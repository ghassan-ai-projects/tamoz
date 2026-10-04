# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'support/thread_barrier'

class ThreadBarrierTest < Minitest::Test
  def test_all_participants_arrive_before_any_one_continues
    barrier = ThreadBarrier.new(3)
    arrived = Queue.new
    observed = Queue.new
    threads = Array.new(3) do |index|
      Thread.new do
        arrived << index
        barrier.wait
        observed << arrived.length
      end
    end
    threads.each(&:value)

    assert_equal [3, 3, 3], Array.new(3) { observed.pop }
  ensure
    threads&.each(&:join)
  end

  def test_missing_participant_fails_without_spending_real_time
    error = assert_raises(ThreadError) { ThreadBarrier.new(2).wait(timeout: 0) }

    assert_equal 'barrier participants did not arrive', error.message
  end

  def test_one_participant_continues_immediately
    assert_silent { ThreadBarrier.new(1).wait(timeout: 0) }
  end

  def test_empty_barrier_is_rejected
    assert_raises(ArgumentError) { ThreadBarrier.new(0) }
  end
end
