# frozen_string_literal: true

module Tamoz
  module Concurrency
    class EventStream
      include Enumerable

      MAX_JOIN_GRACE = 60.0

      attr_reader :sink

      def initialize(sink:, join_grace: 1.0, &runner)
        raise ArgumentError, "a stream runner is required" unless runner
        unless join_grace.is_a?(Numeric) &&
               join_grace.finite? &&
               !join_grace.negative? &&
               join_grace <= MAX_JOIN_GRACE
          raise ConfigurationError, "stream join_grace must be between 0 and 60 seconds"
        end

        @sink = sink
        @join_grace = join_grace
        @runner = runner
        @mutex = Mutex.new
        @coordinator = nil
        @consumer_started = false
        @result = nil
        @error = nil
      end

      def each
        return enum_for(:each) unless block_given?

        @mutex.synchronize do
          if @consumer_started
            raise ConfigurationError, "event stream supports exactly one consumer"
          end
          @consumer_started = true
        end
        start!
        begin
          sink.each { |part| yield part }
        ensure
          close unless sink.finished?
          join!
        end
        raise @error if @error

        self
      end

      def close
        sink.close(reason: "consumer_closed")
        join!
        true
      end

      def result
        consume = @mutex.synchronize { !@consumer_started }
        each { |_part| nil } if consume
        start!
        join!
        raise @error if @error

        @result
      end

      private

      def start!
        @mutex.synchronize do
          raise ConfigurationError, "event stream is already closed" if sink.closed? && !sink.finished?
          return if @coordinator

          @coordinator = Thread.new do
            Thread.current.name = "tamoz-concurrency-event-stream" if Thread.current.respond_to?(:name=)
            begin
              @result = @runner.call
            rescue StandardError => error
              @error = error
            ensure
              sink.finish
            end
          end
        end
      end

      def join!
        coordinator = @mutex.synchronize { @coordinator }
        return unless coordinator

        Concurrency.join_all([coordinator], deadline: @join_grace)
        return unless coordinator.alive?

        @error ||= PoolWorkerError.new(
          "graph stream coordinator did not stop within #{@join_grace} seconds"
        )
      end

      private_constant :MAX_JOIN_GRACE
    end
  end
end
