# frozen_string_literal: true

class ThreadBarrier
  def initialize(participants)
    raise ArgumentError, 'participants must be positive' unless participants.positive?

    @remaining = participants
    @mutex = Mutex.new
    @condition = ConditionVariable.new
  end

  def wait(timeout: 5)
    @mutex.synchronize do
      @remaining -= 1
      @condition.broadcast if @remaining.zero?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      wait_for_peers(deadline) until @remaining <= 0
    end
  end

  private

  def wait_for_peers(deadline)
    remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raise ThreadError, 'barrier participants did not arrive' unless remaining.positive?

    @condition.wait(@mutex, remaining)
  end
end
