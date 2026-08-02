# frozen_string_literal: true

require "securerandom"

module Tamoz
  module Graph
    class DurableRunner
      REQUEST_PROTOCOL_VERSION = 1

      attr_reader :compiled

      def initialize(compiled)
        unless compiled.is_a?(Compiled) &&
               compiled.checkpointer.durable? &&
               compiled.checkpointer.respond_to?(:request_protocol_version) &&
               compiled.checkpointer.request_protocol_version == REQUEST_PROTOCOL_VERSION
          raise ConfigurationError,
                "DurableRunner requires a compatible durable request inbox"
        end

        @compiled = compiled
        freeze
      end

      def submit(
        payload,
        thread:,
        request_id:,
        operation: :turn,
        delivery: :queue,
        namespace: []
      )
        compiled.checkpointer.enqueue_request(
          thread_id: thread,
          namespace:,
          request_id:,
          operation:,
          payload:,
          delivery:
        )
      end

      def fetch(thread:, request_id:, namespace: [])
        compiled.checkpointer.fetch_request(
          thread_id: thread,
          namespace:,
          request_id:
        )
      end

      # Ordered durable request history for a thread (invariant 23 proofs).
      def history(thread:, namespace: [])
        compiled.checkpointer.request_history(thread_id: thread, namespace:)
      end

      def run_next(
        thread:,
        namespace: [],
        owner_id: SecureRandom.uuid,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        final_request = nil
        stale_request = nil
        stale_error = nil
        compiled.checkpointer.open_writer(
          thread_id: thread,
          namespace:,
          owner_id:,
          ttl: compiled.checkpointer.writer_ttl
        ) do |writer|
          request = writer.claim_next_request(validator: claim_validator)
          return nil unless request
          return request unless %i[claimed redirecting].include?(request.status)

          begin
            compiled.__send__(
              :execute_durable_request,
              request,
              writer:,
              concurrency:,
              context:
            )
          rescue Tamoz::StaleRequestError => error
            stale_request = request
            stale_error = error
            next
          end
          final_request = compiled.checkpointer.fetch_request(
            thread_id: thread,
            namespace:,
            request_id: request.request_id
          )
        end
        if stale_request
          final_request = terminal_fail(
            stale_request,
            reason: stale_error.message
          )
        end
        final_request
      end

      def recover(
        thread:,
        request_id:,
        namespace: [],
        owner_id: SecureRandom.uuid,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        final_request = nil
        stale_request = nil
        stale_error = nil
        compiled.checkpointer.open_writer(
          thread_id: thread,
          namespace:,
          owner_id:,
          ttl: compiled.checkpointer.writer_ttl
        ) do |writer|
          request = writer.recover_request(
            request_id:,
            validator: claim_validator
          )
          return request unless %i[claimed running redirecting].include?(request.status)

          begin
            compiled.__send__(
              :execute_durable_request,
              request,
              writer:,
              concurrency:,
              context:
            )
          rescue Tamoz::StaleRequestError => error
            stale_request = request
            stale_error = error
            next
          end
          final_request = compiled.checkpointer.fetch_request(
            thread_id: thread,
            namespace:,
            request_id:
          )
        end
        if stale_request
          final_request = terminal_fail(
            stale_request,
            reason: stale_error.message
          )
        end
        final_request
      end

      # Post-claim execution backstop (DR-4 D2): a state change between claim and
      # execute surfaced as a `StaleRequestError`; fail the claimed request through
      # the checkpointer's public fenced transition so the terminal payload is
      # byte-identical to the claim-time path. A fresh lease is acquired because the
      # runner's own writer block has already closed.
      def terminal_fail(request, reason:)
        final_request = nil
        compiled.checkpointer.open_writer(
          thread_id: request.thread_id,
          namespace: request.namespace,
          owner_id: SecureRandom.uuid,
          ttl: compiled.checkpointer.writer_ttl
        ) do |writer|
          final_request = writer.terminal_fail(
            request_id: request.request_id,
            operation: request.operation,
            reason:
          )
        end
        final_request
      end

      def deliver(
        payload,
        thread:,
        request_id:,
        operation: :turn,
        delivery: :queue,
        namespace: [],
        owner_id: SecureRandom.uuid,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        submitted = submit(
          payload,
          thread:,
          request_id:,
          operation:,
          delivery:,
          namespace:
        )
        return submitted if submitted.terminal?

        run_next(
          thread:,
          namespace:,
          owner_id:,
          concurrency:,
          context:
        )
        fetch(thread:, namespace:, request_id:)
      end

      private

      # The graph-owned staleness predicate as the pure claim/recover validator:
      # invoked with (request, checkpoint) inside the store transaction.
      def claim_validator
        lambda do |request, checkpoint|
          compiled.stale_request_reason(checkpoint, request)
        end
      end

      private_constant :REQUEST_PROTOCOL_VERSION
    end
  end
end
