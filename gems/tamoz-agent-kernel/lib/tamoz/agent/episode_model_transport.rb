# frozen_string_literal: true

require "json"
require "digest"
require "net/http"
require "uri"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P1/§4.3: the frozen episode model transport. The episode path needs the
    # EXACT request bytes it sends and the EXACT response bytes it receives —
    # that is what makes request/response digests witnessable and replayable
    # (P3 builds the witness gateway on top). The episode path uses this thin,
    # frozen OpenAI-compatible client whose request body IS the canonical frame
    # bytes (JCS), so `digest(body)` on the endpoint side equals the receipt's
    # request digest by construction.
    #
    # `endpoint` is any OpenAI-compatible base URL (e.g. a local endpoint in
    # fixture or proxy mode, or ollama's /v1 in production-lite runs). The
    # frozen request shape is a deliberate P1 contract: provider adapters that
    # need a different shape come with a digest-bound request model (P3).
    # :reek:DataClump :reek:FeatureEnvy :reek:LongParameterList :reek:TooManyMethods
    # :reek:TooManyStatements :reek:UncommunicativeVariableName :reek:UtilityFunction -- one wire boundary;
    # request and envelope handling stay together so the digests bind exactly what was sent.
    class EpisodeModelTransport
      OPENAI_COMPLETIONS_PATH = "/chat/completions"
      # The frozen request settings (P1 contract). The settings digest the
      # gateway signs and the receipt carries is computed over THIS document.
      SETTINGS = {
        "temperature" => 0,
        "stream" => false,
        "response_format" => {"type" => "json_object"}
      }.freeze

      Response = Data.define(
        :content, :request_digest, :response_digest, :usage, :settings_digest,
        :provider_configuration_digest
      )

      # The tool-calling request settings. A conversation carries native tool
      # calls, so it never asks for JSON mode.
      CONVERSATION_SETTINGS = {"temperature" => 0, "stream" => false}.freeze
      CONTEXT_WINDOW_PATTERN = /context[ _-]?(length|window)|maximum context|too many tokens|prompt is too long/i

      # One tool-calling turn as received: content, tool calls, raw provider usage and the digests binding them.
      Conversation = Data.define(
        :content, :tool_calls, :finish_reason, :usage, :request_digest, :response_digest,
        :settings_digest, :provider_configuration_digest
      )

      attr_reader :provider, :model, :provider_configuration_digest, :safety, :context_window

      def initialize(endpoint:, model:, provider: "episode_model_transport", api_key: nil,
                     timeout_seconds: 120, gateway: nil, safety: :unsafe,
                     provider_configuration_digest: nil, context_window: nil)
        @endpoint = endpoint.to_s.sub(%r{/+\z}, "")
        raise ConfigurationError, "episode model endpoint is required" if @endpoint.empty?

        @model = model.to_s
        raise ConfigurationError, "episode model id is required" if @model.empty?

        @provider = provider.to_s
        @api_key = api_key
        @timeout_seconds = timeout_seconds
        @gateway = gateway
        @safety = safety.to_sym
        @provider_configuration_digest = provider_configuration_digest || configuration_digest
        @context_window = context_window
        freeze
      end

      def inspect
        "#<#{self.class} provider=#{provider.inspect} model=#{model.inspect} " \
          "safety=#{safety.inspect} configuration=#{provider_configuration_digest.inspect}>"
      end

      def generate(stage:, system:, prompt:)
        request_bytes = build_request(system:, prompt:)
        call(request_bytes, logical_call_id: "model.generate.#{stage}")
      end

      # The frozen request model: system + user messages, temperature 0,
      # non-streaming. Canonicalized with JCS so the digest binds the exact
      # wire bytes. Returns the canonical JSON String (the HTTP body).
      def build_request(system:, prompt:)
        request = {
          "model" => @model,
          "messages" => [
            {"role" => "system", "content" => String(system)},
            {"role" => "user", "content" => String(prompt)}
          ],
          **SETTINGS
        }
        Tamoz::Core.jcs(request)
      end

      # A tool-calling conversation: the whole message history plus the tool
      # schemas, canonicalized so the digest binds the exact wire bytes.
      def converse(stage:, messages:, tools: [], tool_choice: "auto")
        raise ConfigurationError, "tool-calling conversations do not run through the witness gateway" if @gateway

        request_bytes = build_conversation(messages:, tools:, tool_choice:)
        receive_conversation(exchange(request_bytes, logical_call_id: "model.converse.#{stage}"), request_bytes)
      end

      def build_conversation(messages:, tools: [], tool_choice: "auto")
        request = {"model" => @model, "messages" => messages, **CONVERSATION_SETTINGS}
        unless tools.empty?
          request["tools"] = tools
          request["tool_choice"] = tool_choice
        end
        Tamoz::Core.jcs(request)
      end

      def conversation_settings_digest
        "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(CONVERSATION_SETTINGS))}"
      end

      def request_digest(request_bytes)
        "sha256:#{Digest::SHA256.hexdigest(request_bytes)}"
      end

      # The digest of the frozen settings the request was made under — the
      # gateway signs it into the record and the receipt carries it, so the
      # verifier can cross-check the binding (never an always-nil knob).
      def settings_digest
        "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(SETTINGS))}"
      end

      # Sends the canonical request bytes verbatim; returns the content string
      # and the exact response envelope bytes (digest-bound). The response
      # digest covers the raw envelope as received. In GATEWAY mode (P3) the
      # worker's egress is the witness gateway: the request + logical call id
      # + frame digest travel to the gateway, which rehashes, forwards to the
      # provider, and signs the binding record.
      def call(request_bytes, logical_call_id: nil, frame_digest: nil)
        envelope_bytes = exchange(request_bytes, logical_call_id:, frame_digest:)
        build_model_response(envelope_bytes, request_bytes:)
      rescue Tamoz::Core::ProtocolError, Tamoz::Core::JCS::Error, JSON::ParserError, KeyError, TypeError
        raise model_error("invalid_response", body: envelope_bytes)
      end

      private

      def exchange(request_bytes, logical_call_id: nil, frame_digest: nil)
        return gateway_exchange(request_bytes, logical_call_id:, frame_digest:) if @gateway

        headers = {"Content-Type" => "application/json"}
        headers["Authorization"] = "Bearer #{@api_key}" unless @api_key.to_s.empty?
        response = post_completion_request(request_bytes, headers:)
        envelope_bytes = response.body.to_s
        raise http_error(response, envelope_bytes) unless response.is_a?(Net::HTTPSuccess)

        envelope_bytes
      rescue URI::InvalidURIError, SocketError, SystemCallError => e
        raise model_error("transport_failure", body_bytes: e.message.to_s.bytesize)
      end

      def http_error(response, body)
        status = response.code
        window = status.to_s == "400" && body.match?(CONTEXT_WINDOW_PATTERN)
        model_error(window ? "context_window_exceeded" : "http_failure", status:, body:)
      end

      def receive_conversation(envelope_bytes, request_bytes)
        envelope = Tamoz::Core.parse_json_strict(envelope_bytes)
        choice = envelope.is_a?(Hash) && envelope.dig("choices", 0)
        message = choice.is_a?(Hash) && choice["message"]
        raise ProtocolError, "conversation response has no message" unless message.is_a?(Hash)

        Conversation.new(
          content: String(message["content"] || ""), tool_calls: tool_calls_from(message["tool_calls"]),
          finish_reason: String(choice["finish_reason"] || ""), usage: provider_usage(envelope["usage"]),
          request_digest: request_digest(request_bytes),
          response_digest: "sha256:#{Digest::SHA256.hexdigest(envelope_bytes)}",
          settings_digest: conversation_settings_digest, provider_configuration_digest:
        )
      rescue Tamoz::Core::ProtocolError, Tamoz::Core::JCS::Error, JSON::ParserError, KeyError, TypeError
        raise model_error("invalid_response", body: envelope_bytes)
      end

      def tool_calls_from(calls)
        Array(calls).map do |call|
          function = call.fetch("function")
          arguments = function.fetch("arguments")
          raise ProtocolError, "tool call arguments must be a JSON string" unless arguments.is_a?(String)

          {"id" => String(call.fetch("id")), "name" => String(function.fetch("name")), "arguments" => arguments}
        end
      end

      # The provider's own usage counts, integers only; the context engine interprets them.
      def provider_usage(raw)
        return nil unless raw.is_a?(Hash)

        counts = raw.select { |_, value| value.is_a?(Integer) && value >= 0 }
        details = raw["prompt_tokens_details"]
        cached = details.is_a?(Hash) && details["cached_tokens"]
        counts = counts.merge("prompt_tokens_details" => {"cached_tokens" => cached}) if cached.is_a?(Integer)
        counts.empty? ? nil : counts
      end

      # P3: the gateway is the transport the effect adapter calls. The frozen
      # request bytes + logical call id + frame digest are the envelope; the
      # gateway's signed record binds them to the response.
      def gateway_exchange(request_bytes, logical_call_id:, frame_digest:)
        envelope = Tamoz::Core.jcs(
          "logical_call_id" => String(logical_call_id),
          "frame_digest" => String(frame_digest),
          "provider" => @provider,
          "model" => @model,
          "settings_digest" => settings_digest,
          "request_bytes" => request_bytes
        )
        response = post_completion_request(
          envelope, headers: {"Content-Type" => "application/json"}
        )
        envelope_bytes = response.body.to_s
        unless response.is_a?(Net::HTTPSuccess)
          raise model_error("gateway_failure", status: response.code, body: envelope_bytes)
        end

        envelope_bytes
      end

      def post_completion_request(body, headers:)
        uri = URI.parse("#{@endpoint}#{OPENAI_COMPLETIONS_PATH}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.read_timeout = @timeout_seconds
        http.open_timeout = @timeout_seconds
        http.use_ssl = uri.scheme == "https"
        begin
          http.request(Net::HTTP::Post.new(uri, headers), body)
        rescue Timeout::Error, IOError, SystemCallError, SocketError, Net::ProtocolError
          raise EffectUnknownError, "model call outcome is unknown"
        end
      end

      def build_model_response(envelope_bytes, request_bytes:)
        Response.new(
          content: extract_content(envelope_bytes),
          request_digest: request_digest(request_bytes),
          response_digest: "sha256:#{Digest::SHA256.hexdigest(envelope_bytes)}",
          usage: usage_from(extract_usage_hash(envelope_bytes)),
          settings_digest: settings_digest,
          provider_configuration_digest:
        )
      end

      def configuration_digest
        Tamoz::Core.digest(
          "tamoz.agent.model.configuration.v1\n",
          {
            "provider" => @provider,
            "model" => @model,
            "endpoint" => @endpoint,
            "protocol" => "openai-compatible",
            "settings" => SETTINGS,
            "safety" => @safety.to_s
          }
        )
      end

      def model_error(code, status: nil, body: nil, body_bytes: nil)
        bytes = body.to_s
        ModelCallError.new(
          code:, status:,
          body_digest: body ? "sha256:#{Digest::SHA256.hexdigest(bytes)}" : nil,
          body_bytes: body ? bytes.bytesize : body_bytes
        )
      end

      def extract_content(bytes)
        parsed = Tamoz::Core.parse_json_strict(bytes)
        raise ProtocolError, "episode model response is not an object" unless parsed.is_a?(Hash)

        content = parsed.dig("choices", 0, "message", "content")
        if content.nil? || !content.is_a?(String)
          raise ProtocolError, "episode model response has no assistant content"
        end

        content
      end

      def extract_usage_hash(bytes)
        parsed = Tamoz::Core.parse_json_strict(bytes)
        parsed.is_a?(Hash) ? parsed.fetch("usage", {}) : {}
      end

      def usage_from(raw)
        return ModelCall::Usage.unavailable unless raw.is_a?(Hash)

        input = integer_field(raw, "prompt_tokens")
        output = integer_field(raw, "completion_tokens")
        return ModelCall::Usage.unavailable if input.nil? || output.nil?

        ModelCall::Usage.of(
          input_tokens: input.to_i,
          output_tokens: output.to_i,
          cost_microunits: 0
        )
      end

      def integer_field(raw, key)
        value = raw[key]
        value.is_a?(Integer) && value >= 0 ? value : nil
      end
    end
  end
end
