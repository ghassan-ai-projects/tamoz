# frozen_string_literal: true

require "digest"
require "tamoz/core"
require "tamoz/agent/errors"
require "tamoz/agent/effect_dispatcher"

module Tamoz
  module Agent
    # P2/§4.3: the ONE journaled episode tool call. `execute_tool` is the only
    # node that executes a tool, and it executes it through here:
    #
    #   - EffectDispatcher.run journals the call under a LOGICAL key
    #     (episode, stage: "tool", slot), so a replayed attempt reuses the
    #     completed tool receipt and a crashed mid-call attempt is a typed
    #     `unknown` — no duplicate execution, no blind retry.
    #   - The request digest binds the canonical {tool_name, arguments}
    #     bytes; the result digest binds the raw result bytes.
    #   - Results (success AND refusal) are journaled as codec-safe
    #     projections so replay reconstructs the identical result.
    #
    # The node stores the result projection in `tool_results`; `rebuild_frame`
    # appends it (attributed) to the next reason call.
    class EpisodeToolCall
      OPERATION = "episode.tool.call"

      Result = Data.define(:status, :projection) do
        def succeeded? = status == :succeeded
        def unknown? = status == :unknown
        def failed? = status == :failed
      end

      def initialize(tool_port:)
        @tool_port = tool_port
      end

      # The tool port is the per-run capability host (`context.episode_tools`,
      # bound by the runner from the wire's evidence_tools_endpoint); the
      # construction-time port is the test-injection fallback. Neither → a
      # typed ConfigurationError, never a nil crash.
      def call(context:, episode_id:, slot:, tool_name:, arguments:)
        tool_port = resolve_tool_port(context)
        request_digest = digest_request(tool_name:, arguments:)
        logical = build_logical_call_key(episode_id:, slot:, request_digest:)
        outcome = dispatch_tool_call(
          context:, tool_port:, logical:, slot:, call: {tool_name:, arguments:}
        )
        map_outcome(outcome, logical:, request_digest:)
      end

      private

      def resolve_tool_port(context)
        tool_port = (context && context.episode_tools) || @tool_port
        return tool_port if tool_port&.respond_to?(:execute)

        raise ConfigurationError,
              "episode tool call requires a capability host (episode_tools)"
      end

      def digest_request(tool_name:, arguments:)
        request_bytes = Tamoz::Core.jcs(
          {"tool" => tool_name, "arguments" => arguments}
        )
        "sha256:#{Digest::SHA256.hexdigest(request_bytes)}"
      end

      def build_logical_call_key(episode_id:, slot:, request_digest:)
        ModelCall::LogicalCallKey.new(
          episode_id:, stage: "tool", slot:, request_digest:
        )
      end

      def dispatch_tool_call(context:, tool_port:, logical:, slot:, call:)
        call_index = Integer(slot)
        tool_name = call.fetch(:tool_name)
        arguments = call.fetch(:arguments)
        request = dispatch_request(slot:, tool_name:, arguments:, logical:)
        EffectDispatcher.run(
          context:,
          operation: OPERATION,
          safety: :unsafe,
          call_index:,
          request:,
          actor: "tamoz.agent.episode.execute_tool",
          logical_key: logical
        ) do
          execute_tool(tool_port, tool_name, arguments)
        end
      end

      def dispatch_request(slot:, tool_name:, arguments:, logical:)
        {
          "stage" => "tool", "slot" => Integer(slot),
          "tool" => tool_name, "arguments" => arguments,
          "logical_call_key" => logical.to_key
        }
      end

      def execute_tool(tool_port, tool_name, arguments)
        result = tool_port.execute(tool_name, arguments)
        build_effect_value(tool_name:, result:)
      end

      def build_effect_value(tool_name:, result:)
        {
          "tool" => tool_name,
          "is_error" => result.fetch("is_error", false),
          "error_code" => result["error_code"],
          "result_json" => result.fetch("json").to_s,
          "result_sha256" => "sha256:#{Digest::SHA256.hexdigest(result.fetch('json').to_s)}",
          "result_bytes" => result.fetch("json").to_s.bytesize
        }
      end

      def map_outcome(outcome, logical:, request_digest:)
        case outcome.status
        when :succeeded
          Result.new(
            status: :succeeded,
            projection: codec_projection(outcome, logical:, request_digest:)
          )
        when :unknown
          Result.new(status: :unknown, projection: nil)
        when :failed
          Result.new(status: :failed, projection: nil)
        else
          raise ProtocolError, "unexpected episode tool effect status: #{outcome.status.inspect}"
        end
      end

      def codec_projection(outcome, logical:, request_digest:)
        value = outcome.value
        projection = value.is_a?(Hash) ? value : {
          "tool" => "", "is_error" => true,
          "error_code" => "protocol_error",
          "result_json" => String(value), "result_sha256" => nil, "result_bytes" => 0
        }
        projection.merge(
          "slot" => Integer(logical.slot),
          "request_digest" => request_digest,
          "effect_key" => outcome.effect_key
        )
      end
    end
  end
end
