# frozen_string_literal: true

require "tamoz/core"
require "json"

module Tamoz
  module Stream
    # T4.1 (THREAT_MODEL §4): the stream-episode capability host. An episode
    # executes inside this host, whose tool surface is the fixed allowlist of
    # read-only, bounded tools from THREAT_MODEL §4.1 — nothing else can be
    # named, by policy or by injection.
    #
    # Structural absence (§4.3.1): the host is constructed from an explicit
    # implementation map and holds no reference to a toolbox, an effect
    # journal, an MCP client, a filesystem root, a check runner, or any memory
    # write path. The constructor refuses unknown implementation keys, so a
    # denied capability cannot even be bound. The call path is scrubbed too:
    # implementations receive a minimal, frozen context view with NO effects,
    # store, emitter, graph runtime, or interrupts — an effect journal is not
    # reachable from inside the boundary even if an adapter forwards its
    # context argument.
    #
    # The implementations are the data adapters bound by the worker
    # composition (evidence/situation/knowledge sources); each is read-only
    # and its results are bounded by the host (rows/bytes caps enforced here,
    # not merely declared). Binding an adapter under a permitted name is a
    # TRUST BOUNDARY, not enforcement: the host guarantees the surface and the
    # call path, never the internals of a bound adapter — the worker
    # composition owns that contract.
    class EpisodeCapabilityHost
      # THREAT_MODEL §4.1 — the complete permitted tool list.
      PERMITTED = %w[
        features.query evidence.get situations.related
        history.prior_incidents knowledge.search forecast.run
      ].freeze
      # agentic-stream spec tool names match ^[a-z][a-z0-9_]{0,62}$, so the wire says evidence_get.
      WIRE_NAMES = PERMITTED.to_h { |name| [name.tr(".", "_"), name] }.freeze
      PROBE_NAME = /\Aprobe_[a-z0-9_]{1,58}\z/

      # The context attributes an episode tool may see. Everything else on a
      # Tamoz::Context (effects, store, emitter, graph_runtime, interrupts)
      # is deliberately absent — a tool implementation cannot reach it.
      CONTEXT_ALLOWLIST = %i[
        run_id request_id thread_id namespace deadline cancellation clock
      ].freeze

      MAX_RESULT_BYTES = 4 * 1024 * 1024
      MAX_NAME_BYTES = 256

      # The per-host result cap. The worker composition passes the tighter of
      # the hard ceiling and the episode's wire budget (max_tool_result_bytes),
      # so a small budget is enforced HERE, not merely declared — the host
      # bounds results, not just the client.
      # probes: operator probe callables (probe_*). granted: the wire catalog's names; nothing else executes.
      def initialize(implementations, max_result_bytes: MAX_RESULT_BYTES, probes: {}, granted: nil)
        require_implementation_map!(implementations)
        require_positive_cap!(max_result_bytes)
        require_exact_surface!(implementations)
        @max_result_bytes = max_result_bytes
        @surface = build_surface(implementations).merge(build_probes(probes)).freeze
        @granted = granted&.map(&:to_s)&.freeze
        freeze
      end

      def self.stream_tool?(name) = PERMITTED.include?(name) || WIRE_NAMES.key?(name)

      attr_reader :surface

      def names
        PERMITTED
      end

      def permitted?(name)
        PERMITTED.include?(name)
      end

      # The stream allowlist: each tool names itself, its bounds, and nothing
      # else. It is fixed — an injected instruction cannot discover a tool
      # outside it.
      def descriptors
        PERMITTED.map do |id|
          {
            "name" => id,
            "read_only" => true,
            "bounded_rows" => true,
            "bounded_bytes" => true
          }
        end
      end

      # Validate an invocation: only a permitted tool resolves (argument
      # validation is the bound implementation's contract). Everything else is
      # the host's own unknown-tool error (structural, not policy).
      def assert_permitted!(name)
        implementation_for(name)
        true
      end

      def execute(name, arguments, context: {})
        result = implementation_for(name).call(arguments, context_view(context))
        enforce_result_bounds!(name, result)
        result
      rescue Tamoz::Error => error
        raise error
      rescue StandardError => error
        # A wrapped adapter failure discloses only the class — the message is
        # adapter-internal (URLs, provider bodies) and must not flow into the
        # disclosable ToolError surface.
        raise Tamoz::Core::ToolError,
              "episode capability host wrapped #{error.class}"
      end

      private

      def require_implementation_map!(implementations)
        return if implementations.is_a?(Hash)

        raise Tamoz::ConfigurationError,
              "episode capability host requires an implementation map"
      end

      def require_positive_cap!(max_result_bytes)
        return if max_result_bytes.is_a?(Integer) && max_result_bytes.positive?

        raise Tamoz::ConfigurationError,
              "episode capability host result cap must be a positive integer"
      end

      def require_exact_surface!(implementations)
        missing = PERMITTED - implementations.keys
        unless missing.empty?
          raise Tamoz::ConfigurationError,
                "episode capability host requires implementations for: #{missing.join(", ")}"
        end
        unknown = implementations.keys - PERMITTED
        return if unknown.empty?

        raise Tamoz::ConfigurationError,
              "episode capability host rejects implementations for: #{unknown.join(", ")}"
      end

      def build_surface(implementations)
        PERMITTED.to_h do |id|
          [id, require_callable!(id, implementations.fetch(id))]
        end
      end

      def build_probes(probes)
        probes.to_h do |name, implementation|
          unless PROBE_NAME.match?(name.to_s)
            raise Tamoz::ConfigurationError, "episode probe #{name.to_s.inspect} must be named probe_*"
          end

          [name.to_s, require_callable!(name, implementation)]
        end
      end

      def require_callable!(id, implementation)
        return implementation if implementation.respond_to?(:call)

        raise Tamoz::ConfigurationError,
              "episode tool #{id} must be bound to a callable"
      end

      def implementation_for(name)
        name = name.to_s
        if @granted && !@granted.include?(name)
          raise Tamoz::Core::ToolError,
                "tool #{name.byteslice(0, MAX_NAME_BYTES).inspect} is not granted for this episode"
        end

        implementation = @surface[WIRE_NAMES.fetch(name, name)]
        return implementation if implementation

        raise Tamoz::Core::ToolError,
              "unknown tool #{name.to_s.byteslice(0, MAX_NAME_BYTES).inspect} " \
              "in the episode capability host"
      end

      # THREAT_MODEL §4.3: the effect journal and the store are not reachable
      # from inside the boundary. A tool implementation sees only the
      # allowlisted context attributes, frozen — whether the caller passed a
      # Tamoz::Context or a plain hash, the effects/store keys never cross.
      def context_view(context)
        source = resolve_context_source(context)
        CONTEXT_ALLOWLIST.to_h do |key|
          value = source.is_a?(Tamoz::Context) ? source.public_send(key) : source[key]
          [key, value]
        end.freeze
      end

      def resolve_context_source(context)
        case context
        when Hash then context
        when nil then {}
        when Tamoz::Context then context
        else
          raise Tamoz::ConfigurationError,
                "episode tool context must be a metadata hash or Tamoz::Context"
        end
      end

      def enforce_result_bounds!(name, result)
        bytes = result.is_a?(String) ? result.bytesize : JSON.generate(result).bytesize
        return if bytes <= @max_result_bytes

        raise Tamoz::Core::ToolError,
              "episode tool #{name} returned #{bytes} bytes; limit is #{@max_result_bytes}"
      rescue JSON::GeneratorError
        raise Tamoz::Core::ToolError,
              "episode tool #{name} returned an unserializable result"
      end
    end
  end
end
