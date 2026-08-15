# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P1/§4.3: the frozen episode model transport. The episode path needs the
    # EXACT request bytes it sends and the EXACT response bytes it receives —
    # that is what makes request/response digests witnessable and replayable
    # (P3 builds the witness gateway on top). RubyLLM does not expose raw wire
    # bytes, so the episode path does not use RubyLLMModel: this is a thin,
    # frozen OpenAI-compatible chat client whose request body IS the canonical
    # frame bytes (JCS), so `digest(body)` on the endpoint side equals the
    # receipt's request digest by construction.
    #
    # `endpoint` is any OpenAI-compatible base URL (e.g. a local endpoint in
    # fixture or proxy mode, or ollama's /v1 in production-lite runs). The
    # frozen request shape is a deliberate P1 contract: provider adapters that
    # need a different shape come with a digest-bound request model (P3).
    class EpisodeModelTransport
      OPENAI_COMPLETIONS_PATH = "/chat/completions"

      Response = Data.define(:content, :response_bytes, :response_digest, :usage)

      attr_reader :provider, :model

      def initialize(endpoint:, model:, provider: "episode_model_transport", api_key: nil, timeout_seconds: 120)
        @endpoint = endpoint.to_s.sub(%r{/+\z}, "")
        raise ConfigurationError, "episode model endpoint is required" if @endpoint.empty?

        @model = model.to_s
        raise ConfigurationError, "episode model id is required" if @model.empty?

        @provider = provider.to_s
        @api_key = api_key
        @timeout_seconds = timeout_seconds
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
          "temperature" => 0,
          "stream" => false,
          # OpenAI-standard JSON mode: the provider returns a raw JSON object
          # (no markdown fences), which the strict v2 parser requires.
          "response_format" => {"type" => "json_object"}
        }
        Tamoz::Core.jcs(request)
      end

      def request_digest(request_bytes)
        "sha256:#{Digest::SHA256.hexdigest(request_bytes)}"
      end

      # Sends the canonical request bytes verbatim; returns the content string
      # and the exact response envelope bytes (digest-bound). The response
      # digest covers the raw envelope as received.
      def call(request_bytes)
        uri = URI.parse("#{@endpoint}#{OPENAI_COMPLETIONS_PATH}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.read_timeout = @timeout_seconds
        http.open_timeout = @timeout_seconds
        http.use_ssl = uri.scheme == "https"

        headers = {"Content-Type" => "application/json"}
        headers["Authorization"] = "Bearer #{@api_key}" unless @api_key.to_s.empty?

        response = http.request(Net::HTTP::Post.new(uri, headers), request_bytes)
        envelope_bytes = response.body.to_s
        unless response.is_a?(Net::HTTPSuccess)
          raise ProtocolError,
                "episode model endpoint returned #{response.code}: #{envelope_bytes.byteslice(0, 512)}"
        end

        parsed = Tamoz::Core.parse_json_strict(envelope_bytes)
        content = parsed.dig("choices", 0, "message", "content")
        if content.nil? || !content.is_a?(String)
          raise ProtocolError, "episode model response has no assistant content"
        end

        usage = usage_from(parsed.fetch("usage", {}))
        Response.new(
          content: content,
          response_bytes: envelope_bytes,
          response_digest: "sha256:#{Digest::SHA256.hexdigest(envelope_bytes)}",
          usage:
        )
      end

      private

      def usage_from(raw)
        input = integer_field(raw, "prompt_tokens")
        output = integer_field(raw, "completion_tokens")
        return ModelCall::Usage.unavailable if input.nil? && output.nil?

        ModelCall::Usage.of(
          input_tokens: input.to_i,
          output_tokens: output.to_i,
          cost_microunits: 0
        )
      end

      def integer_field(raw, key)
        value = raw[key]
        value.is_a?(Numeric) ? value.to_i : nil
      end
    end
  end
end
