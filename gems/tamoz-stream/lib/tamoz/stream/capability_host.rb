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

      # The context attributes an episode tool may see. Everything else on a
      # Tamoz::Context (effects, store, emitter, graph_runtime, interrupts)
      # is deliberately absent — a tool implementation cannot reach it.
      CONTEXT_ALLOWLIST = %i[
        run_id request_id thread_id namespace deadline cancellation clock
      ].freeze

      MAX_RESULT_BYTES = 4 * 1024 * 1024
      MAX_NAME_BYTES = 256

      def initialize(implementations)
        unless implementations.is_a?(Hash)
          raise Tamoz::ConfigurationError,
                "episode capability host requires an implementation map"
        end

        missing = PERMITTED - implementations.keys
        unless missing.empty?
          raise Tamoz::ConfigurationError,
                "episode capability host requires implementations for: #{missing.join(", ")}"
        end
        unknown = implementations.keys - PERMITTED
        unless unknown.empty?
          raise Tamoz::ConfigurationError,
                "episode capability host rejects implementations for: #{unknown.join(", ")}"
        end

        @surface = PERMITTED.to_h do |id|
          implementation = implementations.fetch(id)
          unless implementation.respond_to?(:call)
            raise Tamoz::ConfigurationError,
                  "episode tool #{id} must be bound to a callable"
          end

          [id, implementation]
        end.freeze
        freeze
      end

      attr_reader :surface

      def names
        PERMITTED
      end

      def permitted?(name)
        PERMITTED.include?(name)
      end

      # The model-visible episode surface: each tool names itself, its bounds,
      # and nothing else. The surface is fixed — an injected instruction cannot
      # discover a tool outside the allowlist.
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

      def implementation_for(name)
        implementation = @surface[name]
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
        source =
          if context.is_a?(Hash)
            context
          elsif context.nil?
            {}
          elsif context.is_a?(Tamoz::Context)
            context
          else
            raise Tamoz::ConfigurationError,
                  "episode tool context must be a metadata hash or Tamoz::Context"
          end
        CONTEXT_ALLOWLIST.to_h do |key|
          value = source.is_a?(Tamoz::Context) ? source.public_send(key) : source[key]
          [key, value]
        end.freeze
      end

      def enforce_result_bounds!(name, result)
        bytes = result.is_a?(String) ? result.bytesize : JSON.generate(result).bytesize
        return if bytes <= MAX_RESULT_BYTES

        raise Tamoz::Core::ToolError,
              "episode tool #{name} returned #{bytes} bytes; limit is #{MAX_RESULT_BYTES}"
      rescue JSON::GeneratorError
        raise Tamoz::Core::ToolError,
              "episode tool #{name} returned an unserializable result"
      end
    end
  end
end
