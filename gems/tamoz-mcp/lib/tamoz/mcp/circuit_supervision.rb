# frozen_string_literal: true

module Tamoz
  module Mcp
    # Shared circuit-breaker delegation and restart/backoff machinery behind
    # the small §8 circuit interface both Supervisor (stdio) and HttpSupervisor
    # present. Included by both rather than lifted onto a common superclass,
    # since Supervisor already subclasses MCP::Client::Stdio.
    #
    # The including class must set @circuit_store, @retired, @started,
    # @base_backoff, @max_backoff, @random, and @config, and must define
    # #connected?, #close, and #start.
    module CircuitSupervision
      BACKOFF_JITTER = 0.2
      DEFAULT_CIRCUIT_THRESHOLD = 3
      DEFAULT_RETRY_BUDGET = 1
      DEFAULT_BASE_BACKOFF = 1.0
      DEFAULT_MAX_BACKOFF = 30.0

      # Validates the four circuit/backoff constructor arguments common to
      # both supervisors, raising Tamoz::Mcp::ValidationError.
      def self.validate_parameters!(circuit_threshold:, retry_budget:, base_backoff:, max_backoff:)
        unless circuit_threshold.is_a?(Integer) && circuit_threshold >= 1
          raise ValidationError, "circuit_threshold must be an integer >= 1"
        end
        unless retry_budget.is_a?(Integer) && retry_budget >= 0
          raise ValidationError, "retry_budget must be an integer >= 0"
        end
        unless base_backoff.is_a?(Numeric) && base_backoff.finite? && base_backoff.positive?
          raise ValidationError, "base_backoff must be positive and finite"
        end
        return if max_backoff.is_a?(Numeric) && max_backoff.finite? && max_backoff.positive? &&
                  max_backoff >= base_backoff

        raise ValidationError, "max_backoff must be positive, finite, and >= base_backoff"
      end

      # Health state from the plan's lifecycle: disabled → starting → ready,
      # with degraded/open on transport failures and retired after teardown.
      def state
        return :retired if @retired
        return :disabled unless @started
        return :open if @circuit_store.open?
        return :degraded if @circuit_store.failures.positive?

        connected? ? :ready : :starting
      end

      def started?
        !!@started
      end

      # True once `circuit_threshold` consecutive transport failures have been
      # recorded. While open, every call fails typed-unavailable until `reset`.
      def open?
        @circuit_store.open?
      end

      def consecutive_failures
        @circuit_store.failures
      end

      def last_failure_kind
        @circuit_store.last_failure_kind
      end

      # Counts one transport failure toward the circuit. A successful round-trip
      # (`record_success`) resets the streak, so only *consecutive* failures open
      # the circuit. `context:` is optional typed metadata recorded for the
      # reset evidence. The threshold is evaluated inside the store's atomic
      # write.
      def record_failure(kind: :transport, context: nil)
        @circuit_store.record_failure(kind:, context:)
      end

      def record_success
        @circuit_store.record_success
      end

      # Caller-initiated circuit reset (§8): availability returns to normal.
      # Never called automatically — the design requires policy-defined
      # recovery. `evidence:` must be a Hash describing who authorized the
      # reset and why; the supervisor augments it with `scope`/`server_id`
      # and a typed `conditions_digest` of the failure state being cleared.
      def reset(evidence: nil)
        raise ValidationError, "reset evidence must be a Hash" unless evidence.nil? || evidence.is_a?(Hash)

        record = {
          "scope" => "server",
          "server_id" => @config.server_id,
          "conditions_digest" => @circuit_store.conditions_digest(@config.server_id)
        }.merge(evidence || {}).freeze
        @circuit_store.reset(evidence: record)
      end

      def reset_evidence
        @circuit_store.reset_evidence
      end

      # Exponential restart backoff with jitter, bounded by [0, max_backoff].
      # Deterministic for a seeded `random:` (tests); jittered in production.
      def backoff_delay(failures = @circuit_store.failures)
        return 0.0 unless failures.is_a?(Integer) && failures.positive?

        base = @base_backoff * (2**(failures - 1))
        base = @max_backoff if base > @max_backoff
        jitter = @random.rand(-BACKOFF_JITTER..BACKOFF_JITTER)
        (base * (1.0 + jitter)).clamp(0.0, @max_backoff)
      end

      # Kills any surviving child/session and starts a fresh one after the
      # backoff delay. Only called for recovery (read-only retry path); never
      # retries a non-idempotent call.
      def restart
        delay = backoff_delay
        close
        sleep(delay) if delay.positive?
        start
      end
    end
  end
end
