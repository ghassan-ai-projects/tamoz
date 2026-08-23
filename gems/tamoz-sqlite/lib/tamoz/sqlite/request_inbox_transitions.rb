# frozen_string_literal: true

module Tamoz
  module SQLite
    # :nodoc: Owns request state transitions and their durable transition rows.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy
    # :reek:LongParameterList :reek:MissingSafeMethod :reek:TooManyStatements
    # :reek:UtilityFunction -- transition rows and fences are explicit contracts.
    # rubocop:disable Naming/MethodParameterName -- `tx` marks transaction boundaries for BoundarySourceAudit.
    class RequestInboxTransitions
      def initialize(store, rows:, staleness:)
        @store = store
        @rows = rows
        @staleness = staleness
        freeze
      end

      def mark_request_running(lease:, request_id:, execution_id:)
        transition_request_without_checkpoint!(
          lease:,
          request_id:,
          execution_id:,
          action: :running
        )
      end

      # Control requests (mode switches) never produce a checkpoint, so their
      # completion is fenced standalone instead of riding a checkpoint append.
      def mark_request_completed(lease:, request_id:, execution_id:)
        transition_request_without_checkpoint!(
          lease:,
          request_id:,
          execution_id:,
          action: :completed
        )
      end

      # rubocop:disable Metrics/MethodLength -- the transition payload mirrors the durable wire contract.
      def request_transition(
        request_id:,
        execution_id:,
        action:,
        graph_status:,
        retryable: nil
      )
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        action_symbol = case action.to_s
                        when 'running' then :running
                        when 'completed' then :completed
                        when 'failed' then :failed
                        else
                          raise ConfigurationError,
                                'request transition action is invalid'
                        end
        response = checkpoint_codec.state_codec.dump(
          { 'graph_status' => graph_status.to_s }
        )
        {
          'request_id' => id,
          'execution_id' => Wire.identity(execution_id, name: 'execution id'),
          'action' => action_symbol.to_s,
          'response' => response,
          'response_digest' => Wire.digest(
            response,
            domain: 'tamoz.sqlite.request_response'
          ),
          'retryable' => retryable
        }.freeze
      end
      # rubocop:enable Metrics/MethodLength

      def redirect_ready?(lease:, target_execution_id:)
        target = Wire.identity(
          target_execution_id,
          name: 'redirect target execution id'
        )
        adapter.__send__(:transaction, operation: 'request.redirect_ready') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.redirect_ready.time')
          validate_transition_lease!(tx, lease, now, 'request.redirect_ready.lease')
          unresolved_effects(tx, lease, target).zero?
        end
      end

      # Called by CheckpointStore#append_checkpoint inside its open transaction.
      # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists -- fenced SQL writes stay explicit and auditable.
      def apply_request_transition_in_transaction!(
        tx,
        lease:,
        checkpoint_id:,
        transition:,
        now:,
        evidence_override: nil
      )
        request_id = transition.fetch('request_id')
        row = rows.request_row(
          tx,
          lease.thread_id,
          lease.namespace,
          request_id,
          'request.commit.row'
        )
        raise CheckpointConflictError, 'request does not exist' unless row

        plan = RequestTransitionPlan.for(
          row:, transition:, checkpoint_id:, evidence_override:
        )
        update_request_transition!(tx, lease, checkpoint_id, request_id, plan, now)
        append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id:,
          from_status: plan.from_status,
          to_status: plan.to_status,
          fence: lease.fence,
          evidence: plan.evidence,
          now:
        )
      end

      # :nodoc: Kept public for the RequestInbox facade's private compatibility seam.
      def transition_request_without_checkpoint!(
        lease:,
        request_id:,
        execution_id:,
        action:
      )
        transition = request_transition(
          request_id:,
          execution_id:,
          action:,
          graph_status: :running
        )
        row = nil
        adapter.__send__(:transaction, operation: 'request.transition') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.transition.time')
          validate_transition_lease!(tx, lease, now, 'request.transition.lease')
          transition_request_in_transaction!(tx, lease, transition, now)
          row = rows.request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            transition.fetch('request_id'),
            'request.transition.result'
          )
        end
        wire.materialize_request(row)
      end

      # :nodoc: Appends exactly one ordered durable transition row.
      def append_request_transition!(
        tx,
        thread_id:,
        namespace:,
        request_id:,
        from_status:,
        to_status:,
        fence:,
        evidence:,
        now:
      )
        index = tx.scalar(
          'request.transition.index',
          <<~SQL,
            SELECT COALESCE(MAX(transition_index) + 1, 0)
            FROM tamoz_request_transitions
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
          SQL
          [thread_id, namespace, request_id]
        )
        evidence_bytes = JSON.generate(evidence)
        tx.execute(
          'request.transition.insert',
          <<~SQL,
            INSERT INTO tamoz_request_transitions(
              thread_id, namespace, request_id, transition_index,
              from_status, to_status, fence, evidence, created_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            thread_id, namespace, request_id, index, from_status,
            to_status, fence, Wire.blob(evidence_bytes), now
          ]
        )
      end

      private

      attr_reader :rows

      def adapter = @store.adapter
      def wire = @store.wire
      def checkpoint_codec = @store.checkpoint_codec

      def validate_transition_lease!(tx, lease, now, label)
        adapter.__send__(
          :validate_lease_in_transaction!,
          tx,
          lease,
          now:,
          label:
        )
      end

      def unresolved_effects(tx, lease, target)
        tx.scalar(
          'request.redirect_ready.effects',
          <<~SQL,
            SELECT COUNT(*)
            FROM tamoz_effects
            WHERE thread_id = ? AND namespace = ? AND execution_id = ?
              AND status IN ('prepared', 'running', 'unknown', 'reconcile')
          SQL
          [lease.thread_id, lease.namespace, target]
        )
      end

      def update_request_transition!(tx, lease, checkpoint_id, request_id, plan, now)
        tx.execute(
          'request.commit.update',
          <<~SQL,
            UPDATE tamoz_requests
            SET status = ?, checkpoint_id = COALESCE(?, checkpoint_id),
                response = ?, response_digest = ?,
                terminal_error = ?, terminal_error_digest = ?,
                retryable = ?, owner_fence = ?,
                updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
              AND status = ?
          SQL
          [
            plan.to_status, checkpoint_id,
            plan.response_blob, plan.response_digest,
            plan.terminal_error_blob, plan.terminal_error_digest,
            plan.retryable_integer, lease.fence, now,
            lease.thread_id, lease.namespace, request_id, plan.from_status
          ]
        )
        raise CheckpointConflictError, 'request transition lost' unless tx.changes == 1
      end
      # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

      def transition_request_in_transaction!(tx, lease, transition, now)
        apply_request_transition_in_transaction!(
          tx,
          lease:,
          checkpoint_id: nil,
          transition:,
          now:
        )
      end
    end
    # rubocop:enable Naming/MethodParameterName
  end
end
