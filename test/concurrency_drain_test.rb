# frozen_string_literal: true

require_relative "test_helper"

require "tamoz/concurrency"

class ConcurrencyDrainTest < Minitest::Test
  # A minimal policy layer over the skeleton: everything it adds is exactly
  # what a real consumer adds (drop accounting, outcome handling, gates).
  class Collector < Tamoz::Concurrency::Drain
    attr_reader :delivered, :outcomes, :drops

    def initialize(lanes:, batch_size:, interval: 0.005)
      @delivered = Queue.new
      @outcomes = []
      @drops = Hash.new(0)
      @gate = nil
      @raise_once = nil
      super(lanes:, batch_size:, interval:)
    end

    def store(lane, item)
      synchronize do
        if accept(lane, item)
          true
        else
          @drops[drain_closed? ? 'closed' : drain_disabled? ? 'disabled' : 'full'] += 1
          false
        end
      end
    end

    def thread_alive?
      @thread&.alive?
    end

    def hold_delivery(gate)
      @gate = gate
    end

    def fail_next_delivery!
      @raise_once = true
    end

    def deliver_batch(batch)
      entry = @gate.pop if @gate
      raise "boom" if @raise_once

      batch.each { |item| @delivered << item }
      @gate << :released if entry
      :delivered
    end

    def delivery_result(outcome, _batch)
      @outcomes << outcome
    end

    def handle_loop_error(_error)
      disable_drain!
    end
  end

  def test_lifecycle_records_drains_flushes_and_closes
    collector = Collector.new(lanes: { a: 8 }, batch_size: 1)

    assert_equal true, collector.store(:a, 1)
    assert_equal true, collector.store(:a, 2)
    assert_equal({ a: 2 }, collector.depths)

    assert_equal 0, collector.flush(deadline_ms: 2_000)
    assert_equal({ a: 0 }, collector.depths)
    assert_equal [1, 2], drained(collector)
    assert_equal [:delivered, :delivered], collector.outcomes
    assert_equal 0, collector.in_flight

    collector.close
    assert collector.closed?
    refute collector.thread_alive?, "close must join the drain thread"
    assert_equal false, collector.store(:a, 3)
    assert_equal({ 'closed' => 1 }, collector.drops)
  end

  def test_flush_deadline_returns_the_leftover_count
    collector = Collector.new(lanes: { a: 8 }, batch_size: 8)
    gate = Queue.new
    collector.hold_delivery(gate)

    3.times { |i| assert_equal true, collector.store(:a, i) }
    assert_equal 3, collector.flush(deadline_ms: 20), "nothing may be drained while delivery is held"

    gate << :go
    assert_equal 0, collector.flush(deadline_ms: 2_000)
  ensure
    gate << :go rescue nil
    collector&.close
  end

  def test_queue_full_refusals_are_counted_by_the_policy_layer
    collector = Collector.new(lanes: { a: 2 }, batch_size: 8)
    gate = Queue.new
    collector.hold_delivery(gate)

    assert_equal true, collector.store(:a, 1)
    assert_equal true, collector.store(:a, 2)
    assert_equal false, collector.store(:a, 3)
    assert_equal({ 'full' => 1 }, collector.drops)
    assert_equal({ a: 2 }, collector.depths)
  ensure
    gate << :go rescue nil
    collector&.close
  end

  def test_in_flight_decrements_only_after_the_delivery_completes
    collector = Collector.new(lanes: { a: 8 }, batch_size: 8)
    gate = Queue.new
    collector.hold_delivery(gate)

    2.times { |i| assert_equal true, collector.store(:a, i) }
    wait_until { collector.in_flight.positive? }
    assert_equal 2, collector.in_flight

    gate << :go
    assert_equal 0, collector.flush(deadline_ms: 2_000)
    assert_equal 0, collector.in_flight
  ensure
    gate << :go rescue nil
    collector&.close
  end

  def test_a_raising_delivery_disables_and_stops_the_thread
    collector = Collector.new(lanes: { a: 8 }, batch_size: 8)
    collector.fail_next_delivery!

    assert_equal true, collector.store(:a, 1)
    wait_until { collector.disabled? }
    refute collector.thread_alive?, "handle_loop_error ends the drain thread"
    assert_equal false, collector.store(:a, 2)
    assert_equal({ 'disabled' => 1 }, collector.drops)
  ensure
    collector&.close
  end

  def test_close_joins_within_grace_even_when_delivery_hangs
    collector = Collector.new(lanes: { a: 8 }, batch_size: 8)
    gate = Queue.new
    collector.hold_delivery(gate)

    assert_equal true, collector.store(:a, 1)
    wait_until { collector.in_flight.positive? }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    collector.close(deadline_ms: 20)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 5.0, "close must give up at the grace, not hang forever"
  ensure
    gate << :go rescue nil
  end

  # A caller must be able to tell a clean shutdown from an abandoned backlog:
  # close returns the count it could not drain, never a bare nil (F03-REL-02).
  def test_close_returns_the_backlog_it_could_not_drain
    collector = Collector.new(lanes: { a: 8 }, batch_size: 8)
    gate = Queue.new
    collector.hold_delivery(gate)

    assert_equal true, collector.store(:a, 1)
    wait_until { collector.in_flight.positive? }

    assert_operator collector.close(deadline_ms: 20), :>, 0,
                    "close reports the backlog it abandoned, never a clean nil"
  ensure
    gate << :go rescue nil
  end

  def test_unknown_lane_is_rejected_without_touching_the_queues
    collector = Collector.new(lanes: { a: 4 }, batch_size: 4)

    assert_raises(Tamoz::ConfigurationError) { collector.push(:nope, 1) }
    assert_equal({ a: 0 }, collector.depths)
  ensure
    collector&.close
  end

  private

  def drained(collector)
    items = []
    items << collector.delivered.pop(true) until collector.delivered.empty?
    items
  end

  def wait_until(timeout: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not reached within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(0.001)
    end
  end
end
