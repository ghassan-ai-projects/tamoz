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

      def run_next(
        thread:,
        namespace: [],
        owner_id: SecureRandom.uuid,
        concurrency: Tamoz.configuration.concurrency,
        context: nil
      )
        final_request = nil
        compiled.checkpointer.open_writer(
          thread_id: thread,
          namespace:,
          owner_id:,
          ttl: compiled.checkpointer.writer_ttl
        ) do |writer|
          request = writer.claim_next_request
          return nil unless request
          return request unless %i[claimed redirecting].include?(request.status)

          compiled.__send__(
            :execute_durable_request,
            request,
            writer:,
            concurrency:,
            context:
          )
          final_request = compiled.checkpointer.fetch_request(
            thread_id: thread,
            namespace:,
            request_id: request.request_id
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
        compiled.checkpointer.open_writer(
          thread_id: thread,
          namespace:,
          owner_id:,
          ttl: compiled.checkpointer.writer_ttl
        ) do |writer|
          request = writer.recover_request(request_id:)
          compiled.__send__(
            :execute_durable_request,
            request,
            writer:,
            concurrency:,
            context:
          )
          final_request = compiled.checkpointer.fetch_request(
            thread_id: thread,
            namespace:,
            request_id:
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

      private_constant :REQUEST_PROTOCOL_VERSION
    end
  end
end
