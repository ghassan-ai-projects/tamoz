# frozen_string_literal: true

require 'mcp'

module Tamoz
  module Mcp
    # Supervises one remote Streamable HTTP MCP session. It presents the same
    # small lifecycle and circuit interface as Supervisor so cataloging and
    # invocation keep the same policy gates for local and remote servers.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
    class HttpSupervisor
      include CircuitSupervision

      DEFAULT_CIRCUIT_THRESHOLD = CircuitSupervision::DEFAULT_CIRCUIT_THRESHOLD
      DEFAULT_RETRY_BUDGET = CircuitSupervision::DEFAULT_RETRY_BUDGET
      DEFAULT_BASE_BACKOFF = CircuitSupervision::DEFAULT_BASE_BACKOFF
      DEFAULT_MAX_BACKOFF = CircuitSupervision::DEFAULT_MAX_BACKOFF

      attr_reader :config, :circuit_threshold, :retry_budget

      def initialize(
        config,
        environ: ENV,
        circuit_threshold: DEFAULT_CIRCUIT_THRESHOLD,
        retry_budget: DEFAULT_RETRY_BUDGET,
        base_backoff: DEFAULT_BASE_BACKOFF,
        max_backoff: DEFAULT_MAX_BACKOFF,
        random: Random.new,
        circuit_store: nil
      )
        unless config.is_a?(ServerConfig) && config.transport == :http
          raise ValidationError, 'HttpSupervisor requires an HTTP ServerConfig'
        end
        CircuitSupervision.validate_parameters!(circuit_threshold:, retry_budget:, base_backoff:, max_backoff:)

        @config = config
        @environ = environ
        @circuit_threshold = circuit_threshold
        @retry_budget = retry_budget
        @base_backoff = base_backoff.to_f
        @max_backoff = max_backoff.to_f
        @random = random
        @circuit_store = circuit_store || MemoryCircuitStore.new(threshold: circuit_threshold)
        @transport = nil
        @started = false
        @retired = false
        @request_sent = false
      end

      def pid = nil

      def start
        raise ProtocolError, 'MCP HTTP supervisor already started' if @started

        @transport = MCP::Client::HTTP.new(
          url: @config.endpoint,
          headers: resolved_headers,
          max_message_bytes: @config.budgets.max_output_bytes
        )
        @started = true
        @retired = false
        nil
      rescue LoadError => e
        raise ProtocolError, "The MCP HTTP client dependencies are unavailable: #{e.message}"
      end

      def connect(client_info: nil, protocol_version: nil, capabilities: {})
        start unless started?
        @transport.connect(client_info:, protocol_version:, capabilities:)
      end

      def connected?
        @transport ? @transport.connected? : false
      end

      def send_request(request:, &)
        @request_sent = true
        @transport.send_request(request:, &)
      end

      def send_notification(notification:)
        @request_sent = true
        @transport.send_notification(notification:)
      end

      def request_sent? = @request_sent

      def stderr_tail = nil

      def close
        @retired = true
        return unless @transport

        @transport.close
      ensure
        @transport = nil
        @started = false
      end

      private

      def resolved_headers
        @config.headers.merge(
          @config.credential_headers.to_h do |header, ref|
            value = @environ[ref]
            raise ValidationError, "credential ref #{ref} is not set in the operator environment" if value.nil?

            [header, value]
          end
        )
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
  end
end
