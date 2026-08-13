# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

require 'tamoz/stream/errors'
require 'tamoz/stream/outcome_subscriber'

module Tamoz
  module Stream
    # The live Channel B transport for the stream notification feed.
    class SseTransport
      Frame = Data.define(:type, :cursor, :event, :data, :control)
      RETRYABLE_ERRORS = [
        EOFError, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
        Net::OpenTimeout, Net::ReadTimeout, SocketError
      ].freeze
      CONTROL_EVENTS = %w[cursor_expired subscriber_too_slow].freeze
      MAX_FRAME_BYTES = OutcomeSubscriber::MAX_FRAME_BYTES

      class TransportError < StreamError
        CATEGORY = 'stream_sse_transport'
      end

      def initialize(endpoint:, **configuration)
        @uri = URI.parse(endpoint)
        unless %w[http https].include?(@uri.scheme) && @uri.host
          raise TransportError, 'SSE endpoint must be an HTTP or HTTPS URL'
        end

        @logger = configuration.fetch(:logger, nil)
        @open_timeout = configuration.fetch(:open_timeout, 5)
        @read_timeout = configuration.fetch(:read_timeout, 30)
        @reconnect_delay = configuration.fetch(:reconnect_delay, 0.25)
        @max_reconnect_delay = configuration.fetch(:max_reconnect_delay, 10)
        @reconnect_on_eof = configuration.fetch(:reconnect_on_eof, true)
        @http_factory = configuration.fetch(:http_factory, nil)
        @http = nil
        @stopped = false
      rescue URI::InvalidURIError => e
        raise TransportError, "invalid SSE endpoint: #{e.message}"
      end

      attr_reader :uri

      def open(cursor:, credential:)
        validate_credential!(credential)
        Enumerator.new do |yielder|
          state = { cursor:, delay: @reconnect_delay }
          loop do
            break if @stopped

            begin
              connect(yielder, state, credential)
              break unless @reconnect_on_eof

              reconnect(state)
            rescue *RETRYABLE_ERRORS => e
              raise if @stopped

              log(:warn, "SSE reconnect error=#{e.class}")
              reconnect(state)
            end
          end
        end
      end

      def resnapshot(cursor:, credential:)
        validate_credential!(credential)
        fresh_cursor = nil
        catch(:first_frame) do
          stream_once(cursor: nil, credential:) do |frame|
            fresh_cursor = frame.cursor
            throw :first_frame
          end
        end
        raise TransportError, 'SSE resnapshot did not return a cursor' unless fresh_cursor

        log(:info, "resnapshot from=#{cursor} to=#{fresh_cursor}")
        fresh_cursor
      end

      def stop
        @stopped = true
        http = @http
        return unless http.respond_to?(:finish)
        return if http.respond_to?(:started?) && !http.started?

        http.finish
      rescue IOError
        nil
      end

      private

      def connect(yielder, state, credential)
        log(:info, "connecting endpoint=#{@uri} cursor=#{state[:cursor] || 'none'}")
        stream_once(cursor: state[:cursor], credential:) do |frame|
          state[:cursor] = frame.cursor if frame.cursor
          yielder << frame
        end
        log(:warn, 'SSE connection closed')
      end

      def reconnect(state)
        sleep_before_retry(state[:delay])
        state[:delay] = next_delay(state[:delay])
      end

      def stream_once(cursor:, credential:, &block)
        request = Net::HTTP::Get.new(request_path)
        request['Accept'] = 'text/event-stream'
        request['Cache-Control'] = 'no-cache'
        request['Authorization'] = "Bearer #{credential}"
        request['Last-Event-ID'] = cursor.to_s if cursor

        http = build_http
        @http = http
        http.request(request) do |response|
          validate_response!(response)
          log(:info, "connected endpoint=#{@uri}")
          parser = Parser.new(&block)
          response.read_body { |chunk| parser.feed(chunk) }
          parser.finish
        end
      ensure
        @http = nil if @http.equal?(http)
      end

      def build_http
        return @http_factory.call(@uri) if @http_factory

        Net::HTTP.new(@uri.host, @uri.port).tap do |http|
          http.use_ssl = @uri.scheme == 'https'
          http.open_timeout = @open_timeout
          http.read_timeout = @read_timeout
        end
      end

      def request_path
        path = @uri.path.empty? ? '/' : @uri.path
        query = @uri.query
        query ? "#{path}?#{query}" : path
      end

      def validate_response!(response)
        return if response.is_a?(Net::HTTPSuccess)

        raise EOFError, "SSE endpoint returned HTTP #{response.code}" if response.code.to_i >= 500

        raise TransportError, "SSE endpoint returned HTTP #{response.code}"
      end

      def validate_credential!(credential)
        return unless credential.to_s.empty?

        raise TransportError, 'SSE subscriber credential is required'
      end

      def sleep_before_retry(delay)
        sleep(delay) unless @stopped || delay.zero?
      end

      def next_delay(delay)
        [delay * 2, @max_reconnect_delay].min
      end

      def log(level, message)
        return unless @logger

        @logger.public_send(level, message)
      end

      # Converts SSE fields into the injected subscriber's frame contract.
      class Parser
        def initialize(&callback)
          @callback = callback
          @buffer = +''
          reset
        end

        def feed(chunk)
          @buffer << chunk.to_s
          lines = @buffer.split("\n", -1)
          @buffer = lines.pop
          lines.each { |line| consume(line.delete_suffix("\r")) }
        end

        def finish
          consume(@buffer.delete_suffix("\r")) unless @buffer.empty?
          consume('')
        end

        private

        def consume(line)
          return emit if line.empty?
          return if line.start_with?(':')

          field, value = line.split(':', 2)
          value = value.to_s.delete_prefix(' ')
          case field
          when 'id', 'cursor'
            @cursor = value
          when 'event'
            @event = value
          when 'control'
            @control = value
          when 'data'
            @data << value
            raise TransportError, "SSE frame exceeds #{MAX_FRAME_BYTES} bytes" if
              @data.join("\n").bytesize > MAX_FRAME_BYTES
          end
        end

        def emit
          return reset if @data.empty? && !@event && !@cursor && !@control

          data = @data.join("\n")
          control = @control || control_from_event(data)
          type = control ? :control : :event
          @callback.call(
            Frame.new(type:, cursor: @cursor, event: @event, data:, control:)
          )
          reset
        end

        def control_from_event(data)
          return @event if CONTROL_EVENTS.include?(@event)
          return unless @event == 'control'

          JSON.parse(data, create_additions: false).fetch('control', nil)
        rescue JSON::ParserError, KeyError
          nil
        end

        def reset
          @cursor = nil
          @event = nil
          @control = nil
          @data = []
        end
      end
    end
  end
end
