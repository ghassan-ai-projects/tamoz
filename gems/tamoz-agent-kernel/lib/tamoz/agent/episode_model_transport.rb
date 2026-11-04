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
      TRANSCRIPTION_PATH = "/audio/transcriptions"
      SPEECH_PATH = "/audio/speech"
      MAX_TRANSCRIPT_CHARACTERS = 100_000
      MAX_SPEECH_BYTES = 2_000_000
      # The frozen request settings (P1 contract). The settings digest the
      # gateway signs and the receipt carries is computed over THIS document.
      SETTINGS = {
        "temperature" => 0,
        "stream" => false,
        "response_format" => {"type" => "json_object"}
      }.freeze

      Response = Data.define(
        :content, :request_digest, :response_digest, :usage, :settings_digest,
        :provider_configuration_digest, :provider_retries
      )

      # A rate-limited or briefly unavailable provider answers before it acts, so the same request may be sent again.
      RETRYABLE_STATUSES = %w[429 503].freeze
      RETRY_PAUSES = [2, 6].freeze
      MAX_RETRY_PAUSE = 30

      # The tool-calling request settings. A conversation carries native tool
      # calls, so it never asks for JSON mode.
      CONVERSATION_SETTINGS = {"temperature" => 0, "stream" => false}.freeze
      CONTEXT_WINDOW_PATTERN = /context[ _-]?(length|window)|maximum context|too many tokens|prompt is too long/i

      # One tool-calling turn as received: content, tool calls, raw provider usage and the digests binding them.
      Conversation = Data.define(
        :content, :tool_calls, :finish_reason, :usage, :request_digest, :response_digest,
        :settings_digest, :provider_configuration_digest
      )

      Transcript = Data.define(:text, :request_digest, :response_digest, :provider_configuration_digest)
      Speech = Data.define(:audio, :media_type, :request_digest)

      attr_reader :provider, :model, :provider_configuration_digest, :safety, :context_window, :timeout_seconds

      # pause: receives the seconds to wait before a retried request; tests pass a recorder.
      def initialize(endpoint:, model:, provider: "episode_model_transport", api_key: nil,
                     timeout_seconds: 120, gateway: nil, safety: :unsafe,
                     provider_configuration_digest: nil, context_window: nil, pause: nil)
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
        @pause = pause || ->(seconds) { sleep(seconds) }
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
        envelope_bytes, = exchange(request_bytes, logical_call_id: "model.converse.#{stage}")
        receive_conversation(envelope_bytes, request_bytes)
      end

      def build_conversation(messages:, tools: [], tool_choice: "auto")
        request = {"model" => @model, "messages" => messages, **CONVERSATION_SETTINGS}
        unless tools.empty?
          request["tools"] = tools
          request["tool_choice"] = tool_choice
        end
        Tamoz::Core.jcs(request)
      end

      # The boundary comes from the audio's digest, so the same audio is the same request bytes.
      def transcribe(audio:, filename:, media_type:)
        raise ConfigurationError, "transcription does not run through the witness gateway" if @gateway

        audio_digest = Digest::SHA256.hexdigest(audio)
        boundary = "tamoz-#{audio_digest[0, 32]}"
        headers = {"Content-Type" => "multipart/form-data; boundary=#{boundary}"}
        headers["Authorization"] = "Bearer #{@api_key}" unless @api_key.to_s.empty?
        upload = Wire.transcription_body(@model, audio, filename, media_type, boundary)
        response = post_request(TRANSCRIPTION_PATH, upload, headers:)
        body = response.body.to_s
        raise http_error(response, body) unless response.is_a?(Net::HTTPSuccess)

        Transcript.new(text: transcript_text(body), request_digest: transcription_digest(audio_digest),
                       response_digest: Wire.sha256(body), provider_configuration_digest:)
      rescue URI::InvalidURIError => e
        raise model_error("transport_failure", body_bytes: e.message.to_s.bytesize)
      end

      def transcription_digest(audio_digest)
        Tamoz::Core.digest("tamoz.agent.transcription.v1\n", {"model" => @model, "audio" => "sha256:#{audio_digest}"})
      end

      def speak(text:, voice:)
        raise ConfigurationError, "speech does not run through the witness gateway" if @gateway
        raise ConfigurationError, "speech needs a voice" if voice.to_s.empty?

        request = Tamoz::Core.jcs("model" => @model, "input" => String(text), "voice" => String(voice),
                                  "response_format" => "mp3")
        headers = {"Content-Type" => "application/json"}
        headers["Authorization"] = "Bearer #{@api_key}" unless @api_key.to_s.empty?
        status, type, audio = post_bounded(SPEECH_PATH, request, headers:, max_bytes: MAX_SPEECH_BYTES)
        raise model_error("http_failure", status:, body: audio) unless status.start_with?("2")
        raise model_error("invalid_response", body: audio) unless type.start_with?("audio/mpeg") && Wire.mp3?(audio)

        Speech.new(audio:, media_type: "audio/mpeg", request_digest: speech_digest(text, voice))
      rescue URI::InvalidURIError => e
        raise model_error("transport_failure", body_bytes: e.message.to_s.bytesize)
      end

      def speech_digest(text, voice)
        Tamoz::Core.digest("tamoz.agent.speech.v1\n",
                           {"model" => @model, "voice" => String(voice), "text" => String(text)})
      end

      def conversation_settings_digest = Wire.sha256(Tamoz::Core.jcs(CONVERSATION_SETTINGS))

      def request_digest(request_bytes) = Wire.sha256(request_bytes)

      # The digest of the frozen settings the request was made under — the
      # gateway signs it into the record and the receipt carries it, so the
      # verifier can cross-check the binding (never an always-nil knob).
      def settings_digest = Wire.sha256(Tamoz::Core.jcs(SETTINGS))

      # Sends the canonical request bytes verbatim; returns the content string
      # and the exact response envelope bytes (digest-bound). The response
      # digest covers the raw envelope as received. In GATEWAY mode (P3) the
      # worker's egress is the witness gateway: the request + logical call id
      # + frame digest travel to the gateway, which rehashes, forwards to the
      # provider, and signs the binding record.
      # max_retries bounds how often a 429 or 503 is sent again; the retries used travel in the response.
      def call(request_bytes, logical_call_id: nil, frame_digest: nil, max_retries: 0)
        envelope_bytes, retries = exchange(request_bytes, logical_call_id:, frame_digest:, max_retries:)
        build_model_response(envelope_bytes, request_bytes:, retries:)
      rescue Tamoz::Core::ProtocolError, Tamoz::Core::JCS::Error, JSON::ParserError, KeyError, TypeError
        raise model_error("invalid_response", body: envelope_bytes)
      end

      private

      # Returns [envelope_bytes, retries_used].
      def exchange(request_bytes, logical_call_id: nil, frame_digest: nil, max_retries: 0)
        return [gateway_exchange(request_bytes, logical_call_id:, frame_digest:), 0] if @gateway

        headers = {"Content-Type" => "application/json"}
        headers["Authorization"] = "Bearer #{@api_key}" unless @api_key.to_s.empty?
        send_with_retries(request_bytes, headers, max_retries)
      rescue URI::InvalidURIError, SocketError, SystemCallError => e
        raise model_error("transport_failure", body_bytes: e.message.to_s.bytesize)
      end

      def send_with_retries(request_bytes, headers, max_retries)
        retries = 0
        loop do
          response = post_completion_request(request_bytes, headers:)
          return [response.body.to_s, retries] if response.is_a?(Net::HTTPSuccess)
          raise http_error(response, response.body.to_s) unless retries < max_retries && retryable?(response)

          @pause.call(retry_pause(response, retries))
          retries += 1
        end
      end

      def retryable?(response) = RETRYABLE_STATUSES.include?(response.code.to_s)

      def retry_pause(response, retries)
        advised = Integer(response["Retry-After"], exception: false)
        return [advised, MAX_RETRY_PAUSE].min if advised&.positive?

        RETRY_PAUSES.fetch(retries, RETRY_PAUSES.last)
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
          content: String(message["content"] || ""), tool_calls: Wire.tool_calls_from(message["tool_calls"]),
          finish_reason: String(choice["finish_reason"] || ""), usage: Wire.provider_usage(envelope["usage"]),
          request_digest: request_digest(request_bytes),
          response_digest: Wire.sha256(envelope_bytes),
          settings_digest: conversation_settings_digest, provider_configuration_digest:
        )
      rescue Tamoz::Core::ProtocolError, Tamoz::Core::JCS::Error, JSON::ParserError, KeyError, TypeError
        raise model_error("invalid_response", body: envelope_bytes)
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

      def post_completion_request(body, headers:) = post_request(OPENAI_COMPLETIONS_PATH, body, headers:)

      def post_request(path, body, headers:, &)
        uri = URI.parse("#{@endpoint}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.read_timeout = @timeout_seconds
        http.open_timeout = @timeout_seconds
        http.use_ssl = uri.scheme == "https"
        begin
          http.request(Net::HTTP::Post.new(uri, headers), body, &)
        rescue Timeout::Error, IOError, SystemCallError, SocketError, Net::ProtocolError
          raise EffectUnknownError, "model call outcome is unknown"
        end
      end

      def post_bounded(path, body, headers:, max_bytes:)
        post_request(path, body, headers:) do |response|
          bytes = +"".b
          response.read_body do |chunk|
            bytes << chunk
            next if bytes.bytesize <= max_bytes

            raise model_error("response_too_large", status: response.code, body_bytes: bytes.bytesize)
          end
          return [response.code.to_s, response["Content-Type"].to_s, bytes]
        end
      end

      def transcript_text(body)
        parsed = Tamoz::Core.parse_json_strict(body)
        text = parsed.is_a?(Hash) && parsed["text"]
        raise model_error("invalid_response", body:) unless text.is_a?(String)

        text[0, MAX_TRANSCRIPT_CHARACTERS]
      rescue Tamoz::Core::ProtocolError, Tamoz::Core::JCS::Error, JSON::ParserError
        raise model_error("invalid_response", body:)
      end

      def build_model_response(envelope_bytes, request_bytes:, retries:)
        Response.new(
          content: Wire.extract_content(envelope_bytes),
          request_digest: request_digest(request_bytes),
          response_digest: Wire.sha256(envelope_bytes),
          usage: Wire.usage_from(Wire.extract_usage_hash(envelope_bytes)),
          settings_digest: settings_digest,
          provider_configuration_digest:,
          provider_retries: retries
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
          body_digest: body ? Wire.sha256(bytes) : nil,
          body_bytes: body ? bytes.bytesize : body_bytes
        )
      end
    end
  end
end

require_relative "episode_model_transport/wire"
