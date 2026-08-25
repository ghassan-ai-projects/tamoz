# frozen_string_literal: true

require "digest"
require "time"
require "tamoz/core"
require "tamoz/agent/errors"
require "tamoz/agent/model_receipt"
require "tamoz/agent/reasoning_document"
require "tamoz/agent/episode_model_transport"

module Tamoz
  module Agent
    # P1/§4.3/§8.1: the ONE journaled episode model call. `reason` is the only
    # graph node that calls a model, and it calls it through here:
    #
    #   - EffectDispatcher.run journals the call under the P0B logical call key
    #     (episode, stage, slot, request digest), so a replayed attempt reuses
    #     the completed receipt and a crashed mid-call attempt is a typed
    #     `unknown` — never a blind retry and never a stale acceptance.
    #   - The transport sends the frozen canonical request bytes; the receipt's
    #     request digest IS the digest of those bytes, so an independent
    #     endpoint-side digest log equals the receipt by construction.
    #   - The journaled result is the full codec-safe call projection
    #     {content, response_digest, usage}, so replay reconstructs the same
    #     receipt without calling the provider.
    #   - The RUNNER turns the journal-verified receipt into wire model
    #     events; the graph's Context emitter rejects model event types, so a
    #     graph node cannot forge a model event (B4/§8.2).
    #
    # The node stores `{raw_response, receipt}` in graph state; `validate`
    # parses the document (reason=call, validate=parse+ground).
    class EpisodeModelCall
      OPERATION = "episode.model.reason"

      Result = Data.define(:status, :raw_response, :receipt, :outcome) do
        def succeeded? = status == :succeeded
        def unknown? = status == :unknown
        def failed? = status == :failed
      end

      # The model call only builds the receipt; the RUNNER turns receipts into
      # wire model events from the terminal state (B4: graph nodes never hold
      # any wire channel, so they cannot forge model events).
      def initialize(transport:)
        @transport = transport
      end

      def call(context:, episode_id:, invocation:, slot:, system:, prompt:, frame_digest: nil)
        request_bytes = @transport.build_request(system:, prompt:)
        request_digest = @transport.request_digest(request_bytes)
        logical = ModelCall::LogicalCallKey.new(
          episode_id:, stage: invocation.stage, slot:, request_digest:
        )
        outcome = journal_episode_model_call(
          context:, invocation:, slot:, system:, prompt:, request_bytes:, logical:, frame_digest:
        )
        map_outcome(
          outcome, logical:, invocation:, request_bytes:, frame_digest:
        )
      end

      private

      def journal_episode_model_call(
        context:, invocation:, slot:, system:, prompt:, request_bytes:, logical:, frame_digest:
      )
        EffectDispatcher.run(
          context:,
          operation: OPERATION,
          safety: :unsafe,
          call_index: Integer(slot),
          request: {
            "stage" => invocation.stage.to_s,
            "system" => system,
            "prompt" => prompt,
            "logical_call_key" => logical.to_key
          },
          actor: "tamoz.agent.episode.reason",
          logical_key: logical
        ) do
          perform_call(request_bytes, logical:, frame_digest:)
        end
      end

      def map_outcome(outcome, logical:, invocation:, request_bytes:, frame_digest:)
        case outcome.status
        when :succeeded
          projection = codec_projection(outcome)
          receipt = build_receipt(
            logical:, invocation:, projection:, request_bytes:, outcome:, frame_digest:
          )
          Result.new(
            status: :succeeded,
            raw_response: projection.fetch("content"),
            receipt:,
            outcome:
          )
        when :unknown
          Result.new(status: :unknown, raw_response: nil, receipt: nil, outcome:)
        when :failed
          Result.new(status: :failed, raw_response: nil, receipt: nil, outcome:)
        else
          raise ProtocolError, "unexpected episode model effect status: #{outcome.status.inspect}"
        end
      end

      # The journaled result is the full call projection — the transport
      # request digest, content, the digest of the exact response envelope,
      # and provider-reported usage — so a replayed run rebuilds the identical
      # receipt from stored bytes and the runner can verify the receipt's
      # request digest against the journal, not just the response side.
      def perform_call(request_bytes, logical:, frame_digest:)
        response = @transport.call(
          request_bytes, logical_call_id: logical.to_key, frame_digest:
        )
        {
          "request_digest" => @transport.request_digest(request_bytes),
          "content" => response.content,
          "response_digest" => response.response_digest,
          "usage" => usage_projection(response)
        }
      end

      def usage_projection(response)
        return nil unless response.usage.available

        {
          "input_tokens" => response.usage.input_tokens,
          "output_tokens" => response.usage.output_tokens,
          "cost_microunits" => response.usage.cost_microunits
        }
      end

      def codec_projection(outcome)
        value = outcome.value
        value.is_a?(Hash) ? value : {
          "request_digest" => "sha256:#{Digest::SHA256.hexdigest(String(value))}",
          "content" => String(value),
          "response_digest" => "sha256:#{Digest::SHA256.hexdigest(String(value))}",
          "usage" => nil
        }
      end

      def build_receipt(logical:, invocation:, projection:, request_bytes:, outcome:, frame_digest:)
        usage_hash = projection["usage"]
        usage = usage_hash ? ModelCall::Usage.of(
          input_tokens: usage_hash.fetch("input_tokens", 0),
          output_tokens: usage_hash.fetch("output_tokens", 0),
          cost_microunits: usage_hash.fetch("cost_microunits", 0)
        ) : ModelCall::Usage.unavailable
        attempt = latest_attempt(outcome)
        ModelCall::ModelReceipt.new(
          logical_call_key: logical,
          invocation: invocation,
          effect_id: logical.to_key,
          effect_key: outcome.effect_key,
          status: :succeeded,
          provider: @transport.provider,
          model: @transport.model,
          revision: nil,
          settings_digest: @transport.settings_digest,
          frame_digest: frame_digest,
          request_digest: @transport.request_digest(request_bytes),
          response_digest: projection.fetch("response_digest"),
          artifact_refs: [],
          usage: usage,
          provider_request_id: nil,
          retry_count: [outcome.attempt_number - 1, 0].max,
          started_at: iso_time(attempt&.started_at_ms),
          completed_at: iso_time(attempt&.completed_at_ms),
          error_category: nil
        )
      end

      def latest_attempt(outcome)
        record = outcome.respond_to?(:record) ? outcome.record : nil
        return nil unless record&.respond_to?(:attempts)

        record.attempts.last
      end

      def iso_time(millis)
        return nil if millis.nil?

        Time.at(millis / 1000.0).utc.iso8601
      end
    end
  end
end
