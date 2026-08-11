# frozen_string_literal: true

require 'securerandom'

module Tamoz
  module SQLite
    # :nodoc: Owns explicit recovery and the post-claim terminal-fail backstop.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:MissingSafeMethod :reek:TooManyInstanceVariables :reek:TooManyStatements -- fenced recovery.
    # rubocop:disable Naming/MethodParameterName -- BoundarySourceAudit follows `tx` helpers.
    class RequestInboxRecovery
      def initialize(store, rows:, transitions:, claimer:, staleness:)
        @store = store
        @rows = rows
        @transitions = transitions
        @claimer = claimer
        @staleness = staleness
        freeze
      end

      # Recover an interrupted claimed, running, or redirecting request under a
      # fresh lease. Validation and any stale failure stay in this transaction.
      def recover_request(lease:, request_id:, validator: nil)
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = nil
        adapter.__send__(:transaction, operation: 'request.recover') do |tx|
          row = recover_request_in_transaction(
            tx,
            lease:,
            id:,
            validator:
          )
        end
        wire.materialize_request(row)
      end

      # Public fenced terminal-fail for the post-claim execution backstop.
      # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength -- terminal fail keeps lease validation and the fenced transition atomic.
      def terminal_fail(lease:, request_id:, operation:, reason:)
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = nil
        adapter.__send__(:transaction, operation: 'request.terminal_fail') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.terminal_fail.time')
          validate_recovery_lease!(tx, lease, now, 'request.terminal_fail.lease')
          row = rows.request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            'request.terminal_fail.row'
          )
          raise CheckpointConflictError, 'request does not exist' unless row

          # A claim that raised before its durable transition leaves the request
          # `queued`; the guarded transition plan only accepts claimed/running/
          # redirecting, so route through the claimer's un-guarded fenced
          # failure, which already handles queued rows (the stale-claim path).
          if row.fetch(7) == 'queued'
            claimer.terminal_fail_in_transaction!(
              tx,
              lease:,
              row:,
              operation:,
              reason:,
              execution_id: SecureRandom.uuid,
              checkpoint_id: nil,
              now:
            )
          else
            validate_terminal_fail_status!(row)
            transitions.apply_request_transition_in_transaction!(
              tx,
              lease:,
              checkpoint_id: nil,
              transition: staleness.terminal_transition(
                request_id: id,
                execution_id: row.fetch(10),
                operation:,
                reason:
              ),
              now:,
              evidence_override: staleness.transition_evidence(
                operation:,
                reason:,
                checkpoint_id: nil
              )
            )
          end
          row = rows.request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            'request.terminal_fail.result'
          )
        end
        wire.materialize_request(row)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength

      private

      attr_reader :rows, :transitions, :claimer, :staleness

      def adapter = @store.adapter
      def wire = @store.wire

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- recovery keeps validation, stale failure, fencing, and ordering in one transaction.
      def recover_request_in_transaction(tx, lease:, id:, validator:)
        now = adapter.__send__(:backend_time, tx, 'request.recover.time')
        validate_recovery_lease!(tx, lease, now, 'request.recover.lease')
        row = rows.request_row(
          tx,
          lease.thread_id,
          lease.namespace,
          id,
          'request.recover.row'
        )
        raise CheckpointConflictError, 'request does not exist' unless row

        validate_recoverable_status!(row)
        ensure_no_earlier_request!(tx, lease, row)

        stale = claimer.fail_if_stale!(
          tx,
          lease:,
          row:,
          validator:,
          now:,
          execution_id: row.fetch(10),
          checkpoint_label: 'request.recover.latest_checkpoint',
          result_label: 'request.recover.result'
        )
        return stale if stale

        update_recovered_request!(tx, lease, id, row, now)
        transitions.append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id: id,
          from_status: row.fetch(7),
          to_status: row.fetch(7),
          fence: lease.fence,
          evidence: { 'kind' => 'recovery' },
          now:
        )
        rows.request_row(
          tx,
          lease.thread_id,
          lease.namespace,
          id,
          'request.recover.result'
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def validate_recovery_lease!(tx, lease, now, label)
        adapter.__send__(
          :validate_lease_in_transaction!,
          tx,
          lease,
          now:,
          label:
        )
      end

      def validate_recoverable_status!(row)
        return if %w[claimed running redirecting].include?(row.fetch(7))

        raise CheckpointConflictError,
              "request status #{row.fetch(7)} is not recoverable"
      end

      def ensure_no_earlier_request!(tx, lease, row)
        earlier = tx.scalar(
          'request.recover.earlier',
          <<~SQL,
            SELECT COUNT(*)
            FROM tamoz_requests
            WHERE thread_id = ? AND namespace = ?
              AND enqueue_sequence < ?
              AND status NOT IN ('completed', 'failed')
          SQL
          [lease.thread_id, lease.namespace, row.fetch(3)]
        )
        return unless earlier.positive?

        raise CheckpointConflictError,
              'request recovery would skip an earlier nonterminal request'
      end

      def update_recovered_request!(tx, lease, id, row, now)
        tx.execute(
          'request.recover.update',
          <<~SQL,
            UPDATE tamoz_requests
            SET owner_fence = ?, updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
              AND status = ?
          SQL
          [
            lease.fence, now, lease.thread_id, lease.namespace,
            id, row.fetch(7)
          ]
        )
        raise CheckpointConflictError, 'request recovery lost' unless tx.changes == 1
      end

      def validate_terminal_fail_status!(row)
        return if %w[claimed running redirecting].include?(row.fetch(7))

        raise CheckpointConflictError,
              "request status #{row.fetch(7)} is not terminal-failable"
      end
    end
    # rubocop:enable Naming/MethodParameterName
  end
end
