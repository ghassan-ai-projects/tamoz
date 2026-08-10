# frozen_string_literal: true

require 'json'
require 'net/http'
require 'time'

module Tamoz
  module Telegram
    # A minimal Bot API HTTP client over net/http (ADR-041: stdlib only).
    # Every request is a bounded JSON call; a 429 carries the server's
    # authoritative retry_after, a network timeout on a send is
    # AmbiguousDeliveryError (genuinely irreconcilable, design §10), and an
    # auth failure is AuthenticationError (never a retry).
    # The client is one bounded HTTP call; the metric smells measure the
    # HTTP boundary (timeouts, throttle, idempotent-flag), not a choice to
    # overload.
    # :reek:TooManyStatements, :reek:BooleanParameter, :reek:ControlParameter
    # :reek:DuplicateMethodCall, :reek:LongParameterList
    class Client
      DEFAULT_ORIGIN = 'https://api.telegram.org'
      DEFAULT_OPEN_TIMEOUT = 10.0
      DEFAULT_READ_TIMEOUT = 65.0

      attr_reader :token, :origin

      def initialize(token, origin: DEFAULT_ORIGIN, open_timeout: DEFAULT_OPEN_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT)
        @token = token
        @origin = origin
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      # rubocop:disable Metrics/AbcSize -- one HTTP boundary with timeout and
      #   throttle branches.
      # :reek:UncommunicativeVariableName -- `error` is the rescued exception.
      # One bounded API call. `idempotent` distinguishes reads (safe to
      # retry) from sends (a timeout must never be retried blindly).
      # @return [Hash] the parsed `ok` payload.
      def call(method, params, idempotent: false)
        http = build_http
        request = Net::HTTP::Post.new(path_for(method))
        request.body = JSON.generate(params)
        request['Content-Type'] = 'application/json'
        response = http.request(request)

        case response
        when Net::HTTPSuccess
          payload = JSON.parse(response.body, create_additions: false)
          raise Comms::AuthenticationError, 'bot token refused' unless payload.fetch('ok')

          payload.fetch('result')
        when Net::HTTPTooManyRequests
          raise Comms::ThrottledError.new('rate limited', retry_after: retry_after_from(response))
        when Net::HTTPUnauthorized
          raise Comms::AuthenticationError, 'bot token refused'
        else
          raise Comms::CommsError, "telegram api error #{response.code}"
        end
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ETIMEDOUT => e
        raise if idempotent

        raise Comms::AmbiguousDeliveryError, "send may or may not have happened (#{e.class})"
      end

      private

      # :reek:UtilityFunction -- a pure parse of the throttle payload.
      def retry_after_from(response)
        JSON.parse(response.body, create_additions: false).dig('parameters', 'retry_after') || 1
      end

      def path_for(method)
        "/bot#{@token}/#{method}"
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
# rubocop:enable Metrics/AbcSize
