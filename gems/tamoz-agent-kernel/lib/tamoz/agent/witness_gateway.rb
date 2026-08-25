# frozen_string_literal: true

require "socket"
require "json"
require "digest"
require "net/http"
require "uri"
require "openssl"
require "tamoz/core"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P3 (provenance/replay): the WITNESS GATEWAY — a separately-credentialed
    # service between the worker and the provider. It has NO diagnosis rules,
    # NO tools, NO ground truth: it rehashes the request bytes it receives,
    # forwards them verbatim to the provider, and signs ONE record binding the
    # logical call id, frame/request/response digests, provider, model,
    # provider request id, settings digest, and usage. Tamoz's own events stop
    # being evidence — the gateway's signed record is the witness (B8).
    #
    # The effect adapter's transport is the gateway CLIENT: the worker's egress
    # is allowlisted to the gateway, and the gateway's upstream is the provider.
    class WitnessGateway
      RECORD_VERSION = 1
      SIGNING_ALGORITHM = "sha256"
      MAX_RECORDS = 10_000
      READ_TIMEOUT_SECONDS = 15
      UPSTREAM_READ_TIMEOUT_SECONDS = 300
      UPSTREAM_OPEN_TIMEOUT_SECONDS = 60

      Record = Data.define(
        :logical_call_id, :frame_digest, :request_digest, :response_digest,
        :provider, :model, :provider_request_id, :settings_digest,
        :usage, :signed_at, :signature
      ) do
        # The canonical signed payload — sign and verify both build the
        # signature over THIS document, so the two can never drift (a verifier
        # that accepted a caller-supplied payload would bind nothing).
        def to_payload
          {
            "version" => RECORD_VERSION,
            "logical_call_id" => logical_call_id,
            "frame_digest" => frame_digest,
            "request_digest" => request_digest,
            "response_digest" => response_digest,
            "provider" => provider,
            "model" => model,
            "provider_request_id" => provider_request_id,
            "settings_digest" => settings_digest,
            "usage" => usage
          }
        end
      end

      def initialize(upstream:, signing_key:, log_path: nil)
        @upstream = upstream.to_s.sub(%r{/+\z}, "")
        raise ConfigurationError, "witness gateway requires an upstream" if @upstream.empty?

        @signing_key = String(signing_key)
        raise ConfigurationError, "witness gateway requires a signing key" if @signing_key.empty?

        @log_path = log_path
        @records = []
        @lock = Mutex.new
        @server = TCPServer.new("127.0.0.1", 0)
        @port = @server.addr[1]
      end

      attr_reader :port, :records

      def base_url = "http://127.0.0.1:#{@port}/v1/chat/completions"

      def start
        @thread = Thread.new do
          loop do
            client = begin
              @server.accept
            rescue StandardError
              break
            end
            guard_read_timeout(client)
            handle(client)
          end
        end
        self
      end

      def stop
        begin
          @server.close
        rescue StandardError
          nil
        end
        @thread&.kill
        @thread&.join(1)
      end

      # The verifier's view: the signed records, durable + independently
      # re-readable (a log line per record when log_path is set).
      def signature_ok?(record)
        record.signature == sign(record.to_payload)
      end

      # The canonical signed payload — the log line reads it back from the record.
      def record_payload(record)
        record.to_payload
      end

      private

      # A stalled client must not hang the single accept thread forever:
      # SO_RCVTIMEO turns a silent connection into a timed-out read that the
      # handler's rescue closes.
      def guard_read_timeout(client)
        timeout = [READ_TIMEOUT_SECONDS, 0].pack("l_2")
        client.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, timeout)
      rescue StandardError
        nil
      end

      # The gateway request format (the frozen adapter's client sends this):
      #   { "logical_call_id", "frame_digest", "provider", "model",
      #     "settings_digest", "request_bytes" }  — the request body is the
      #   frozen provider request the gateway rehashes and forwards.
      def handle(client)
        request_bytes = Tamoz::Core::RawHttp.read_request(client)
        return if request_bytes.nil?

        status, response_body = witness_request(request_bytes)
        Tamoz::Core::RawHttp.write_response(client, response_body, status:)
      rescue ProtocolError => error
        # A bad envelope is the client's fault (400); an upstream failure
        # keeps its typed code but is a gateway-side 502.
        status = error.message.start_with?("witness_gateway/upstream_failed") ? 502 : 400
        write_error(client, error, status:)
      rescue StandardError => error
        write_error(client, error, status: 502)
      ensure
        begin
          client&.close
        rescue StandardError
          nil
        end
      end

      def witness_request(request_bytes)
        envelope = parse_envelope(request_bytes)
        logical_call_id = envelope.fetch("logical_call_id")
        frame_digest = envelope.fetch("frame_digest")
        provider = envelope.fetch("provider")
        model = envelope.fetch("model")
        settings_digest = envelope.fetch("settings_digest", nil)
        body = envelope.fetch("request_bytes")

        request_digest = "sha256:#{Digest::SHA256.hexdigest(body)}"
        status, response_body, provider_request_id = forward(body)
        response_digest = "sha256:#{Digest::SHA256.hexdigest(response_body)}"
        usage = extract_usage(response_body)

        record = Record.new(
          logical_call_id:, frame_digest:, request_digest:, response_digest:,
          provider:, model:, provider_request_id:, settings_digest:,
          usage:, signed_at: Time.now.to_i, signature: nil
        )
        signed = record.with(signature: sign(record.to_payload))
        @lock.synchronize do
          @records << signed
          @records.shift if @records.length > MAX_RECORDS
        end
        append_log(signed) if @log_path
        [status, response_body]
      end

      def parse_envelope(bytes)
        parsed = Tamoz::Core.parse_json_strict(bytes)
        unless parsed.is_a?(Hash) && parsed.key?("request_bytes") && parsed.key?("logical_call_id")
          raise ProtocolError, "witness_gateway/envelope_invalid"
        end

        parsed
      end

      def forward(body)
        uri = URI.parse("#{@upstream}/v1/chat/completions")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.read_timeout = UPSTREAM_READ_TIMEOUT_SECONDS
        http.open_timeout = UPSTREAM_OPEN_TIMEOUT_SECONDS
        response = http.request(
          Net::HTTP::Post.new(uri, "Content-Type" => "application/json"),
          body
        )
        request_id = response["x-request-id"] || response["X-Request-Id"]
        [response.code.to_i, response.body.to_s, request_id]
      rescue StandardError => error
        raise ProtocolError, "witness_gateway/upstream_failed: #{error.class}"
      end

      def extract_usage(response_body)
        parsed = Tamoz::Core.parse_json_strict(response_body)
        raw = parsed.is_a?(Hash) ? parsed.fetch("usage", {}) : {}
        return nil unless raw.is_a?(Hash)

        # Only what the provider actually reported is signed — a fabricated
        # cost would be evidence of nothing (the unavailable-cost invariant).
        usage = {}
        usage["input_tokens"] = raw["prompt_tokens"].to_i if raw["prompt_tokens"].is_a?(Numeric)
        usage["output_tokens"] = raw["completion_tokens"].to_i if raw["completion_tokens"].is_a?(Numeric)
        usage.empty? ? nil : usage
      rescue ProtocolError
        nil
      end

      def sign(payload)
        OpenSSL::HMAC.hexdigest(SIGNING_ALGORITHM, @signing_key, JSON.generate(payload))
      end

      def append_log(record)
        File.open(@log_path, "a") do |file|
          file.puts(
            JSON.generate(
              record_payload(record).merge(
                "signed_at" => record.signed_at,
                "signature" => record.signature
              )
            )
          )
        end
      end

      def write_error(client, error, status:)
        code = error.is_a?(ProtocolError) ? error.message : "witness_gateway/internal_error"
        body = JSON.generate({"error" => code})
        Tamoz::Core::RawHttp.write_response(
          client, body, status:,
          reason: status == 400 ? "Bad Request" : "Bad Gateway"
        )
      end
    end
  end
end
