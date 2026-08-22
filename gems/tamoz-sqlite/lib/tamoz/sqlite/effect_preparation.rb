# frozen_string_literal: true

require 'securerandom'

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Owns the atomic prepare, recovery, and retry-grant decisions.
    # :reek:DuplicateMethodCall :reek:TooManyStatements -- ordered SQL branches
    # preserve lease/row validation and atomic sequencing.
    # :reek:LongParameterList :reek:TooManyInstanceVariables -- named fields
    # are explicit collaborators or immutable effect-intent policy values.
    class EffectPreparation
      def initialize(store:, guard:, attempt_ttl:, record_reader:, safeties:)
        @store = store
        @guard = guard
        @attempt_ttl = attempt_ttl
        @record_reader = record_reader
        @safeties = safeties
        freeze
      end

      # The single transaction deliberately keeps lease validation, head state,
      # attempt state, and audit transition ordering visible.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
      # rubocop:disable Metrics/BlockLength, Metrics/ParameterLists
      def prepare(
        execution_id:,
        task_id:,
        call_index:,
        operation:,
        safety:,
        request:,
        logical_key: nil
      )
        lease = @guard.lease
        execution = Wire.identity(execution_id, name: 'effect execution id')
        task = Wire.identity(task_id, name: 'effect task id')
        index = EffectJournalValidation.non_negative_integer!(
          call_index,
          'effect call index'
        )
        operation_text = Wire.identity(operation, name: 'effect operation')
        safety_text = EffectJournalValidation.enum_text!(
          safety,
          @safeties,
          'effect safety'
        )
        effect_key = if logical_key
                       EffectJournalKey.logical(logical_key)
                     else
                       EffectJournalKey.build(
                         guard: @guard,
                         execution_id: execution,
                         task_id: task,
                         call_index: index,
                         operation: operation_text
                       )
                     end
        logical_key_text = effect_key
        request_bytes = @store.checkpoint_codec.state_codec.dump(request)
        request_digest = Wire.digest(
          request_bytes,
          domain: 'tamoz.sqlite.effect_request'
        )
        candidate_token = SecureRandom.uuid.freeze
        action = nil
        granted_token = nil
        @store.adapter.__send__(:transaction, operation: 'effect.prepare') do |tx|
          now = @store.adapter.__send__(:backend_time, tx, 'effect.prepare.time')
          @store.adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'effect.prepare.lease'
          )
          active_execution = tx.scalar(
            'effect.prepare.active_execution',
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
                  'effect execution is not the active graph execution'
          end
          row = EffectJournalRows.effect(tx, effect_key, 'effect.prepare.row')
          unless row
            tx.execute(
              'effect.prepare.insert',
              <<~SQL,
                INSERT INTO tamoz_effects(
                  effect_key, logical_key, thread_id, namespace, execution_id, task_id,
                  call_index, operation, safety, request_digest, status,
                  current_attempt, requires_reconciliation,
                  created_at_ms, updated_at_ms
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'prepared', 1, 0, ?, ?)
              SQL
              [
                effect_key, logical_key_text, lease.thread_id, lease.namespace, execution, task,
                index, operation_text, safety_text, request_digest, now, now
              ]
            )
            EffectAttemptLedger.insert!(
              tx,
              effect_key:,
              attempt_number: 1,
              attempt_token: candidate_token,
              attempt_identity: EffectJournalKey.attempt_identity(
                logical_key_text, 1, execution_id: execution, fence: lease.fence
              ),
              fence: lease.fence,
              attempt_ttl: @attempt_ttl,
              now:
            )
            EffectTransitionLog.append!(
              tx,
              effect_key:,
              transition: 'prepare',
              attempt_number: 1,
              actor: nil,
              evidence: { 'safety' => safety_text },
              now:
            )
            action = :execute
            granted_token = candidate_token
            next
          end

          EffectJournalKey.verify_identity!(
            row,
            lease:,
            execution_id: execution,
            task_id: task,
            call_index: index,
            operation: operation_text,
            safety: safety_text,
            request_digest:,
            logical_key:
          )
          status = row.fetch(9)
          case status
          when 'succeeded'
            action = :return
          when 'unknown'
            action = :unknown
          when 'reconcile'
            action = :reconcile
          when 'failed', 'abandoned'
            action = :failed
          when 'prepared', 'running'
            attempt = EffectJournalRows.attempt(
              tx,
              effect_key,
              row.fetch(11),
              'effect.prepare.current_attempt'
            )
            raise IntegrityError, 'effect current attempt is missing' unless attempt

            # A new fenced writer has proved that the previous owner no longer
            # controls the request. Do not make recovery wait for that dead
            # owner's wall-clock attempt deadline before classifying the effect.
            if attempt.fetch(4) > now && attempt.fetch(2) == lease.fence
              action = :wait
              next
            end
            if status == 'prepared'
              tx.execute(
                'effect.prepare.abandon_unstarted',
                <<~SQL,
                  UPDATE tamoz_effect_attempts
                  SET status = 'abandoned', completed_at_ms = ?
                  WHERE effect_key = ? AND attempt_number = ?
                    AND status = 'prepared'
                SQL
                [now, effect_key, row.fetch(11)]
              )
              EffectAttemptLedger.grant_next!(
                tx,
                row:,
                effect_key:,
                token: candidate_token,
                execution_id: execution,
                fence: lease.fence,
                attempt_ttl: @attempt_ttl,
                now:
              )
              action = :execute
              granted_token = candidate_token
            else
              case safety_text
              when 'read_only', 'idempotent'
                EffectAttemptLedger.grant_next!(
                  tx,
                  row:,
                  effect_key:,
                  token: candidate_token,
                  execution_id: execution,
                  fence: lease.fence,
                  attempt_ttl: @attempt_ttl,
                  now:
                )
                action = :execute
                granted_token = candidate_token
              when 'transactional', 'reconcilable'
                tx.execute(
                  'effect.prepare.reconcile',
                  <<~SQL,
                    UPDATE tamoz_effects
                    SET status = 'reconcile', requires_reconciliation = 1,
                        updated_at_ms = ?
                    WHERE effect_key = ?
                  SQL
                  [now, effect_key]
                )
                action = :reconcile
              when 'unsafe'
                tx.execute(
                  'effect.prepare.unknown_attempt',
                  <<~SQL,
                    UPDATE tamoz_effect_attempts
                    SET status = 'unknown', completed_at_ms = ?
                    WHERE effect_key = ? AND attempt_number = ?
                      AND status = 'running'
                  SQL
                  [now, effect_key, row.fetch(11)]
                )
                tx.execute(
                  'effect.prepare.unknown_head',
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
            raise IntegrityError, 'effect status is invalid'
          end
        end

        Tamoz::Graph::EffectDecision.new(
          action:,
          record: @record_reader.fetch(effect_key),
          attempt_token: granted_token
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
      # rubocop:enable Metrics/BlockLength, Metrics/ParameterLists
    end
    private_constant :EffectPreparation
  end
end
