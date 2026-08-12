# frozen_string_literal: true

module Tamoz
  module SQLite
    # :nodoc: Fenced claim/stale-failure owner. :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy
    # rubocop:disable Naming/MethodParameterName -- tx boundary. :reek:LongParameterList :reek:MissingSafeMethod
    # :reek:RepeatedConditional :reek:TooManyInstanceVariables :reek:TooManyStatements :reek:UtilityFunction
    class RequestInboxClaimer
      def initialize(store, rows:, transitions:, staleness:, fresh_execution_operations:)
        @store = store
        @rows = rows
        @transitions = transitions
        @staleness = staleness
        @fresh_execution_operations = fresh_execution_operations
        freeze
      end

      # Claim the oldest queued request under the lease. A validator runs inside
      # this transaction, so stale work becomes failed without an observable claim.
      def claim_next_request(lease:, validator: nil)
        execution_id = SecureRandom.uuid.freeze
        row = nil
        adapter.__send__(:transaction, operation: 'request.claim') do |tx|
          row = claim_request_in_transaction(tx, lease:, validator:, execution_id:)
        end
        row && wire.materialize_request(row)
      end

      # The staleness verdict that means EARLY, not invalid: a fresh turn whose
      # thread has not settled yet arrived while earlier work was still running
      # or waiting on a human. It is left queued; the string is the graph's
      # RequestStaleness verdict for exactly that case.
      EARLY_TURN_REASON = 'latest checkpoint is not terminal'
      # Only turns defer. A fork is an operator action on a specific execution;
      # failing it loudly at claim is the feedback the operator needs.
      EARLY_TURN_OPERATIONS = %w[turn].freeze

      # :nodoc: Shared by claim and recovery while their transaction is open.
      # rubocop:disable Metrics/ParameterLists -- the validation context is the durable claim contract.
      def fail_if_stale!(
        tx,
        lease:,
        row:,
        validator:,
        now:,
        execution_id:,
        checkpoint_label:,
        result_label:
      )
        return nil unless validator

        checkpoint = @store.latest_checkpoint_in_transaction(tx, lease.thread_id, lease.namespace, checkpoint_label)
        reason = @staleness.reason_for(validator, wire.materialize_request(row), checkpoint)
        return nil unless reason

        terminal_fail_in_transaction!(
          tx,
          lease:,
          row:,
          operation: row.fetch(5).to_sym,
          reason:,
          execution_id:,
          checkpoint_id: checkpoint&.id,
          now:
        )
        rows.request_row(tx, lease.thread_id, lease.namespace, row.fetch(2), result_label)
      end
      # rubocop:enable Metrics/ParameterLists

      # :nodoc: Single atomic request failure inside claim or recovery.
      # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists -- one fenced failure keeps the atomic write and transition together.
      def terminal_fail_in_transaction!(
        tx,
        lease:,
        row:,
        operation:,
        reason:,
        execution_id:,
        checkpoint_id:,
        now:
      )
        payload = @staleness.terminal_payload(operation:, reason:)
        tx.execute(
          'request.terminal_fail',
          <<~SQL,
            UPDATE tamoz_requests
            SET status = 'failed',
                execution_id = ?,
                response = NULL, response_digest = NULL,
                terminal_error = ?, terminal_error_digest = ?,
                retryable = NULL, owner_fence = ?,
                updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
              AND status = ?
          SQL
          [
            execution_id,
            Wire.blob(payload),
            Wire.digest(payload, domain: 'tamoz.sqlite.request_error'),
            lease.fence, now,
            lease.thread_id, lease.namespace, row.fetch(2),
            row.fetch(7)
          ]
        )
        raise CheckpointConflictError, 'request terminal fail lost' unless tx.changes == 1

        transitions.append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id: row.fetch(2),
          from_status: row.fetch(7),
          to_status: 'failed',
          fence: lease.fence,
          evidence: @staleness.transition_evidence(
            operation:,
            reason:,
            checkpoint_id:
          ),
          now:
        )
      end
      # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

      # :nodoc: Kept public for the RequestInbox facade's private compatibility seam.
      def claim_binding(tx, lease:, operation:, execution_id:)
        redirect = operation == 'redirect'
        RequestClaimBinding.new(
          status: redirect ? 'redirecting' : 'claimed',
          execution_id: if fresh_execution_operations.include?(operation)
                          execution_id
                        else
                          @store.active_execution_id!(tx, lease, 'request.claim.active_execution')
                        end,
          target_execution_id: redirect ? @store.active_execution_id!(tx, lease, 'request.claim.redirect_target') : nil,
          cancellation_generation: redirect ? next_cancellation_generation(tx, lease) : nil
        )
      end

      # :nodoc: Kept public for the RequestInbox facade's private compatibility seam.
      def next_cancellation_generation(tx, lease)
        tx.scalar(
          'request.claim.cancellation_generation',
          <<~SQL,
            SELECT COALESCE(MAX(cancellation_generation), 0) + 1
            FROM tamoz_requests
            WHERE thread_id = ? AND namespace = ?
          SQL
          [lease.thread_id, lease.namespace]
        )
      end

      private

      attr_reader :rows, :transitions, :fresh_execution_operations

      def adapter = @store.adapter
      def wire = @store.wire

      def claim_request_in_transaction(tx, lease:, validator:, execution_id:)
        now = adapter.__send__(:backend_time, tx, 'request.claim.time')
        validate_claim_lease!(tx, lease, now)
        candidate_rows(tx, lease).each do |row|
          return row unless row.fetch(7) == 'queued'

          if validator
            checkpoint = @store.latest_checkpoint_in_transaction(
              tx, lease.thread_id, lease.namespace, 'request.claim.latest_checkpoint'
            )
            reason = @staleness.reason_for(validator, wire.materialize_request(row), checkpoint)
            if reason
              next if early_turn?(row, reason)

              return fail_stale_claim!(tx, lease:, row:, reason:, checkpoint:, now:, execution_id:)
            end
          end

          return claim_queued_request!(tx, lease:, row:, execution_id:, now:)
        end
        nil
      end

      # A queued turn whose only verdict is "the checkpoint has not settled"
      # is deferred, not failed: the message arrived while the thread was
      # busy, and killing it would drop work the sender sees as accepted.
      # Deferring also unblocks whatever sits behind it — a resume answering
      # the open turn must reach the claim ahead of the next fresh turn.
      def early_turn?(row, reason)
        EARLY_TURN_OPERATIONS.include?(row.fetch(5)) && reason == EARLY_TURN_REASON
      end

      def fail_stale_claim!(tx, lease:, row:, reason:, checkpoint:, now:, execution_id:) # rubocop:disable Metrics/ParameterLists -- one atomic stale failure keeps the write and transition together.
        terminal_fail_in_transaction!(
          tx,
          lease:,
          row:,
          operation: row.fetch(5).to_sym,
          reason:,
          execution_id:,
          checkpoint_id: checkpoint&.id,
          now:
        )
        rows.request_row(tx, lease.thread_id, lease.namespace, row.fetch(2), 'request.claim.result')
      end

      def validate_claim_lease!(tx, lease, now)
        adapter.__send__(
          :validate_lease_in_transaction!,
          tx,
          lease,
          now:,
          label: 'request.claim.lease'
        )
      end

      # The oldest non-terminal requests, oldest first. More than one row is
      # needed because an early turn is skipped and the claim must see what
      # waits behind it; the scan is bounded so a backed-up inbox never turns
      # the claim into a table walk.
      def candidate_rows(tx, lease, limit: 8) # rubocop:disable Naming/MethodParameterName
        tx.rows(
          'request.claim.candidates',
          <<~SQL,
            #{RequestInboxRows::REQUEST_SELECT}
            WHERE thread_id = ? AND namespace = ?
              AND status NOT IN ('completed', 'failed')
            ORDER BY enqueue_sequence
            LIMIT ?
          SQL
          [lease.thread_id, lease.namespace, limit]
        )
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- claim update and transition share one fence.
      def claim_queued_request!(tx, lease:, row:, execution_id:, now:)
        binding = claim_binding(tx, lease:, operation: row.fetch(5), execution_id:)
        tx.execute(
          'request.claim.update',
          <<~SQL,
            UPDATE tamoz_requests
            SET status = ?, execution_id = ?, target_execution_id = ?,
                cancellation_generation = ?, owner_fence = ?,
                updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
              AND status = 'queued'
          SQL
          [
            binding.status, binding.execution_id, binding.target_execution_id,
            binding.cancellation_generation, lease.fence, now,
            lease.thread_id, lease.namespace, row.fetch(2)
          ]
        )
        raise CheckpointConflictError, 'request claim lost' unless tx.changes == 1

        transitions.append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id: row.fetch(2),
          from_status: 'queued',
          to_status: binding.status,
          fence: lease.fence,
          evidence: {
            'kind' => 'claim',
            'target_execution_id' => binding.target_execution_id,
            'cancellation_generation' => binding.cancellation_generation
          },
          now:
        )
        rows.request_row(tx, lease.thread_id, lease.namespace, row.fetch(2), 'request.claim.result')
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
    end
    # rubocop:enable Naming/MethodParameterName
  end
end
