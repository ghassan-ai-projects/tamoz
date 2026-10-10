# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'

module Tamoz
  module Telegram
    # A minimal Bot API HTTP client over net/http (ADR-041: stdlib only).
    # Every request is a bounded JSON call; the response body is streamed and
    # abandoned past `max_response_bytes` (typed Comms::ResponseTooLargeError;
    # never buffered unbounded); a 429 carries the server's authoritative
    # retry_after, a network timeout on a send is AmbiguousDeliveryError
    # (genuinely irreconcilable, design §10), and an auth failure is
    # AuthenticationError (never a retry).
    # :reek:TooManyStatements, :reek:BooleanParameter, :reek:ControlParameter
    # :reek:DuplicateMethodCall, :reek:LongParameterList
    class Client
      DEFAULT_ORIGIN = 'https://api.telegram.org'
      DEFAULT_OPEN_TIMEOUT = 10.0
      DEFAULT_READ_TIMEOUT = 65.0
      DEFAULT_MAX_RESPONSE_BYTES = 10_000_000
      DOWNLOAD_DEADLINE_S = 40.0
      DOWNLOAD_READ_TIMEOUT_S = 15.0
      FILE_PATH = %r{\A(?!/)(?!.*(?:\A|/)\.\.(?:/|\z))[A-Za-z0-9_.\-/]{1,256}\z}
      # A stand-in Bot API on this machine (the evals) is the only origin besides Telegram's own.
      LOOPBACK_ORIGIN = %r{\Ahttp://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d{1,5})?\z}

      attr_reader :token, :origin, :max_response_bytes

      def initialize(token, origin: DEFAULT_ORIGIN, open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES,
                     download_deadline: DOWNLOAD_DEADLINE_S)
        unless origin == DEFAULT_ORIGIN || origin.match?(LOOPBACK_ORIGIN)
          raise Comms::ValidationError, 'the Bot API origin must be Telegram or a loopback stand-in'
        end

        @token = token
        @origin = origin
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @download_deadline = download_deadline
        # An undeclared cap IS the declared default: the client's own limit is
        # the one source of truth for it.
        @max_response_bytes = max_response_bytes || DEFAULT_MAX_RESPONSE_BYTES
      end

      # :reek:UncommunicativeVariableName -- `error` is the rescued exception.
      # One bounded API call. `idempotent` distinguishes reads (safe to
      # retry) from sends (a timeout must never be retried blindly).
      # @return [Hash] the parsed `ok` payload.
      def call(method, params, idempotent: false, read_timeout: @read_timeout)
        response, body = post(method, params, read_timeout)
        interpret(response, body, method:, idempotent:)
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, JSON::ParserError => e
        # A read observed nothing and changed nothing, so it is typed transient
        # and the caller repeats it from unchanged state. A send is the other
        # case entirely: its outcome is unknown and must never be blindly
        # retried (design §10).
        raise Comms::TransientTransportError, "#{method} did not complete (#{e.class})" if idempotent

        raise transport_failure(idempotent, "#{method} did not return a valid response (#{e.class})")
      end

      # A download observes and changes nothing, so a failure is transient.
      def download(file_path, max_bytes:)
        raise Comms::ValidationError, 'file path is not a Telegram file path' unless FILE_PATH.match?(file_path.to_s)

        response = nil
        body = (+'').b
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @download_deadline
        http = build_http
        http.read_timeout = DOWNLOAD_READ_TIMEOUT_S
        http.request(Net::HTTP::Get.new("/file/bot#{@token}/#{file_path}")) do |partial|
          response = partial
          read_bounded(partial, body, max_bytes, deadline:)
        end
        raise Comms::TransientTransportError, "file download failed (#{response.code})" unless
          response.is_a?(Net::HTTPSuccess)

        body
      rescue Comms::CommsError
        raise
      rescue StandardError => e
        raise Comms::TransientTransportError, "file download did not complete (#{e.class})"
      end

      private

      def post(method, params, read_timeout)
        http = build_http
        http.read_timeout = read_timeout
        request = build_request(method, params)
        response = nil
        body = +''
        http.request(request) do |partial|
          response = partial
          read_bounded(partial, body)
        end
        [response, body]
      end

      def read_bounded(partial, body, limit = @max_response_bytes, deadline: nil)
        partial.read_body do |chunk|
          body << chunk
          raise Comms::ResponseTooLargeError if body.bytesize > limit
          raise Comms::TransientTransportError, 'file download exceeded its deadline' if
            deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end
      end

      def interpret(response, body, method:, idempotent:)
        case response
        when Net::HTTPSuccess then api_result(body, method:, idempotent:)
        when Net::HTTPTooManyRequests then raise throttled(body)
        when Net::HTTPUnauthorized then raise Comms::AuthenticationError, 'bot token refused'
        when Net::HTTPConflict then raise conflict_failure(idempotent, body)
        else raise refused(idempotent, body, response.code)
        end
      end

      # Telegram's 400 "file is too big" is final, not a transient read.
      def refused(idempotent, body, code)
        description = idempotent ? described(body) : ''
        return Comms::ResponseTooLargeError.new(description) if description.match?(/too big/i)

        transport_failure(idempotent, "telegram api error #{code}")
      end

      # :reek:UtilityFunction -- a pure parse of an error payload.
      def described(body)
        parsed = JSON.parse(body, create_additions: false)
        parsed.is_a?(Hash) ? parsed['description'].to_s : ''
      rescue JSON::ParserError
        ''
      end

      def throttled(body)
        Comms::ThrottledError.new('rate limited', retry_after: retry_after_from(body))
      end

      def api_result(body, method:, idempotent:)
        payload = JSON.parse(body, create_additions: false)
        raise Comms::ValidationError, "#{method} response carries no ok field" unless payload.key?('ok')
        return payload.fetch('result') if payload.fetch('ok')
        raise Comms::AuthenticationError, 'bot token refused' if payload['error_code'] == 401

        raise transport_failure(idempotent, "telegram api error #{payload['error_code']}")
      end

      # A 409 on a poll (idempotent read) is the poller-conflict condition:
      # another getUpdates or a webhook holds this bot — fatal and named, never
      # retried, because two pollers on one stream is a correctness problem. A
      # 409 on a send is not that: PollerConflictError is a class the delivery
      # drainer cannot read, so it would kill the drainer thread and strand the
      # row. A send's 409 takes the ambiguous mapping, so the send lands unknown.
      def conflict_failure(idempotent, body)
        message = conflict_message(body)
        return Comms::PollerConflictError.new(message) if idempotent

        transport_failure(idempotent, message)
      end

      # The API's own description names WHICH competitor holds the stream, so
      # it is worth carrying; a malformed body still gets a usable message.
      # :reek:UtilityFunction -- a pure parse of the conflict payload.
      def conflict_message(body)
        described = JSON.parse(body, create_additions: false)['description']
        described.to_s.empty? ? 'another poller or a webhook holds this bot' : described.to_s
      rescue JSON::ParserError
        'another poller or a webhook holds this bot'
      end

      # :reek:UtilityFunction -- a pure parse of the throttle payload.
      def retry_after_from(body)
        JSON.parse(body, create_additions: false).dig('parameters', 'retry_after') || 1
      end

      def path_for(method)
        "/bot#{@token}/#{method}"
      end

      def transport_failure(idempotent, message)
        if idempotent
          Comms::TransientTransportError.new(message)
        else
          Comms::AmbiguousDeliveryError.new("send may or may not have happened (#{message})")
        end
      end

      def build_request(method, params)
        request = Net::HTTP::Post.new(path_for(method))
        request.body = JSON.generate(params)
        request['Content-Type'] = 'application/json'
        request
      end

      def build_http
        uri = URI(@origin)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http
      end
    end
  end
end
