# frozen_string_literal: true

require 'mcp'

module Tamoz
  module Mcp
    # Supervises one remote Streamable HTTP MCP session. It presents the same
    # small lifecycle and circuit interface as Supervisor so cataloging and
    # invocation keep the same policy gates for local and remote servers.
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
    class HttpSupervisor
      BACKOFF_JITTER = 0.2
      DEFAULT_CIRCUIT_THRESHOLD = 3
      DEFAULT_RETRY_BUDGET = 1
      DEFAULT_BASE_BACKOFF = 1.0
      DEFAULT_MAX_BACKOFF = 30.0

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
        unless circuit_threshold.is_a?(Integer) && circuit_threshold >= 1
          raise ValidationError, 'circuit threshold must be an integer >= 1'
        end
        unless retry_budget.is_a?(Integer) && retry_budget >= 0
          raise ValidationError, 'retry budget must be an integer >= 0'
        end
        unless base_backoff.is_a?(Numeric) && base_backoff.finite? && base_backoff.positive?
          raise ValidationError, 'base backoff must be positive and finite'
        end
        unless max_backoff.is_a?(Numeric) && max_backoff.finite? && max_backoff.positive? &&
               max_backoff >= base_backoff
          raise ValidationError, 'max backoff must be positive, finite, and >= base backoff'
        end

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

      def state
        return :retired if @retired
        return :disabled unless @started
        return :open if @circuit_store.open?
        return :degraded if @circuit_store.failures.positive?

        connected? ? :ready : :starting
      end

      def started? = @started

      def pid = nil

      def open? = @circuit_store.open?

      def consecutive_failures = @circuit_store.failures

      def last_failure_kind = @circuit_store.last_failure_kind

      def record_failure(kind: :transport, context: nil)
        @circuit_store.record_failure(kind:, context:)
      end

      def record_success
        @circuit_store.record_success
      end

      def reset(evidence: nil)
        raise ValidationError, 'reset evidence must be a Hash' unless evidence.nil? || evidence.is_a?(Hash)

        record = {
          'scope' => 'server',
          'server_id' => @config.server_id,
          'conditions_digest' => @circuit_store.conditions_digest(@config.server_id)
        }.merge(evidence || {}).freeze
        @circuit_store.reset(evidence: record)
      end

      def reset_evidence = @circuit_store.reset_evidence

      def backoff_delay(failures = @circuit_store.failures)
        return 0.0 unless failures.is_a?(Integer) && failures.positive?

        base = @base_backoff * (2**(failures - 1))
        base = @max_backoff if base > @max_backoff
        jitter = @random.rand(-BACKOFF_JITTER..BACKOFF_JITTER)
        (base * (1.0 + jitter)).clamp(0.0, @max_backoff)
      end

      def restart
        delay = backoff_delay
        close
        sleep(delay) if delay.positive?
        start
      end

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
