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
    # The client is one bounded HTTP call; the metric smells measure the
    # HTTP boundary (timeouts, throttle, idempotent-flag), not a choice to
    # overload.
    # :reek:TooManyStatements, :reek:BooleanParameter, :reek:ControlParameter
    # :reek:DuplicateMethodCall, :reek:LongParameterList
    class Client
      DEFAULT_ORIGIN = 'https://api.telegram.org'
      DEFAULT_OPEN_TIMEOUT = 10.0
      DEFAULT_READ_TIMEOUT = 65.0
      DEFAULT_MAX_RESPONSE_BYTES = 10_000_000

      attr_reader :token, :origin, :max_response_bytes

      def initialize(token, origin: DEFAULT_ORIGIN, open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES)
        @token = token
        @origin = origin
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        # An undeclared cap IS the declared default: the client's own limit is
        # the one source of truth for it.
        @max_response_bytes = max_response_bytes || DEFAULT_MAX_RESPONSE_BYTES
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one HTTP boundary with timeout and
      #   throttle branches.
      # :reek:UncommunicativeVariableName -- `error` is the rescued exception.
      # One bounded API call. `idempotent` distinguishes reads (safe to
      # retry) from sends (a timeout must never be retried blindly).
      # @return [Hash] the parsed `ok` payload.
      def call(method, params, idempotent: false)
        http = build_http
        request = build_request(method, params)
        response = nil
        body = +''
        http.request(request) do |partial|
          response = partial
          partial.read_body do |chunk|
            body << chunk
            raise Comms::ResponseTooLargeError if body.bytesize > @max_response_bytes
          end
        end

        case response
        when Net::HTTPSuccess
          payload = JSON.parse(body, create_additions: false)
          raise Comms::ValidationError, "#{method} response carries no ok field" unless payload.key?('ok')

          if payload.fetch('ok')
            payload.fetch('result')
          elsif payload['error_code'] == 401
            raise Comms::AuthenticationError, 'bot token refused'
          else
            raise transport_failure(idempotent, "telegram api error #{payload['error_code']}")
          end
        when Net::HTTPTooManyRequests
          raise Comms::ThrottledError.new('rate limited', retry_after: retry_after_from(body))
        when Net::HTTPUnauthorized
          raise Comms::AuthenticationError, 'bot token refused'
        when Net::HTTPConflict
          # 409 is the remote saying another getUpdates holds this bot, or a
          # webhook does. `doctor` catches that before serving, but only for
          # THIS runtime directory: the competitor can be another host or a
          # webhook set later. Fatal and named, never a retry — two pollers
          # reading one update stream is a correctness problem.
          raise Comms::PollerConflictError, conflict_message(body)
        else
          raise transport_failure(idempotent, "telegram api error #{response.code}")
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT, JSON::ParserError => e
        # A read observed nothing and changed nothing, so it is typed transient
        # and the caller repeats it from unchanged state. A send is the other
        # case entirely: its outcome is unknown and must never be blindly
        # retried (design §10).
        raise Comms::TransientTransportError, "#{method} did not complete (#{e.class})" if idempotent

        raise transport_failure(idempotent, "#{method} did not return a valid response (#{e.class})")
      end

      private

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
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength
