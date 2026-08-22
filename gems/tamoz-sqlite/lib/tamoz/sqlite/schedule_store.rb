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
        bytes = Tamoz::Core.jcs(payload)
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
          # `enabled` is lifecycle STATE, not definition: an edit preserves the
          # current enabled flag unless the new definition explicitly sets it,
          # so a paused schedule stays paused across edits (critic repro J).
          enabled = if schedule.enabled == false
                      false
                    elsif current
                      tx.scalar(
                        "schedule.put.enabled",
                        <<~SQL,
                          SELECT enabled FROM tamoz_schedules
                          WHERE schedule_id = ? AND revision = ?
                        SQL
                        [schedule.id, current]
                      ) == 1
                    else
                      true
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
              bytes, digest, enabled ? 1 : 0, now, now
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

      # Every schedule at its ACTIVE revision, for `tamoz schedule list/show`.
      # Read-only, no lease: an operator must be able to look at a running
      # runtime without contending with the worker polling it.
      def list_schedules(limit: 500)
        bounded = Integer(limit)
        raise ConfigurationError, "limit must be positive" unless bounded.positive?

        rows = @adapter.__send__(:read, operation: "schedule.list_definitions") do |tx|
          tx.rows(
            "schedule.list_definitions.select",
            <<~SQL,
              SELECT s.revision, s.definition_digest, s.payload, s.enabled
              FROM tamoz_schedules s
              JOIN (
                SELECT schedule_id, MAX(revision) AS revision
                FROM tamoz_schedules
                WHERE deleted = 0
                GROUP BY schedule_id
              ) latest ON latest.schedule_id = s.schedule_id
                       AND latest.revision = s.revision
              WHERE s.deleted = 0
              ORDER BY s.schedule_id COLLATE BINARY
              LIMIT ?
            SQL
            [bounded]
          )
        end
        rows.filter_map { |row| materialize_schedule(row) }.freeze
      end

      def fetch_schedule(id)
        list_schedules.find { |schedule| schedule.id == id }
      end

      # The symmetric partner of `disable_schedule`. Enabling is lifecycle state,
      # not definition: `put_schedule` deliberately PRESERVES the stored enabled
      # flag across edits (so an edit cannot silently un-pause a schedule), which
      # is exactly why resuming needs its own path rather than a re-put.
      def enable_schedule(id, expected_revision:)
        now = now_ms
        @adapter.__send__(:transaction, operation: "schedule.enable") do |tx|
          current = tx.scalar(
            "schedule.enable.revision",
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
            "schedule.enable.update",
            <<~SQL,
              UPDATE tamoz_schedules
              SET enabled = 1, updated_at_ms = ?
              WHERE schedule_id = ? AND revision = ?
            SQL
            [now, id, current]
          )
        end
        nil
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
      # enforcement point — REQUIRED. The schedule's stored maximum grant is
      # intersected against it: a revoked schedule skips (escalates), a
      # narrowed one runs under the effective intersection. `nil` fails
      # closed (treated as an empty policy, so nothing survives the
      # intersection): no operator policy means no delayed authority.
      # `include_provenance` controls whether the enqueued request payload carries
      # the schedule/occurrence identifiers alongside the template.
      #
      # It defaults to true, which is the original behaviour. A caller whose
      # consumer treats the payload as a CLOSED schema — the agent session, whose
      # payload is its initial graph state and rejects any key that is not a
      # declared channel — passes false. The identifiers are not lost by doing so:
      # every one of them is a column on the occurrence row this method writes in
      # the same transaction, so provenance stays queryable through
      # `list_occurrences` either way.
      def materialize_due(now:, owner:, lease_for:, limit:, request_template:,
                          current_grant:, include_provenance: true)
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

            begin
              claim_one_schedule(
                schedule, now:, owner:, limit:, request_template:,
                current_grant:, tx:, include_provenance:
              ).each { |value| claimed << value }
            rescue Tamoz::Scheduler::StoreConflictError, Tamoz::CheckpointConflictError => error
              # Plan §11: one schedule's conflict never crashes the poller.
              # Record the conflict as a skipped reason and continue the scan.
              record_scan_conflict(schedule, now, error.message, tx)
            end
          end
        end
        claimed
      end

      # The per-schedule claim body: grant intersection, due window, misfire
      # selection, overlap enforcement (per-occurrence for `allow`), and the
      # enqueue. Runs inside the caller's transaction.
      def claim_one_schedule(schedule, now:, owner:, limit:, request_template:,
                             current_grant:, tx:, include_provenance: true)
        claimed = []
        # P13-C (invariant 40, claim-time): the stored maximum grant is a
        # ceiling. `nil` current policy fails closed (nothing survives).
        effective = Tamoz::Scheduler::GrantIntersector.effective_grant(
          schedule.capability_grant, current_grant
        )
        if effective.nil?
          record_grant_denied(schedule, now, tx)
          return claimed
        end
        # Resolve a callable template ONCE per schedule, before it is merged or
        # enqueued, so one scan can carry a different task per schedule.
        resolved_template =
          request_template.respond_to?(:call) ? request_template.call(schedule) : request_template
        unless resolved_template.is_a?(Hash)
          raise Tamoz::Scheduler::SchedulerError,
                "request_template must be a Hash or return one, got #{resolved_template.class}"
        end

        # The claim-time grant intersection rides in the payload for consumers
        # with an open payload schema. For a closed-schema consumer it is left
        # out — and not lost: it is a pure function of the schedule's stored
        # `capability_grant` at the revision the occurrence pins, intersected
        # with the worker's grant at claim time, so it stays reconstructible from
        # the occurrence row rather than being taken on trust from the payload.
        claim_template =
          if include_provenance
            resolved_template.merge("effective_grant" => effective)
          else
            resolved_template
          end

        due = schedule.due_occurrences(now:, limit:)
        return claimed if due.empty?

        # P13-B (design §6): misfire policy decides what this scan
        # materializes vs. records as skipped. Deterministic, bounded.
        selection = schedule.misfire_selection(due)
        non_terminal, pending = occurrence_state(schedule.id, tx)

        # P13-B (design §7): `forbid`/`queue_one` gate running-ahead against
        # the DURABLE pre-scan state (a prior poll's in-flight occurrence
        # blocks/coalesces THIS scan); `allow` re-evaluates per occurrence.
        overlap = schedule.overlap_policy == :allow ? nil :
                  schedule.overlap_decision(non_terminal:, pending:)

        # Misfire-skipped instants are recorded as skipped history (never
        # enqueued), per the policy's selection.
        selection.fetch(:skipped).each do |fire_at|
          occurrence = build_occurrence(schedule, fire_at, now)
          next if occurrence_exists?(occurrence, tx)

          record_terminal(schedule, occurrence, :skipped, "misfire", now, tx)
        end

        due.each do |fire_at|
          occurrence = build_occurrence(schedule, fire_at, now)
          next if occurrence_exists?(occurrence, tx)
          next unless selection.fetch(:materialize).include?(fire_at)

          # P13-C/§5 (design §5): an occurrence is deliverable only once its
          # `not_before` (nominal instant + deterministic jitter) has passed.
          next if now < occurrence.not_before

          # P13-B (design §7): overlap from DURABLE occurrence state — never
          # a process-local mutex. `forbid`/`queue_one` gate running-ahead
          # (evaluated against the pre-scan state once, so replay catch-up is
          # not blocked by its own same-scan materializations); `allow` is
          # re-evaluated per occurrence so same-scan materializations count
          # toward max_concurrency.
          if schedule.overlap_policy == :allow
            overlap = schedule.overlap_decision(non_terminal:, pending:)
          end
          case overlap
          when :skip
            if schedule.overlap_policy == :allow
              # Backpressure, not a skip: the occurrence stays eligible for a
              # later scan once concurrency frees (design §7 "exhaustion
              # delays with a reason"). It is NOT recorded as terminal.
              next
            end
            record_terminal(schedule, occurrence, :skipped, "overlap", now, tx)
          when :coalesce
            record_terminal(
              schedule, occurrence, :coalesced,
              "into pending occurrence", now, tx
            )
          when :materialize
            enqueue_occurrence(
              schedule, occurrence, now, owner, claim_template, tx, include_provenance:
            ).then { |value| claimed << value }
            non_terminal += 1
            pending += 1
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
      # current policy. EVERY due occurrence (bounded by the due window) is
      # recorded as skipped with reason `grant_revoked` (design §6: every due
      # occurrence has exactly one durable reason); nothing is enqueued — a
      # revoked schedule never runs with a fabricated grant.
      def record_grant_denied(schedule, now, tx)
        schedule.due_occurrences(now:).each do |fire_at|
          occurrence = build_occurrence(schedule, fire_at, now)
          next if occurrence_exists?(occurrence, tx)

          record_terminal(schedule, occurrence, :skipped, "grant_revoked", now, tx)
        end
      end

      # Plan §11: a schedule whose enqueue conflicted (a byte-different
      # duplicate request id, or a stale revision) records the conflict as a
      # skipped reason — the scan continues, the poller never crashes.
      def record_scan_conflict(schedule, now, message, tx)
        due = schedule.due_occurrences(now:)
        return if due.empty?

        occurrence = build_occurrence(schedule, due.last, now)
        return if occurrence_exists?(occurrence, tx)

        record_terminal(
          schedule, occurrence, :skipped,
          "scan_conflict:#{message.to_s.byteslice(0, 128)}", now, tx
        )
      end

      # Enqueue ONE occurrence: the deterministic request id is the dedup key
      # (invariant 38), so a retried delivery re-enqueues the same request row.
      def enqueue_occurrence(schedule, occurrence, now, owner, request_template, tx,
                             include_provenance: true)
        thread, encoded_namespace = normalize_request_address(schedule)
        request_id = occurrence.request_id
        payload = build_request_payload(schedule, occurrence, request_template, include_provenance)
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

      TERMINAL_EXECUTION_STATUSES = %i[succeeded failed cancelled unknown].freeze

      def complete_occurrence(id, execution_id:, status:, evidence:)
        unless TERMINAL_EXECUTION_STATUSES.include?(status)
          raise Tamoz::Scheduler::SchedulerError,
                "execution status must be one of " \
                "#{TERMINAL_EXECUTION_STATUSES.inspect}, got #{status.inspect}"
        end
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

      # Join the scheduler's durable occurrence to the ordinary request inbox
      # by its deterministic request id. The worker uses this seam to complete
      # the delivery-to-execution lifecycle after the graph has a durable view.
      def occurrence_for_request(request_id)
        normalized = Wire.identity(request_id, name: "schedule request id")
        row = @adapter.__send__(:read, operation: "schedule.occurrence_for_request") do |tx|
          tx.first(
            "schedule.occurrence_for_request.fetch",
            <<~SQL,
              SELECT occurrence_id, schedule_id, schedule_revision,
                     nominal_fire_at_utc, not_before, request_id, state,
                     fence, owner, reason, created_at_ms, updated_at_ms
              FROM tamoz_occurrences
              WHERE request_id = ?
              ORDER BY updated_at_ms DESC
              LIMIT 1
            SQL
            [normalized]
          )
        end
        row && materialize_occurrence(row)
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

      def build_request_payload(schedule, occurrence, template, include_provenance = true)
        base = template.dup
        return base unless include_provenance

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
