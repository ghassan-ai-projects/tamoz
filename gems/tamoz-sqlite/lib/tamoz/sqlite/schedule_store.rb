# frozen_string_literal: true

require "json"

module Tamoz
  module SQLite
    # P13-A — the durable ScheduleStore (plan §4, SCHEDULER_DESIGN §11).
    #
    # The atomicity seam (C1/DC-4) is honored exactly: `materialize_due`
    # claims → creates the occurrence → enqueues its request inside ONE
    # transaction, reusing the enqueue primitive extracted from
    # `CheckpointStore#enqueue_request` (`enqueue_request_in_transaction!`).
    # A crash at any point leaves old-or-complete-new state; a repeated
    # delivery re-runs the same transaction and the shared primitive dedups on
    # the deterministic request id (invariant 38 duplicate-turn hard zero).
    #
    # The `request_id` is a digest of the occurrence identity, so a retried
    # materialization re-enqueues the SAME request row. Schedule edits CAS on
    # `expected_revision`; occurrences reference the request inbox by request id
    # only (no FK into the request tables), so a pre-P13 database migrates
    # forward without touching existing rows.
    class ScheduleStore
      include Tamoz::Scheduler::ScheduleStore

      REQUEST_OPERATION = "turn"
      REQUEST_DELIVERY = "queue"
      REQUEST_NAMESPACE = [].freeze
      ENQUEUE_CONTEXT_DOMAIN = "tamoz.sqlite.scheduler.enqueue.v1\n"

      def initialize(adapter:, checkpoints:)
        @adapter = adapter
        @checkpoints = checkpoints
      end

      attr_reader :adapter, :checkpoints

      # --- schedules --------------------------------------------------------

      def put_schedule(schedule, expected_revision: nil)
        now = now_ms
        payload = schedule.to_h
        bytes = JSON.generate(Tamoz::Core.canonical(payload))
        digest = Digest::SHA256.hexdigest(ENQUEUE_CONTEXT_DOMAIN + bytes)
        row = nil
        @adapter.__send__(:transaction, operation: "schedule.put") do |tx|
          current = tx.scalar(
            "schedule.put.revision",
            <<~SQL,
              SELECT revision FROM tamoz_schedules
              WHERE schedule_id = ? AND deleted = 0
              ORDER BY revision DESC LIMIT 1
            SQL
            [schedule.id]
          )
          if current && expected_revision != current
            raise Tamoz::Scheduler::StoreConflictError,
                  "schedule #{schedule.id} is at revision #{current}, expected #{expected_revision}"
          end
          next_revision = (current || 0) + 1
          tx.execute(
            "schedule.put.insert",
            <<~SQL,
              INSERT INTO tamoz_schedules(
                schedule_id, revision, definition_digest, payload,
                payload_digest, enabled, deleted, created_at_ms, updated_at_ms
              )
              VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
            SQL
            [
              schedule.id, next_revision, schedule.definition_digest,
              bytes, digest, schedule.enabled ? 1 : 0, now, now
            ]
          )
          row = tx.first(
            "schedule.put.select",
            <<~SQL,
              SELECT revision, definition_digest, payload, enabled
              FROM tamoz_schedules
              WHERE schedule_id = ? AND revision = ?
            SQL
            [schedule.id, next_revision]
          )
        end
        materialize_schedule(row)
      end

      def disable_schedule(id, expected_revision:, reason:)
        now = now_ms
        @adapter.__send__(:transaction, operation: "schedule.disable") do |tx|
          current = tx.scalar(
            "schedule.disable.revision",
            <<~SQL,
              SELECT revision FROM tamoz_schedules
              WHERE schedule_id = ? AND deleted = 0
              ORDER BY revision DESC LIMIT 1
            SQL
            [id]
          )
          unless current == expected_revision
            raise Tamoz::Scheduler::StoreConflictError,
                  "schedule #{id} is at revision #{current}, expected #{expected_revision}"
          end
          tx.execute(
            "schedule.disable.update",
            <<~SQL,
              UPDATE tamoz_schedules
              SET enabled = 0, updated_at_ms = ?
              WHERE schedule_id = ? AND revision = ?
            SQL
            [now, id, current]
          )
        end
        nil
      end

      # --- occurrences ------------------------------------------------------

      # The atomic due scan (plan §4 C1/DC-4). For every enabled schedule whose
      # next nominal instant has passed, claim/create the occurrence and enqueue
      # its request — ONE transaction. Returns the occurrences whose requests
      # committed. A repeated call re-runs the same transaction and dedups on
      # the request id.
      #
      # P13-C (invariant 40): `current_grant` is the operator policy AT the
      # enforcement point. The schedule's stored maximum grant is intersected
      # against it: a revoked schedule skips (escalates), a narrowed one runs
      # under the effective intersection. When `current_grant` is nil the
      # check is skipped (the scorecard harness and tests that pin claim-time
      # behavior before P13-C); production callers always pass it.
      def materialize_due(now:, owner:, lease_for:, limit:, request_template:,
                          current_grant: nil)
        claimed = []
        @adapter.__send__(:transaction, operation: "schedule.materialize_due") do |tx|
          schedules = tx.rows(
            "schedule.materialize.schedules",
            <<~SQL,
              SELECT s.schedule_id, s.revision, s.definition_digest, s.payload, s.enabled
              FROM tamoz_schedules s
              JOIN (
                SELECT schedule_id, MAX(revision) AS revision
                FROM tamoz_schedules
                WHERE deleted = 0
                GROUP BY schedule_id
              ) latest ON latest.schedule_id = s.schedule_id
                       AND latest.revision = s.revision
              WHERE s.enabled = 1 AND s.deleted = 0
              ORDER BY s.schedule_id COLLATE BINARY
              LIMIT ?
            SQL
            [limit]
          )
          schedules.each do |row|
            # [schedule_id, revision, definition_digest, payload, enabled]
            schedule = materialize_schedule(
              [row.fetch(1), row.fetch(2), row.fetch(3), row.fetch(4)]
            )
            next unless schedule

            # P13-C (invariant 40, claim-time): the stored maximum grant is a
            # ceiling. Revocation skips/escalates; narrowing runs under the
            # intersection. The request template carries the effective grant.
            claim_template = request_template
            if current_grant
              effective = Tamoz::Scheduler::GrantIntersector.effective_grant(
                schedule.capability_grant, current_grant
              )
              if effective.nil?
                record_grant_denied(schedule, now, tx)
                next
              end
              claim_template = request_template.merge(
                "effective_grant" => effective
              )
            end

            due = schedule.due_occurrences(now:, limit:)
            next if due.empty?

            # P13-B (design §6): misfire policy decides what this scan
            # materializes vs. records as skipped. Deterministic, bounded.
            selection = schedule.misfire_selection(due)
            non_terminal, pending = occurrence_state(schedule.id, tx)

            # Misfire-skipped instants are recorded as skipped history (never
            # enqueued), per the policy's selection.
            selection.fetch(:skipped).each do |fire_at|
              occurrence = build_occurrence(schedule, fire_at, now)
              next if occurrence_exists?(occurrence, tx)

              record_terminal(schedule, occurrence, :skipped, "misfire", now, tx)
            end

            # P13-B (design §7): overlap decision from DURABLE occurrence
            # state captured BEFORE this scan — never a process-local mutex,
            # and same-scan replay occurrences are sequential, not concurrent.
            overlap = schedule.overlap_decision(non_terminal:, pending:)

            due.each do |fire_at|
              occurrence = build_occurrence(schedule, fire_at, now)
              next if occurrence_exists?(occurrence, tx)
              next unless selection.fetch(:materialize).include?(fire_at)

              case overlap
              when :skip
                record_terminal(schedule, occurrence, :skipped, "overlap", now, tx)
              when :coalesce
                record_terminal(
                  schedule, occurrence, :coalesced,
                  "into pending occurrence", now, tx
                )
              when :materialize
                enqueue_occurrence(
                  schedule, occurrence, now, owner, claim_template, tx
                ).then { |value| claimed << value }
              end
            end
          end
        end
        claimed
      end

      # P13-B internals ------------------------------------------------------

      # Durable in-flight state for one schedule: [non_terminal, pending].
      # `non_terminal` = claimed + enqueued + running; `pending` = enqueued
      # only. Computed from the occurrence rows, never a process-local mutex.
      def occurrence_state(schedule_id, tx)
        row = tx.first(
          "schedule.materialize.state",
          <<~SQL,
            SELECT
              SUM(CASE WHEN state IN ('claimed', 'enqueued', 'running') THEN 1 ELSE 0 END),
              SUM(CASE WHEN state = 'enqueued' THEN 1 ELSE 0 END)
            FROM tamoz_occurrences
            WHERE schedule_id = ?
          SQL
          [schedule_id]
        )
        [row.fetch(0).to_i, row.fetch(1).to_i]
      end

      def occurrence_exists?(occurrence, tx)
        tx.scalar(
          "schedule.materialize.occurrence",
          "SELECT 1 FROM tamoz_occurrences WHERE occurrence_id = ?",
          [occurrence.occurrence_id]
        ) == 1
      end

      # P13-C (invariant 40): the schedule's stored grant is REVOKED under
      # current policy. The earliest due occurrence is recorded as skipped with
      # reason `grant_revoked` (bounded, queryable history) and nothing is
      # enqueued — a revoked schedule never runs with a fabricated grant.
      def record_grant_denied(schedule, now, tx)
        earliest = schedule.due_occurrences(now:).first
        return unless earliest

        occurrence = build_occurrence(schedule, earliest, now)
        return if occurrence_exists?(occurrence, tx)

        record_terminal(schedule, occurrence, :skipped, "grant_revoked", now, tx)
      end

      # Enqueue ONE occurrence: the deterministic request id is the dedup key
      # (invariant 38), so a retried delivery re-enqueues the same request row.
      def enqueue_occurrence(schedule, occurrence, now, owner, request_template, tx)
        thread, encoded_namespace = normalize_request_address(schedule)
        request_id = occurrence.request_id
        payload = build_request_payload(schedule, occurrence, request_template)
        payload_bytes = @checkpoints.checkpoint_codec.dump_request_payload(
          REQUEST_OPERATION, payload
        )
        payload_digest = Wire.digest(
          payload_bytes, domain: "tamoz.sqlite.request_payload"
        )
        input_digest = Wire.digest(
          JSON.generate([REQUEST_OPERATION, REQUEST_DELIVERY, payload_bytes]),
          domain: "tamoz.sqlite.request"
        )
        @checkpoints.enqueue_request_in_transaction!(
          tx,
          thread:, encoded_namespace:, id: request_id,
          operation_text: REQUEST_OPERATION, delivery_text: REQUEST_DELIVERY,
          payload_bytes:, payload_digest:, input_digest:
        )
        tx.execute(
          "schedule.materialize.occurrence.insert",
          <<~SQL,
            INSERT INTO tamoz_occurrences(
              occurrence_id, schedule_id, schedule_revision,
              nominal_fire_at_utc, not_before, request_id, state,
              fence, owner, reason, payload_digest, created_at_ms, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, 'enqueued', ?, ?, NULL, ?, ?, ?)
          SQL
          [
            occurrence.occurrence_id, schedule.id, schedule.revision,
            occurrence.nominal_fire_at_utc, occurrence.not_before,
            request_id, now, owner, payload_digest, now, now
          ]
        )
        occurrence.claimed(fence: now, owner:, now:).enqueued(fence: now, now:)
      end

      # Record a non-materialized occurrence as skipped/coalesced (bounded
      # history, explicit in the occurrence row). `request_id` is still derived
      # so history is queryable by request, but no request is enqueued. The
      # payload_digest column is NOT NULL, so the terminal reason digest fills
      # it (no request payload exists for a non-delivered occurrence).
      def record_terminal(schedule, occurrence, state, reason, now, tx)
        digest = "sha256:#{Digest::SHA256.hexdigest(
          ENQUEUE_CONTEXT_DOMAIN + "#{state}:#{reason}:#{occurrence.occurrence_id}"
        )}"
        tx.execute(
          "schedule.materialize.terminal.insert",
          <<~SQL,
            INSERT INTO tamoz_occurrences(
              occurrence_id, schedule_id, schedule_revision,
              nominal_fire_at_utc, not_before, request_id, state,
              fence, owner, reason, payload_digest, created_at_ms, updated_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?)
          SQL
          [
            occurrence.occurrence_id, schedule.id, schedule.revision,
            occurrence.nominal_fire_at_utc, occurrence.not_before,
            occurrence.request_id, state.to_s, reason, digest, now, now
          ]
        )
        nil
      end

      def renew_occurrence_lease(id, fence:, lease_for:)
        now = now_ms
        changed = nil
        @adapter.__send__(:transaction, operation: "schedule.renew") do |tx|
          tx.execute(
            "schedule.renew.update",
            <<~SQL,
              UPDATE tamoz_occurrences
              SET fence = ?, updated_at_ms = ?
              WHERE occurrence_id = ? AND fence = ?
                AND state IN ('claimed', 'enqueued', 'running')
            SQL
            [fence, now, id, fence]
          )
          changed = tx.changes
        end
        if changed.zero?
          raise Tamoz::Scheduler::LeaseLostError,
                "occurrence lease was lost or already completed"
        end
        nil
      end

      # P13-B (design §10): the delivery→execution handoff. Delivery is
      # `enqueued` (the request committed); the consumer acknowledges the
      # occurrence when the graph starts running it. Distinct from completion —
      # enqueued is never execution success (hard zero: no false green).
      def acknowledge_occurrence(id, execution_id:, fence:, now: nil)
        now ||= now_ms
        changed = nil
        @adapter.__send__(:transaction, operation: "schedule.acknowledge") do |tx|
          tx.execute(
            "schedule.acknowledge.update",
            <<~SQL,
              UPDATE tamoz_occurrences
              SET state = 'running', fence = ?, reason = ?, updated_at_ms = ?
              WHERE occurrence_id = ? AND state = 'enqueued' AND fence = ?
            SQL
            [fence, JSON.generate({"execution_id" => execution_id}), now, id, fence]
          )
          changed = tx.changes
        end
        if changed.zero?
          raise Tamoz::Scheduler::LeaseLostError,
                "occurrence #{id} is not enqueued under the given fence"
        end
        nil
      end

      def complete_occurrence(id, execution_id:, status:, evidence:)
        now = now_ms
        changed = nil
        @adapter.__send__(:transaction, operation: "schedule.complete") do |tx|
          tx.execute(
            "schedule.complete.update",
            <<~SQL,
              UPDATE tamoz_occurrences
              SET state = ?, reason = ?, updated_at_ms = ?
              WHERE occurrence_id = ? AND state = 'running'
            SQL
            [status.to_s, JSON.generate({"execution_id" => execution_id, "evidence" => evidence}), now, id]
          )
          changed = tx.changes
        end
        if changed.zero?
          raise Tamoz::Scheduler::SchedulerError,
                "occurrence #{id} is not running; completion refused"
        end
        nil
      end

      def list_occurrences(schedule_id:, cursor: nil, limit: 100)
        bound = limit.clamp(1, 100)
        rows = @adapter.__send__(:read, operation: "schedule.list") do |tx|
          if cursor
            tx.rows(
              "schedule.list.after",
              <<~SQL,
                SELECT occurrence_id, schedule_id, schedule_revision,
                       nominal_fire_at_utc, not_before, request_id, state,
                       fence, owner, reason, created_at_ms, updated_at_ms
                FROM tamoz_occurrences
                WHERE schedule_id = ? AND occurrence_id > ?
                ORDER BY occurrence_id COLLATE BINARY
                LIMIT ?
              SQL
              [schedule_id, cursor, bound]
            )
          else
            tx.rows(
              "schedule.list.all",
              <<~SQL,
                SELECT occurrence_id, schedule_id, schedule_revision,
                       nominal_fire_at_utc, not_before, request_id, state,
                       fence, owner, reason, created_at_ms, updated_at_ms
                FROM tamoz_occurrences
                WHERE schedule_id = ?
                ORDER BY occurrence_id COLLATE BINARY
                LIMIT ?
              SQL
              [schedule_id, bound]
            )
          end
        end
        rows.map { |row| materialize_occurrence(row) }
      end

      # --- internals --------------------------------------------------------

      def now_ms
        (Time.now.to_r * 1000).to_i
      end

      def build_occurrence(schedule, fire_at, now)
        Tamoz::Scheduler::Occurrence.new(
          schedule_id: schedule.id,
          schedule_revision: schedule.revision,
          nominal_fire_at_utc: fire_at,
          not_before: fire_at + schedule.jitter_for(
            Tamoz::Scheduler::Occurrence.identity(schedule.id, schedule.revision, fire_at)
          ),
          created_at: now
        )
      end

      def normalize_request_address(schedule)
        thread = Wire.identity(schedule.thread_policy, name: "thread id")
        [thread, Wire.namespace(REQUEST_NAMESPACE)].freeze
      end

      def build_request_payload(schedule, occurrence, template)
        base = template.dup
        {
          "schedule_id" => schedule.id,
          "schedule_revision" => schedule.revision,
          "occurrence_id" => occurrence.occurrence_id,
          "nominal_fire_at_utc" => occurrence.nominal_fire_at_utc,
          "request_id" => occurrence.request_id
        }.each { |key, value| base[key] = value }
        base
      end

      def materialize_schedule(row)
        return nil unless row

        payload = JSON.parse(row.fetch(2), create_additions: false)
        coerced = payload.dup
        # String-keyed JSON round-trip: coerce the enum fields back to symbols
        # (the value constructor validates symbols only).
        %w[kind misfire_policy overlap_policy].each do |key|
          coerced[key] = coerced[key].to_sym if coerced.key?(key)
        end
        # The DB revision, enabled flag, and stored definition digest are
        # authoritative; reconstructing must not recompute any of them.
        # Canonical row shape: [revision, definition_digest, payload, enabled].
        coerced["revision"] = row.fetch(0)
        coerced["definition_digest"] = row.fetch(1)
        coerced["enabled"] = row.fetch(3) == 1 if row.length >= 4
        Tamoz::Scheduler::Schedule.new(**symbolize_keys(coerced))
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Tamoz::CheckpointCorruptionError.new("schedule record is invalid"), cause: error
      end

      def materialize_occurrence(row)
        Tamoz::Scheduler::Occurrence.new(
          schedule_id: row.fetch(1),
          schedule_revision: row.fetch(2),
          nominal_fire_at_utc: row.fetch(3),
          not_before: row.fetch(4),
          state: row.fetch(6).to_sym,
          fence: row.fetch(7),
          owner: row.fetch(8),
          reason: row.fetch(9).nil? ? nil : begin
            parsed = JSON.parse(row.fetch(9), create_additions: false)
            parsed.is_a?(Hash) ? parsed : row.fetch(9)
          rescue JSON::ParserError
            row.fetch(9)
          end,
          created_at: row.fetch(10),
          updated_at: row.fetch(11)
        )
      end

      def symbolize_keys(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key.to_sym] = value
        end
      end
    end
  end
end
