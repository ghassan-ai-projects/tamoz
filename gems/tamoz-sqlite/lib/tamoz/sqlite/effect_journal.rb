# frozen_string_literal: true

require "json"
require "securerandom"

module Tamoz
  module SQLite
    class EffectJournal
      PROTOCOL_VERSION = 1
      SAFETIES = %w[
        read_only idempotent transactional reconcilable unsafe
      ].freeze
      STATUSES = %w[
        prepared running succeeded failed unknown reconcile abandoned
      ].freeze
      TERMINAL_ATTEMPT_STATUSES = %w[succeeded failed abandoned].freeze
      MAX_ATTEMPT_TTL = 3_600.0

      attr_reader :store, :guard, :attempt_ttl

      def initialize(store:, guard:, attempt_ttl: 60.0)
        unless attempt_ttl.is_a?(Numeric) &&
               attempt_ttl.finite? &&
               attempt_ttl >= 0.1 &&
               attempt_ttl <= MAX_ATTEMPT_TTL
          raise ConfigurationError,
                "effect attempt_ttl must be between 0.1 and #{MAX_ATTEMPT_TTL}"
        end

        @store = store
        @guard = guard
        @attempt_ttl = attempt_ttl.to_f
        freeze
      end

      def protocol_version = PROTOCOL_VERSION
      def storage_identity = store.adapter

      def key(execution_id:, task_id:, call_index:, operation:)
        execution = Wire.identity(execution_id, name: "effect execution id")
        task = Wire.identity(task_id, name: "effect task id")
        index = non_negative_integer!(call_index, "effect call index")
        operation_text = Wire.identity(operation, name: "effect operation")
        Wire.digest(
          JSON.generate(
            [
              guard.lease.thread_id,
              guard.lease.namespace,
              execution,
              task,
              index,
              operation_text
            ]
          ),
          domain: "tamoz.graph.effect"
        )
      end

      def prepare(
        execution_id:,
        task_id:,
        call_index:,
        operation:,
        safety:,
        request:
      )
        lease = guard.lease
        execution = Wire.identity(execution_id, name: "effect execution id")
        task = Wire.identity(task_id, name: "effect task id")
        index = non_negative_integer!(call_index, "effect call index")
        operation_text = Wire.identity(operation, name: "effect operation")
        safety_text = enum_text!(safety, SAFETIES, "effect safety")
        effect_key = key(
          execution_id: execution,
          task_id: task,
          call_index: index,
          operation: operation_text
        )
        request_bytes = store.checkpoint_codec.state_codec.dump(request)
        request_digest = Wire.digest(
          request_bytes,
          domain: "tamoz.sqlite.effect_request"
        )
        candidate_token = SecureRandom.uuid.freeze
        action = nil
        granted_token = nil

        store.adapter.__send__(:transaction, operation: "effect.prepare") do |tx|
          now = store.adapter.__send__(:backend_time, tx, "effect.prepare.time")
          store.adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "effect.prepare.lease"
          )
          active_execution = tx.scalar(
            "effect.prepare.active_execution",
            <<~SQL,
              SELECT c.execution_id
              FROM tamoz_namespaces n
              JOIN tamoz_checkpoints c ON c.id = n.active_checkpoint_id
              WHERE n.thread_id = ? AND n.namespace = ?
            SQL
            [lease.thread_id, lease.namespace]
          )
          unless active_execution == execution
            raise CheckpointConflictError,
                  "effect execution is not the active graph execution"
          end
          row = effect_row(tx, effect_key, "effect.prepare.row")
          unless row
            tx.execute(
              "effect.prepare.insert",
              <<~SQL,
                INSERT INTO tamoz_effects(
                  effect_key, thread_id, namespace, execution_id, task_id,
                  call_index, operation, safety, request_digest, status,
                  current_attempt, requires_reconciliation,
                  created_at_ms, updated_at_ms
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', 1, 0, ?, ?)
              SQL
              [
                effect_key, lease.thread_id, lease.namespace, execution, task,
                index, operation_text, safety_text, request_digest, now, now
              ]
            )
            insert_attempt!(
              tx,
              effect_key:,
              attempt_number: 1,
              attempt_token: candidate_token,
              fence: lease.fence,
              now:
            )
            append_transition!(
              tx,
              effect_key:,
              transition: "prepare",
              attempt_number: 1,
              actor: nil,
              evidence: {"safety" => safety_text},
              now:
            )
            action = :execute
            granted_token = candidate_token
            next
          end

          verify_effect_identity!(
            row,
            lease:,
            execution_id: execution,
            task_id: task,
            call_index: index,
            operation: operation_text,
            safety: safety_text,
            request_digest:
          )
          status = row.fetch(8)
          case status
          when "succeeded"
            action = :return
          when "unknown"
            action = :unknown
          when "reconcile"
            action = :reconcile
          when "failed", "abandoned"
            action = :failed
          when "prepared", "running"
            attempt = attempt_row(
              tx,
              effect_key,
              row.fetch(10),
              "effect.prepare.current_attempt"
            )
            raise IntegrityError, "effect current attempt is missing" unless attempt
            if attempt.fetch(4) > now
              action = :wait
              next
            end

            if status == "prepared"
              tx.execute(
                "effect.prepare.abandon_unstarted",
                <<~SQL,
                  UPDATE tamoz_effect_attempts
                  SET status = 'abandoned', completed_at_ms = ?
                  WHERE effect_key = ? AND attempt_number = ?
                    AND status = 'prepared'
                SQL
                [now, effect_key, row.fetch(10)]
              )
              grant_next_attempt!(
                tx,
                row:,
                effect_key:,
                token: candidate_token,
                fence: lease.fence,
                now:
              )
              action = :execute
              granted_token = candidate_token
            else
              case safety_text
              when "read_only", "idempotent"
                grant_next_attempt!(
                  tx,
                  row:,
                  effect_key:,
                  token: candidate_token,
                  fence: lease.fence,
                  now:
                )
                action = :execute
                granted_token = candidate_token
              when "transactional", "reconcilable"
                tx.execute(
                  "effect.prepare.reconcile",
                  <<~SQL,
                    UPDATE tamoz_effects
                    SET status = 'reconcile', requires_reconciliation = 1,
                        updated_at_ms = ?
                    WHERE effect_key = ?
                  SQL
                  [now, effect_key]
                )
                action = :reconcile
              when "unsafe"
                tx.execute(
                  "effect.prepare.unknown_attempt",
                  <<~SQL,
                    UPDATE tamoz_effect_attempts
                    SET status = 'unknown', completed_at_ms = ?
                    WHERE effect_key = ? AND attempt_number = ?
                      AND status = 'running'
                  SQL
                  [now, effect_key, row.fetch(10)]
                )
                tx.execute(
                  "effect.prepare.unknown_head",
                  <<~SQL,
                    UPDATE tamoz_effects
                    SET status = 'unknown', updated_at_ms = ?
                    WHERE effect_key = ?
                  SQL
                  [now, effect_key]
                )
                action = :unknown
              end
            end
          else
            raise IntegrityError, "effect status is invalid"
          end
        end

        Tamoz::Graph::EffectDecision.new(
          action:,
          record: fetch(effect_key),
          attempt_token: granted_token
        )
      end

      def start(key:, attempt_token:)
        effect_key = Wire.identity(key, name: "effect key")
        token = Wire.identity(attempt_token, name: "effect attempt token")
        lease = guard.lease
        store.adapter.__send__(:transaction, operation: "effect.start") do |tx|
          now = store.adapter.__send__(:backend_time, tx, "effect.start.time")
          store.adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "effect.start.lease"
          )
          row = tx.first(
            "effect.start.row",
            <<~SQL,
              SELECT e.current_attempt, e.status, a.fence, a.status,
                     a.deadline_ms
              FROM tamoz_effects e
              JOIN tamoz_effect_attempts a
                ON a.effect_key = e.effect_key
               AND a.attempt_number = e.current_attempt
              WHERE e.effect_key = ? AND a.attempt_token = ?
            SQL
            [effect_key, token]
          )
          unless row &&
                 row.fetch(1) == "prepared" &&
                 row.fetch(2) == lease.fence &&
                 row.fetch(3) == "prepared" &&
                 row.fetch(4) > now
            raise LeaseLostError,
                  "effect attempt is expired, stale, or no longer prepared"
          end
          tx.execute(
            "effect.start.attempt",
            <<~SQL,
              UPDATE tamoz_effect_attempts
              SET status = 'running', started_at_ms = ?
              WHERE effect_key = ? AND attempt_number = ?
                AND attempt_token = ? AND status = 'prepared'
            SQL
            [now, effect_key, row.fetch(0), token]
          )
          raise CheckpointConflictError, "effect start lost" unless tx.changes == 1
          tx.execute(
            "effect.start.head",
            <<~SQL,
              UPDATE tamoz_effects
              SET status = 'running', updated_at_ms = ?
              WHERE effect_key = ? AND current_attempt = ?
                AND status = 'prepared'
            SQL
            [now, effect_key, row.fetch(0)]
          )
          raise CheckpointConflictError, "effect head start lost" unless tx.changes == 1
          append_transition!(
            tx,
            effect_key:,
            transition: "start",
            attempt_number: row.fetch(0),
            actor: nil,
            evidence: {},
            now:
          )
        end
        fetch(effect_key)
      end

      def complete(
        key:,
        attempt_token:,
        status:,
        result: nil,
        external_id: nil,
        error: nil
      )
        effect_key = Wire.identity(key, name: "effect key")
        token = Wire.identity(attempt_token, name: "effect attempt token")
        status_text = enum_text!(
          status,
          %w[succeeded failed unknown],
          "effect completion status"
        )
        external = external_id &&
                   Wire.identity(external_id, name: "effect external id")
        result_bytes = store.checkpoint_codec.state_codec.dump(result)
        error_bytes = store.checkpoint_codec.state_codec.dump(error)
        result_digest = Wire.digest(
          result_bytes,
          domain: "tamoz.sqlite.effect_result"
        )
        error_digest = Wire.digest(
          error_bytes,
          domain: "tamoz.sqlite.effect_error"
        )

        store.adapter.__send__(:transaction, operation: "effect.complete") do |tx|
          now = store.adapter.__send__(:backend_time, tx, "effect.complete.time")
          row = tx.first(
            "effect.complete.row",
            <<~SQL,
              SELECT a.attempt_number, a.status, a.result, a.result_digest,
                     a.external_id, a.error, a.error_digest,
                     e.current_attempt, e.status
              FROM tamoz_effect_attempts a
              JOIN tamoz_effects e ON e.effect_key = a.effect_key
              WHERE a.effect_key = ? AND a.attempt_token = ?
            SQL
            [effect_key, token]
          )
          raise CheckpointConflictError, "effect attempt token does not exist" unless row

          if TERMINAL_ATTEMPT_STATUSES.include?(row.fetch(1))
            unless row.fetch(1) == status_text &&
                   row.fetch(2) == result_bytes &&
                   row.fetch(3) == result_digest &&
                   row.fetch(4) == external &&
                   row.fetch(5) == error_bytes &&
                   row.fetch(6) == error_digest
              raise CheckpointConflictError,
                    "effect attempt already has a different terminal receipt"
            end
            next
          end
          unless %w[running unknown].include?(row.fetch(1))
            raise CheckpointConflictError,
                  "effect completion requires a started attempt"
          end

          tx.execute(
            "effect.complete.attempt",
            <<~SQL,
              UPDATE tamoz_effect_attempts
              SET status = ?, result = ?, result_digest = ?,
                  external_id = ?, error = ?, error_digest = ?,
                  completed_at_ms = ?
              WHERE effect_key = ? AND attempt_number = ?
                AND attempt_token = ? AND status IN ('running', 'unknown')
            SQL
            [
              status_text, Wire.blob(result_bytes), result_digest, external,
              Wire.blob(error_bytes), error_digest, now, effect_key,
              row.fetch(0), token
            ]
          )
          raise CheckpointConflictError, "effect receipt commit lost" unless tx.changes == 1

          if row.fetch(0) == row.fetch(7)
            if row.fetch(8) == "succeeded"
              tx.execute(
                "effect.complete.succeeded_head",
                <<~SQL,
                  UPDATE tamoz_effects
                  SET requires_reconciliation = CASE
                        WHEN ? = 'succeeded' THEN requires_reconciliation
                        ELSE 1
                      END,
                      updated_at_ms = ?
                  WHERE effect_key = ? AND current_attempt = ?
                    AND status = 'succeeded'
                SQL
                [status_text, now, effect_key, row.fetch(0)]
              )
            elsif %w[failed abandoned].include?(row.fetch(8)) &&
                  status_text == "succeeded"
              tx.execute(
                "effect.complete.resolved_conflict",
                <<~SQL,
                  UPDATE tamoz_effects
                  SET status = 'reconcile', requires_reconciliation = 1,
                      updated_at_ms = ?
                  WHERE effect_key = ? AND current_attempt = ?
                SQL
                [now, effect_key, row.fetch(0)]
              )
            else
              tx.execute(
                "effect.complete.head",
                <<~SQL,
                  UPDATE tamoz_effects
                  SET status = ?, updated_at_ms = ?
                  WHERE effect_key = ? AND current_attempt = ?
                SQL
                [status_text, now, effect_key, row.fetch(0)]
              )
            end
          elsif status_text == "succeeded"
            tx.execute(
              "effect.complete.late",
              <<~SQL,
                UPDATE tamoz_effects
                SET status = CASE
                      WHEN status = 'succeeded' THEN 'succeeded'
                      ELSE 'reconcile'
                    END,
                    requires_reconciliation = 1,
                    updated_at_ms = ?
                WHERE effect_key = ?
              SQL
              [now, effect_key]
            )
          end
          append_transition!(
            tx,
            effect_key:,
            transition: "complete.#{status_text}",
            attempt_number: row.fetch(0),
            actor: nil,
            evidence: {"late" => row.fetch(0) != row.fetch(7)},
            now:
          )
        end
        fetch(effect_key)
      end

      # Resolve an effect whose head is `reconcile` using evidence observed at the
      # target. Three dispositions, exactly matching the three things a reconciler can
      # honestly conclude:
      #
      #   :completed   the target proves the after-state; the effect happened. Head
      #                becomes succeeded and the recorded receipt is returned.
      #   :not_applied the target proves the *before*-state; the effect never happened.
      #                One further attempt is granted under the same stable effect key,
      #                fenced by the current lease. This retry is authorised by observed
      #                evidence, never by a safety class and never by an approval.
      #   :unknown     the target proves neither. Head becomes unknown and only a human
      #                resolution can move it on.
      #
      # `:not_applied` validates the lease inside the transaction because it grants
      # execution authority. `:completed` and `:unknown` do not, for the same reason
      # `complete` does not: a truthful outcome must be recordable after lease loss.
      def reconcile(key:, disposition:, actor:, evidence:)
        effect_key = Wire.identity(key, name: "effect key")
        disposition_text = enum_text!(
          disposition,
          %w[completed not_applied unknown],
          "effect reconciliation disposition"
        )
        actor_text = Wire.identity(actor, name: "effect reconciliation actor")
        evidence_bytes = store.checkpoint_codec.state_codec.dump(evidence)
        evidence_digest = Wire.digest(
          evidence_bytes,
          domain: "tamoz.sqlite.effect_reconciliation"
        )
        candidate_token = SecureRandom.uuid.freeze
        action = nil
        granted_token = nil

        store.adapter.__send__(:transaction, operation: "effect.reconcile") do |tx|
          now = store.adapter.__send__(:backend_time, tx, "effect.reconcile.time")
          row = effect_row(tx, effect_key, "effect.reconcile.row")
          raise CheckpointConflictError, "effect does not exist" unless row
          unless row.fetch(8) == "reconcile"
            raise CheckpointConflictError,
                  "effect status #{row.fetch(8)} cannot be reconciled"
          end

          case disposition_text
          when "completed"
            tx.execute(
              "effect.reconcile.completed_attempt",
              <<~SQL,
                UPDATE tamoz_effect_attempts
                SET status = 'succeeded', completed_at_ms = ?
                WHERE effect_key = ? AND attempt_number = ?
                  AND status IN ('prepared', 'running', 'unknown')
              SQL
              [now, effect_key, row.fetch(10)]
            )
            tx.execute(
              "effect.reconcile.completed_head",
              <<~SQL,
                UPDATE tamoz_effects
                SET status = 'succeeded', requires_reconciliation = 0, updated_at_ms = ?
                WHERE effect_key = ? AND status = 'reconcile'
              SQL
              [now, effect_key]
            )
            raise CheckpointConflictError, "effect reconciliation lost" unless tx.changes == 1

            action = :return
          when "not_applied"
            store.adapter.__send__(
              :validate_lease_in_transaction!,
              tx,
              guard.lease,
              now:,
              label: "effect.reconcile.lease"
            )
            tx.execute(
              "effect.reconcile.not_applied_attempt",
              <<~SQL,
                UPDATE tamoz_effect_attempts
                SET status = 'abandoned', completed_at_ms = ?
                WHERE effect_key = ? AND attempt_number = ?
                  AND status IN ('prepared', 'running', 'unknown')
              SQL
              [now, effect_key, row.fetch(10)]
            )
            grant_next_attempt!(
              tx,
              row:,
              effect_key:,
              token: candidate_token,
              fence: guard.lease.fence,
              now:
            )
            tx.execute(
              "effect.reconcile.not_applied_head",
              <<~SQL,
                UPDATE tamoz_effects
                SET requires_reconciliation = 0, updated_at_ms = ?
                WHERE effect_key = ?
              SQL
              [now, effect_key]
            )
            action = :execute
            granted_token = candidate_token
          else
            tx.execute(
              "effect.reconcile.unknown_attempt",
              <<~SQL,
                UPDATE tamoz_effect_attempts
                SET status = 'unknown', completed_at_ms = ?
                WHERE effect_key = ? AND attempt_number = ?
                  AND status IN ('prepared', 'running')
              SQL
              [now, effect_key, row.fetch(10)]
            )
            tx.execute(
              "effect.reconcile.unknown_head",
              <<~SQL,
                UPDATE tamoz_effects
                SET status = 'unknown', requires_reconciliation = 1, updated_at_ms = ?
                WHERE effect_key = ? AND status = 'reconcile'
              SQL
              [now, effect_key]
            )
            raise CheckpointConflictError, "effect reconciliation lost" unless tx.changes == 1

            action = :unknown
          end

          append_transition!(
            tx,
            effect_key:,
            transition: "reconcile.#{disposition_text}",
            attempt_number: row.fetch(10),
            actor: actor_text,
            evidence: {
              "payload" => evidence_bytes,
              "payload_digest" => evidence_digest
            },
            now:
          )
        end

        Tamoz::Graph::EffectDecision.new(
          action:,
          record: fetch(effect_key),
          attempt_token: granted_token
        )
      end

      def resolve(key:, status:, actor:, evidence:)
        effect_key = Wire.identity(key, name: "effect key")
        status_text = enum_text!(
          status,
          %w[succeeded failed abandoned],
          "effect resolution status"
        )
        actor_text = Wire.identity(actor, name: "effect resolution actor")
        evidence_bytes = store.checkpoint_codec.state_codec.dump(evidence)

        store.adapter.__send__(:transaction, operation: "effect.resolve") do |tx|
          now = store.adapter.__send__(:backend_time, tx, "effect.resolve.time")
          row = effect_row(tx, effect_key, "effect.resolve.row")
          raise CheckpointConflictError, "effect does not exist" unless row
          unless %w[unknown reconcile failed].include?(row.fetch(8))
            raise CheckpointConflictError,
                  "effect status #{row.fetch(8)} cannot be human-resolved"
          end
          tx.execute(
            "effect.resolve.head",
            <<~SQL,
              UPDATE tamoz_effects
              SET status = ?,
                  requires_reconciliation = CASE WHEN ? = 'succeeded' THEN 0 ELSE
                    requires_reconciliation END,
                  updated_at_ms = ?
              WHERE effect_key = ? AND status = ?
            SQL
            [status_text, status_text, now, effect_key, row.fetch(8)]
          )
          raise CheckpointConflictError, "effect resolution lost" unless tx.changes == 1
          append_transition!(
            tx,
            effect_key:,
            transition: "resolve.#{status_text}",
            attempt_number: row.fetch(10),
            actor: actor_text,
            evidence: {
              "payload" => evidence_bytes,
              "payload_digest" => Wire.digest(
                evidence_bytes,
                domain: "tamoz.sqlite.effect_resolution"
              )
            },
            now:
          )
        end
        fetch(effect_key)
      end

      def fetch(key)
        effect_key = Wire.identity(key, name: "effect key")
        row, attempts = store.adapter.__send__(:read, operation: "effect.fetch") do |tx|
          [
            effect_row(tx, effect_key, "effect.fetch.row"),
            tx.rows(
              "effect.fetch.attempts",
              <<~SQL,
                SELECT attempt_number, attempt_token, fence, status,
                       deadline_ms, result, result_digest, external_id,
                       error, error_digest, prepared_at_ms, started_at_ms,
                       completed_at_ms
                FROM tamoz_effect_attempts
                WHERE effect_key = ?
                ORDER BY attempt_number
              SQL
              [effect_key]
            )
          ]
        end
        return nil unless row

        materialize(row, attempts)
      end

      private

      def effect_row(tx, effect_key, label)
        tx.first(
          label,
          <<~SQL,
            SELECT effect_key, thread_id, namespace, execution_id, task_id,
                   call_index, operation, safety, status, request_digest,
                   current_attempt, requires_reconciliation,
                   created_at_ms, updated_at_ms
            FROM tamoz_effects
            WHERE effect_key = ?
          SQL
          [effect_key]
        )
      end

      def attempt_row(tx, effect_key, attempt_number, label)
        tx.first(
          label,
          <<~SQL,
            SELECT attempt_number, attempt_token, fence, status, deadline_ms
            FROM tamoz_effect_attempts
            WHERE effect_key = ? AND attempt_number = ?
          SQL
          [effect_key, attempt_number]
        )
      end

      def insert_attempt!(
        tx,
        effect_key:,
        attempt_number:,
        attempt_token:,
        fence:,
        now:
      )
        deadline = now + (attempt_ttl * 1_000).ceil
        tx.execute(
          "effect.attempt.insert",
          <<~SQL,
            INSERT INTO tamoz_effect_attempts(
              effect_key, attempt_number, attempt_token, fence, status,
              deadline_ms, result, result_digest, external_id, error,
              error_digest, prepared_at_ms, started_at_ms, completed_at_ms
            )
            VALUES (
              ?, ?, ?, ?, 'prepared', ?, NULL, NULL, NULL, NULL,
              NULL, ?, NULL, NULL
            )
          SQL
          [effect_key, attempt_number, attempt_token, fence, deadline, now]
        )
      end

      def grant_next_attempt!(tx, row:, effect_key:, token:, fence:, now:)
        attempt_number = row.fetch(10) + 1
        insert_attempt!(
          tx,
          effect_key:,
          attempt_number:,
          attempt_token: token,
          fence:,
          now:
        )
        tx.execute(
          "effect.attempt.advance",
          <<~SQL,
            UPDATE tamoz_effects
            SET status = 'prepared', current_attempt = ?,
                updated_at_ms = ?
            WHERE effect_key = ?
          SQL
          [attempt_number, now, effect_key]
        )
        append_transition!(
          tx,
          effect_key:,
          transition: "retry.prepare",
          attempt_number:,
          actor: nil,
          evidence: {},
          now:
        )
      end

      def verify_effect_identity!(
        row,
        lease:,
        execution_id:,
        task_id:,
        call_index:,
        operation:,
        safety:,
        request_digest:
      )
        expected = [
          lease.thread_id,
          lease.namespace,
          execution_id,
          task_id,
          call_index,
          operation,
          safety,
          request_digest
        ]
        actual = [
          row.fetch(1), row.fetch(2), row.fetch(3), row.fetch(4),
          row.fetch(5), row.fetch(6), row.fetch(7), row.fetch(9)
        ]
        return if actual == expected

        raise CheckpointConflictError,
              "effect key is already bound to different semantics"
      end

      def append_transition!(
        tx,
        effect_key:,
        transition:,
        attempt_number:,
        actor:,
        evidence:,
        now:
      )
        index = tx.scalar(
          "effect.transition.index",
          <<~SQL,
            SELECT COALESCE(MAX(transition_index) + 1, 0)
            FROM tamoz_effect_transitions
            WHERE effect_key = ?
          SQL
          [effect_key]
        )
        tx.execute(
          "effect.transition.insert",
          <<~SQL,
            INSERT INTO tamoz_effect_transitions(
              effect_key, transition_index, transition, attempt_number,
              actor, evidence, created_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            effect_key, index, transition, attempt_number, actor,
            Wire.blob(JSON.generate(evidence)), now
          ]
        )
      end

      def materialize(row, attempts)
        safety = checked_symbol!(row.fetch(7), SAFETIES, "effect safety")
        status = checked_symbol!(row.fetch(8), STATUSES, "effect status")
        materialized_attempts = attempts.map do |attempt|
          result = decode_receipt(
            attempt.fetch(5),
            attempt.fetch(6),
            "tamoz.sqlite.effect_result"
          )
          error = decode_receipt(
            attempt.fetch(8),
            attempt.fetch(9),
            "tamoz.sqlite.effect_error"
          )
          Tamoz::Graph::EffectAttempt.new(
            attempt_number: attempt.fetch(0),
            attempt_token: attempt.fetch(1).dup.freeze,
            fence: attempt.fetch(2),
            status: checked_symbol!(
              attempt.fetch(3),
              %w[prepared running succeeded failed unknown abandoned],
              "effect attempt status"
            ),
            deadline_ms: attempt.fetch(4),
            result:,
            external_id: attempt.fetch(7)&.dup&.freeze,
            error:,
            prepared_at_ms: attempt.fetch(10),
            started_at_ms: attempt.fetch(11),
            completed_at_ms: attempt.fetch(12)
          )
        end.freeze
        Tamoz::Graph::EffectRecord.new(
          key: row.fetch(0).dup.freeze,
          thread_id: row.fetch(1).dup.freeze,
          namespace: Wire.decode_namespace(row.fetch(2)),
          execution_id: row.fetch(3).dup.freeze,
          task_id: row.fetch(4).dup.freeze,
          call_index: row.fetch(5),
          operation: row.fetch(6).dup.freeze,
          safety:,
          status:,
          request_digest: row.fetch(9).dup.freeze,
          current_attempt: row.fetch(10),
          requires_reconciliation: row.fetch(11) == 1,
          attempts: materialized_attempts,
          created_at_ms: row.fetch(12),
          updated_at_ms: row.fetch(13)
        )
      end

      def decode_receipt(bytes, digest, domain)
        if bytes.nil?
          raise IntegrityError, "#{domain} digest exists without payload" if digest

          return nil
        end
        Wire.verify_digest!(bytes, digest, domain:)
        value = store.checkpoint_codec.state_codec.load(bytes)
        # Canonicality is a BYTE property. SQLite returns BLOB columns as
        # ASCII-8BIT while the codec dumps UTF-8, so `==` is false for any
        # byte-identical payload that is not ASCII-only — one non-ASCII
        # character in a model reply would forge a corruption error.
        unless store.checkpoint_codec.state_codec.dump(value).b == bytes.b
          raise CheckpointCorruptionError, "#{domain} payload is not canonical"
        end

        value
      end

      def enum_text!(value, allowed, name)
        text = value.to_s
        return text if allowed.include?(text)

        raise ConfigurationError, "#{name} is invalid"
      end

      def checked_symbol!(value, allowed, name)
        unless value.is_a?(String) && allowed.include?(value)
          raise CheckpointCorruptionError, "stored #{name} is invalid"
        end

        value.to_sym
      end

      def non_negative_integer!(value, name)
        return value if value.is_a?(Integer) && !value.negative?

        raise ConfigurationError, "#{name} must be a non-negative integer"
      end

      private_constant :PROTOCOL_VERSION, :SAFETIES, :STATUSES,
                       :TERMINAL_ATTEMPT_STATUSES, :MAX_ATTEMPT_TTL
    end
  end
end
