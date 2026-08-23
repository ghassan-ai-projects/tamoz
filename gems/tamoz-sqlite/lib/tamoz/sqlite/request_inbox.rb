# frozen_string_literal: true

require_relative 'request_inbox_rows'
require_relative 'request_inbox_enqueue_input'
require_relative 'request_inbox_enqueuer'
require_relative 'request_inbox_transitions'
require_relative 'request_inbox_claimer'
require_relative 'request_inbox_recovery'

module Tamoz
  module SQLite
    # The durable request inbox facade. It preserves the store's request API while
    # keeping enqueue, reads, claims, recovery, and transitions separately cohesive.
    class RequestInbox
      REQUEST_SELECT = RequestInboxRows::REQUEST_SELECT
      # A mode switch claims against no active checkpoint: it addresses idle
      # threads too, so it carries its own execution identity like a turn.
      FRESH_EXECUTION_OPERATIONS = %w[turn fork redirect mode_switch].freeze

      def initialize(store)
        @store = store
        staleness = RequestStaleness.new(store.checkpoint_codec.state_codec)
        @staleness = staleness
        @rows = RequestInboxRows.new(store)
        transitions = RequestInboxTransitions.new(
          store,
          rows: @rows,
          staleness:
        )
        @transitions = transitions
        @enqueuer = RequestInboxEnqueuer.new(
          store,
          rows: @rows,
          transitions:
        )
        @claimer = RequestInboxClaimer.new(
          store,
          rows: @rows,
          transitions:,
          staleness:,
          fresh_execution_operations: FRESH_EXECUTION_OPERATIONS
        )
        @recovery = RequestInboxRecovery.new(
          store,
          rows: @rows,
          transitions:,
          claimer: @claimer,
          staleness:
        )
        freeze
      end

      def enqueue_request(
        thread_id:,
        request_id:, operation:, payload:, namespace: [],
        delivery: :queue
      )
        @enqueuer.enqueue_request(
          thread_id:,
          request_id:,
          operation:,
          payload:,
          namespace:,
          delivery:
        )
      end

      # P13-A seam: the scheduler can enqueue inside its existing transaction.
      def enqueue_request_in_transaction!(
        tx,
        thread:, encoded_namespace:, id:,
        operation_text:, delivery_text:, payload_bytes:,
        payload_digest:, input_digest:
      )
        @enqueuer.enqueue_request_in_transaction!(
          tx,
          input: RequestInboxEnqueueInput.new(
            thread:,
            encoded_namespace:,
            id:,
            operation_text:,
            delivery_text:,
            payload_bytes:,
            payload_digest:,
            input_digest:
          )
        )
      end

      def fetch_request(thread_id:, request_id:, namespace: [])
        @rows.fetch_request(thread_id:, request_id:, namespace:)
      end

      def request_history(thread_id:, namespace: []) = @rows.request_history(thread_id:, namespace:)

      def pending_threads(limit: 100) = @rows.pending_threads(limit:)

      def claim_next_request(lease:, validator: nil) = @claimer.claim_next_request(lease:, validator:)

      def recover_request(lease:, request_id:, validator: nil)
        @recovery.recover_request(lease:, request_id:, validator:)
      end

      def mark_request_running(lease:, request_id:, execution_id:)
        @transitions.mark_request_running(
          lease:,
          request_id:,
          execution_id:
        )
      end

      def mark_request_completed(lease:, request_id:, execution_id:)
        @transitions.mark_request_completed(
          lease:,
          request_id:,
          execution_id:
        )
      end

      def terminal_fail(lease:, request_id:, operation:, reason:)
        @recovery.terminal_fail(lease:, request_id:, operation:, reason:)
      end

      def request_transition(
        request_id:,
        execution_id:,
        action:,
        graph_status:,
        retryable: nil
      )
        @transitions.request_transition(
          request_id:,
          execution_id:,
          action:,
          graph_status:,
          retryable:
        )
      end

      def redirect_ready?(lease:, target_execution_id:) = @transitions.redirect_ready?(lease:, target_execution_id:)

      # Called by CheckpointStore#append_checkpoint inside its open transaction.
      def apply_request_transition_in_transaction!(
        tx,
        lease:,
        checkpoint_id:,
        transition:,
        now:,
        evidence_override: nil
      )
        @transitions.apply_request_transition_in_transaction!(
          tx,
          lease:,
          checkpoint_id:,
          transition:,
          now:,
          evidence_override:
        )
      end

      private

      attr_reader :staleness

      def wire = @store.wire
      def adapter = @store.adapter
      def checkpoint_codec = @store.checkpoint_codec
      def normalize_address(...) = @store.normalize_address(...)
      def active_execution_id!(...) = @store.active_execution_id!(...)
      def latest_checkpoint_in_transaction(...) = @store.latest_checkpoint_in_transaction(...)

      def ensure_namespace_for_enqueue!(...) = @enqueuer.__send__(__method__, ...)
      def request_row(...) = @rows.request_row(...)
      def claim_binding(...) = @claimer.__send__(__method__, ...)
      def next_cancellation_generation(...) = @claimer.__send__(__method__, ...)
      def fail_if_stale!(...) = @claimer.__send__(__method__, ...)
      def terminal_fail_in_transaction!(...) = @claimer.__send__(__method__, ...)
      def transition_request_without_checkpoint!(...) = @transitions.__send__(__method__, ...)
      def append_request_transition!(...) = @transitions.__send__(__method__, ...)

      private_constant :REQUEST_SELECT
    end
  end
end
