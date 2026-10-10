# frozen_string_literal: true

require_relative 'comms_store_rows'

module Tamoz
  module SQLite
    # Admitted channel requests after admission: their terminal settle, the durable cancellation
    # timeline, and the lookups that route a request back to its conversation.
    class CommsRequests
      include CommsStoreRows

      CANCEL_OPERATION = 'redirect'
      CANCEL_DELIVERY = 'redirect'
      # The settle kinds a terminal delivery can carry; stamped into projection_state so every
      # later reader derives the terminal task status from the SAME durable fact.
      TERMINAL_SETTLES = %w[answer failed stopped blocked].freeze

      def initialize(adapter:, checkpoints:)
        @adapter = adapter
        @checkpoints = checkpoints
      end

      # Records the settle kind the correspondent was told and releases the request's reservation,
      # so its slots return to intake only after terminal projection is durable (design §12).
      def complete_request(thread_id:, request_id:, settle_kind:)
        kind = settle_kind.to_s
        raise KeyError, "unknown settle kind #{settle_kind.inspect}" unless TERMINAL_SETTLES.include?(kind)

        transaction('comms.request.complete') do |txn|
          txn.execute('comms.request.complete', <<~SQL, [kind, thread_id, request_id])
            UPDATE tamoz_comms_requests SET projection_state = ?
            WHERE thread_id = ? AND request_id = ? AND projection_state = 'admitted'
          SQL
          txn.changes == 1 ? :released : :not_admitted
        end
      end

      def cancellation_requested?(thread_id:, request_id:)
        read('comms.request.cancel.requested') do |txn|
          !txn.first('comms.request.cancel.requested', <<~SQL, [thread_id, request_id]).nil?
            SELECT 1 FROM tamoz_comms_requests
            WHERE thread_id = ? AND request_id = ? AND cancellation_requested_at_ms IS NOT NULL
          SQL
        end
      end

      # Conversations whose admitted request a live worker lease is running right now.
      def working_conversations(surface_id:, now:)
        read('comms.request.working') do |txn|
          binds = [DEFAULT_NAMESPACE, DEFAULT_NAMESPACE, now_ms(now), surface_id]
          txn.rows('comms.request.working', <<~SQL, binds).map(&:first)
            SELECT DISTINCT c.conversation_id FROM tamoz_comms_requests c
            JOIN tamoz_requests r ON r.thread_id = c.thread_id AND r.namespace = ?
            JOIN tamoz_namespaces n ON n.thread_id = c.thread_id AND n.namespace = ? AND n.lease_expires_at_ms > ?
            WHERE c.surface_id = ? AND c.projection_state = 'admitted' AND r.status IN ('claimed', 'running')
          SQL
        end
      end

      # The current-generation admitted requests a caller-bound cancellation can target, in queue order.
      def open_request_targets(surface_id:, conversation_id:, thread_id:)
        read('comms.request.cancel.targets') do |txn|
          rows = txn.rows('comms.request.cancel.targets', <<~SQL, [surface_id, conversation_id, thread_id])
            SELECT request_id, thread_id, cancellation_requested_at_ms IS NOT NULL FROM tamoz_comms_requests
            WHERE surface_id = ? AND conversation_id = ? AND thread_id = ?
              AND projection_state = 'admitted'
            ORDER BY created_at_ms ASC, request_id ASC
          SQL
          rows.map do |request_id, row_thread_id, stopping|
            { 'request_id' => request_id, 'request_ref' => request_ref(request_id), 'thread_id' => row_thread_id,
              'stopping' => stopping == 1 }
          end
        end
      end

      # The `requested` stamp and the :cancel enqueue commit in ONE transaction, so a rollback leaves
      # neither. Without a target, every still-admitted request on the thread is stamped.
      def request_cancellation(thread_id:, request_id:, payload:, now:, target_request_id: nil)
        payload_bytes, payload_digest, input_digest = encode_request(CANCEL_OPERATION, CANCEL_DELIVERY, payload)
        transaction('comms.request.cancel') do |txn|
          stamp_cancellation_requested!(txn, thread_id:, target_request_id:, now:)
          @checkpoints.enqueue_request_in_transaction!(
            txn, thread: thread_id, encoded_namespace: DEFAULT_NAMESPACE, id: request_id,
                 operation_text: CANCEL_OPERATION, delivery_text: CANCEL_DELIVERY,
                 payload_bytes:, payload_digest:, input_digest:
          )
          :requested
        end
      end

      # The `observed` stamp, written once where the turn runner consumed the cancel. First write wins.
      def mark_cancellation_observed(thread_id:, now:)
        transaction('comms.request.cancel.observed') do |txn|
          txn.execute('comms.request.cancel.observed.stamp', <<~SQL, [now_ms(now), now_ms(now), thread_id])
            UPDATE tamoz_comms_requests
            SET cancellation_observed_at_ms = ?, updated_at_ms = ?
            WHERE thread_id = ? AND cancellation_requested_at_ms IS NOT NULL
              AND cancellation_observed_at_ms IS NULL
          SQL
          :observed
        end
      end

      # The conversation a thread routes to (via its most recent admission), for delivery projection.
      def request_conversation(thread_id:)
        read('comms.request.conversation') do |txn|
          row = txn.first('comms.request.conversation', <<~SQL, [thread_id])
            SELECT surface_id, conversation_id FROM tamoz_comms_requests
            WHERE thread_id = ? ORDER BY created_at_ms DESC LIMIT 1
          SQL
          row && { 'surface_id' => row[0], 'conversation_id' => row[1] }
        end
      end

      # Operator-wide reference scan for the reconnectable CLI view: unlike the channel's
      # caller-scoped resolution, an operator may see every match.
      def requests_by_reference(ref)
        return [] unless ref.is_a?(String) && ref.match?(REQUEST_REF_PATTERN)

        read('comms.request.ref.scan') do |txn|
          txn.rows('comms.request.ref.scan', <<~SQL, [ref[1, REQUEST_REF_WIDTH]])
            SELECT surface_id, conversation_id, request_id FROM tamoz_comms_requests
            WHERE substr(request_id, 1, #{REQUEST_REF_WIDTH}) = ?
            ORDER BY created_at_ms DESC LIMIT 25
          SQL
        end
      end

      private

      def stamp_cancellation_requested!(txn, thread_id:, target_request_id:, now:)
        binds = [now_ms(now), now_ms(now), thread_id]
        binds << target_request_id if target_request_id
        txn.execute('comms.request.cancel.stamp', <<~SQL, binds)
          UPDATE tamoz_comms_requests
          SET cancellation_requested_at_ms = ?, updated_at_ms = ?
          WHERE thread_id = ? AND projection_state = 'admitted'
            AND cancellation_requested_at_ms IS NULL
            #{' AND request_id = ?' if target_request_id}
        SQL
        return unless target_request_id

        raise Tamoz::CheckpointConflictError, 'the cancellation target is no longer admitted' unless txn.changes == 1
      end
    end
  end
end
