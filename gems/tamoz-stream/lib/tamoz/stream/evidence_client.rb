# frozen_string_literal: true

require "securerandom"
require "tamoz/core"
require "tamoz/stream/gen"

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # T3.1 (PLAN_TAMOZ_STREAM_BUILD T3.1): the EvidenceTools gRPC client — the
    # reverse channel. The stream's EvidenceTools host serves the episode's
    # read-only evidence tools, scoped by the short-lived capability token the
    # worker carries verbatim (T1.3: the worker holds NO signing secret and
    # never verifies the token — it echoes it back and the host decides).
    #
    # The client is the tamoz-side half of the token's custody: it scopes the
    # call to the request identity (episode_id/attempt_id/fence) and the
    # verified snapshot's tenant/situation/entity, bounds rows and bytes, and
    # verifies the RESULT — the echoed identity must match the call and the
    # result digest must verify under the shared evidence domain. A result
    # that fails either check is refused: the token may not be minted here,
    # but a misrouted or tampered result is refused here.
    #
    # Fail-closed construction: an episode without an endpoint or token never
    # builds a dialing client — the runner binds a refusal adapter instead, so
    # the surface stays fixed and evidence simply refuses.
    class EvidenceClient
      PROTOCOL_VERSION = "1.0"
      # The result-digest domain shared with the stream's EvidenceTools host
      # (the Go host's rule when it lands; documented with the vendored
      # contract in docs/PLAN_TAMOZ_STREAM_BUILD.md §T3).
      RESULT_DIGEST_DOMAIN = "situation-runtime/evidence/v1\n"

      MAX_ARGUMENTS_BYTES = 256 * 1024
      MAX_ID_BYTES = 256
      MAX_RESULT_RECEIVE_BYTES = 4 * 1024 * 1024

      # An evidence call refused by the host surface, the result verification,
      # or the peer. Typed (ToolError) so the capability host passes it
      # through rather than class-wrapping it.
      class EvidenceError < Tamoz::Core::ToolError
        CATEGORY = "stream_evidence"
      end

      def initialize(endpoint:, capability_token:, episode_id:, attempt_id:,
                     fence:, tenant_id:, situation_id:, situation_version:,
                     entity_id:, max_rows: nil, max_bytes: nil,
                     time_from: nil, time_until: nil,
                     traceparent: nil, tracestate: nil)
        if endpoint.nil? || endpoint.empty?
          raise EvidenceError, "evidence channel requires an endpoint"
        end
        if capability_token.nil? || capability_token.empty?
          raise EvidenceError, "evidence channel requires a capability token"
        end
        @endpoint = endpoint
        @capability_token = capability_token
        @episode_id = identity!(episode_id, "episode_id")
        @attempt_id = identity!(attempt_id, "attempt_id")
        unless fence.is_a?(Integer) && fence >= 1
          raise EvidenceError, "evidence fence must be a positive integer"
        end
        @fence = fence
        @tenant_id = identity!(tenant_id, "tenant_id")
        @situation_id = identity!(situation_id, "situation_id")
        unless situation_version.is_a?(Integer)
          raise EvidenceError, "evidence situation_version must be an integer"
        end
        @situation_version = situation_version
        @entity_id = identity!(entity_id, "entity_id")
        @max_rows = max_rows
        @max_bytes = max_bytes
        @time_from = time_from
        @time_until = time_until
        @traceparent = traceparent
        @tracestate = tracestate
        # :this_channel_is_insecure — the deployment socket is the trust
        # boundary (UDS + mTLS in production); the client never calls connect
        # explicitly (GRPC::Core::Channel#connect segfaults on this platform).
        # The receive cap is set explicitly: the client alone must never
        # accept an unbounded result even when it is reached outside the host.
        @stub = Agenticstream::Runtime::V1::EvidenceTools::Stub.new(
          endpoint, :this_channel_is_insecure,
          channel_args: {"grpc.max_receive_message_length" => MAX_RESULT_RECEIVE_BYTES}
        )
        freeze
      end

      # One evidence call. `arguments` is the tool's JSON-able argument
      # document (canonicalized before the call); the result is returned as a
      # hash with the parsed document under "json" and the host/truncation
      # facts alongside, so the capability host can bound it.
      def call(tool_name:, arguments:, call_id: SecureRandom.uuid, deadline: nil)
        tool_name = String(tool_name)
        if tool_name.empty? || tool_name.bytesize > MAX_ID_BYTES
          raise EvidenceError, "evidence tool name must be bounded and non-empty"
        end
        call_id = identity!(call_id, "call_id")
        document = Tamoz::Core.jcs(arguments)
        if document.bytesize > MAX_ARGUMENTS_BYTES
          raise EvidenceError,
                "evidence arguments exceed #{MAX_ARGUMENTS_BYTES} bytes"
        end

        request = Agenticstream::Runtime::V1::EvidenceToolCall.new(
          protocol_version: PROTOCOL_VERSION,
          episode_id: @episode_id,
          call_id:,
          tool_name:,
          arguments_json: document.to_s.b,
          capability_token: @capability_token.to_s.b,
          deadline: timestamp(deadline),
          attempt_id: @attempt_id,
          fence: @fence,
          traceparent: @traceparent,
          tracestate: @tracestate,
          tenant_id: @tenant_id,
          situation_id: @situation_id,
          entity_id: @entity_id,
          max_rows: @max_rows,
          max_bytes: @max_bytes,
          time_from: @time_from,
          time_until: @time_until,
          situation_version: @situation_version
        )
        result = call_with_deadline(request, deadline)
        if result.is_error
          code = result.error_code.to_s.byteslice(0, 256)
          code = code.gsub(/[\x00-\x1F\x7F]/, " ").strip
          raise EvidenceError,
                "evidence tool refused: #{code.empty? ? "error" : code}"
        end

        parsed = verify!(result, call_id:)
        result_hash(result, parsed)
      rescue EvidenceError
        raise
      rescue StandardError => error
        # A transport failure (unreachable host, deadline, proto error) is a
        # typed evidence failure, never a bare GRPC class leaking into the
        # episode surface.
        raise EvidenceError,
              "evidence call failed: #{error.class}"
      end

      def close = nil

      private

      def call_with_deadline(request, deadline)
        if deadline.nil?
          @stub.call(request)
        else
          @stub.call(request, deadline: deadline)
        end
      end

      # The result must be the answer to THIS call: same episode, same
      # attempt/fence, same call id — a crossed or replayed result is refused.
      # A data result must also carry a digest that verifies under the shared
      # evidence domain; a missing digest on a data result is a refusal, never
      # a silent accept. For a data result the attempt/fence echo is REQUIRED
      # (a result that omits its own attempt/fence is refused, not tolerated —
      # the identity guarantee is not weaker than the header claims).
      def verify!(result, call_id:)
        unless result.episode_id == @episode_id && result.call_id == call_id
          raise EvidenceError, "evidence result identity does not match the call"
        end
        return if result.is_error

        unless result.attempt_id == @attempt_id && result.fence == @fence
          raise EvidenceError, "evidence result identity does not match the call"
        end

        if result.result_json.nil? || result.result_json.empty?
          raise EvidenceError, "evidence result carries no document"
        end
        document = result.result_json.to_s.dup.force_encoding(Encoding::UTF_8)
        unless document.valid_encoding?
          raise EvidenceError, "evidence result is not valid UTF-8"
        end
        expected = Tamoz::Core.normalize_digest(result.result_sha256).to_s
        if expected.empty?
          raise EvidenceError, "evidence result carries no digest"
        end
        parsed = Tamoz::Core.parse_json_strict(document)
        unless Tamoz::Core.verify_digest(RESULT_DIGEST_DOMAIN, parsed, expected)
          raise EvidenceError, "evidence result digest mismatch"
        end

        parsed
      end

      def result_hash(result, parsed)
        {
          "json" => parsed,
          "truncated" => result.truncated,
          "artifact" => artifact_hash(result.artifact),
          "row_count" => result.row_count,
          "result_bytes" => result.result_bytes
        }
      end

      def artifact_hash(artifact)
        return nil if artifact.nil?

        {
          "id" => artifact.id,
          "media_type" => artifact.media_type,
          "size_bytes" => artifact.size_bytes,
          "sha256" => Tamoz::Core.normalize_digest(artifact.sha256).to_s
        }
      end

      def timestamp(value)
        return nil if value.nil?

        seconds = value.is_a?(Time) ? value.to_i : Integer(value)
        Google::Protobuf::Timestamp.new(seconds: seconds)
      end

      def identity!(value, name)
        text = String(value)
        if text.empty? || text.bytesize > MAX_ID_BYTES || text.match?(/[\x00-\x1F\x7F]/)
          raise EvidenceError, "#{name} must be a bounded control-free string"
        end

        text
      end
    end

    # T3.2: the adapter that binds one allowed tool name to the EvidenceTools
    # client inside the containment host. Arguments are canonicalized before
    # the call; the parsed result (bounded by the host) is returned. The
    # episode context's deadline and cancellation are honored: a call cannot
    # hang past the episode deadline, and a supersession cancel aborts at the
    # call boundary.
    class EvidenceToolAdapter
      def initialize(client, tool_name:)
        @client = client
        @tool_name = tool_name
        freeze
      end

      def call(arguments, context)
        check_cancellation!(context[:cancellation])
        result = @client.call(
          tool_name: @tool_name,
          arguments: arguments,
          deadline: absolute_deadline(context[:deadline])
        )
        check_cancellation!(context[:cancellation])
        result
      end

      private

      # The context deadline is on the monotonic clock; the evidence RPC needs
      # an absolute Time (for the wire field) and seconds-from-now (for the
      # gRPC option). Time.now + remaining is both. A deadline already past is
      # a typed refusal — the call never leaves, and the episode fails with
      # the typed category, not a mislabeled internal error.
      def absolute_deadline(monotonic_deadline)
        return nil unless monotonic_deadline.is_a?(Numeric)

        remaining = monotonic_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          raise EvidenceClient::EvidenceError, "evidence call deadline exceeded"
        end

        Time.now + remaining
      end

      def check_cancellation!(cancellation)
        return unless cancellation

        raise EvidenceClient::EvidenceError, "evidence call cancelled" if
          cancellation.cancelled?
      end
    end

    # The refuse-only adapter bound when the episode carries no evidence
    # channel (no endpoint or token): the surface stays fixed, evidence
    # simply refuses. Fail-closed by construction — no adapter is ever a
    # silent no-op.
    class EvidenceUnavailableAdapter
      def initialize(tool_name:)
        @tool_name = tool_name
        freeze
      end

      def call(_arguments, _context)
        raise EvidenceClient::EvidenceError,
              "evidence tool #{@tool_name} is not configured for this episode"
      end
    end
  end
end
