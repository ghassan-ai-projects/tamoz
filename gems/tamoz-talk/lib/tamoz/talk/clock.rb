# frozen_string_literal: true

module Tamoz
  module Talk
    # Microsecond sequence numbers that never go backwards, starting above a floor the caller knows is taken.
    class Clock
      def initialize(floor: 0, now_us: -> { Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond) })
        @now_us = now_us
        @last = floor.to_i
        @mutex = Mutex.new
      end

      def next = @mutex.synchronize { @last = [@last + 1, @now_us.call].max }

      def raise_floor(value) = @mutex.synchronize { @last = [@last, value.to_i].max }
    end
  end
end
