# frozen_string_literal: true

require_relative "test_helper"

class CorePoolTest < Minitest::Test
  def test_inline_and_threaded_results_preserve_submission_order
    items = (0...40).to_a
    inline = Tamoz::Pool.for(:inline).map(items) { |item| item * item }
    threaded = Tamoz::Pool.for(:threads, size: 4, queue_capacity: 3).map(items) do |item|
      sleep(((39 - item) % 5) * 0.0001)
      item * item
    end

    assert_equal (0...40).to_a, threaded.map(&:index)
    assert_equal inline.map(&:value), threaded.map(&:value)
    assert threaded.all? { |result| result.is_a?(Tamoz::TaskResult::Succeeded) }
  end

  def test_order_equivalence_across_deterministic_schedules
    50.times do |seed|
      random = Random.new(seed)
      items = Array.new(random.rand(1..30)) { random.rand(-1_000..1_000) }
      delays = items.each_index.map { random.rand(0..4) * 0.00005 }
      expected = Tamoz::Pool.for(:inline).map(items) { |item| item * 3 }
      actual = Tamoz::Pool.for(
        :threads,
        size: random.rand(1..4),
        queue_capacity: random.rand(1..5)
      ).map(items.each_with_index.to_a) do |(item, index)|
        sleep(delays.fetch(index))
        item * 3
      end

      assert_equal expected.map(&:value), actual.map(&:value), "seed=#{seed}"
      assert_equal items.each_index.to_a, actual.map(&:index), "seed=#{seed}"
    end
  end

  def test_interrupt_is_captured_inside_each_worker
    descriptor = {"kind" => "approval", "payload" => {"plan" => "p1"}}
    inline = Tamoz::Pool.for(:inline).map([1]) do
      throw :tamoz_interrupt, descriptor
    end
    threaded = Tamoz::Pool.for(:threads, size: 1).map([1]) do
      throw :tamoz_interrupt, descriptor
    end

    [inline.first, threaded.first].each do |result|
      assert_instance_of Tamoz::TaskResult::Interrupted, result
      assert_equal descriptor, result.descriptor
      assert result.descriptor.frozen?
      assert result.descriptor.fetch("payload").frozen?
    end
  end

  def test_normal_value_cannot_be_confused_with_an_interrupt
    value = [:ordinary, {"value" => 1}]
    result = Tamoz::Pool.for(:threads, size: 1).map([1]) { value }.first

    assert_instance_of Tamoz::TaskResult::Succeeded, result
    assert_same value, result.value
  end

  def test_task_error_is_retained_with_original_backtrace
    failure = Class.new(StandardError).new("task failed")
    result = Tamoz::Pool.for(:threads, size: 1).map([1]) { raise failure }.first

    assert_instance_of Tamoz::TaskResult::Failed, result
    assert_same failure, result.error
    assert_includes result.error.backtrace.first, "core_pool_test.rb"
  end

  def test_fatal_exception_is_re_raised_as_the_original_object
    fatal_class = Class.new(Exception)
    fatal = fatal_class.new("fatal")
    actual = assert_raises(fatal_class) do
      Tamoz::Pool.for(:threads, size: 1).map([1]) { raise fatal }
    end

    assert_same fatal, actual
    assert_includes actual.backtrace.first, "core_pool_test.rb"
  end

  def test_pre_cancelled_token_prevents_all_work
    token = Tamoz::CancellationToken.new
    token.cancel!("redirected")
    calls = 0
    results = Tamoz::Pool.for(:threads, size: 2, cancellation: token).map([1, 2, 3]) do
      calls += 1
    end

    assert_equal 0, calls
    assert_equal %i[cancelled cancelled cancelled], results.map(&:status)
    assert_equal ["redirected"], results.map(&:reason).uniq
  end

  def test_cooperative_cancellation_rejects_late_success_and_joins_workers
    token = Tamoz::CancellationToken.new
    started = Queue.new
    pool = Tamoz::Pool.for(
      :threads,
      size: 2,
      queue_capacity: 1,
      cancellation: token,
      cancellation_grace: 0.5
    )
    canceller = Thread.new do
      2.times { started.pop }
      token.cancel!("redirected")
    end
    results = pool.map([1, 2, 3, 4]) do |item|
      started << true
      token.wait(timeout: 0.5)
      item
    end

    canceller.join
    assert results.all? { |result| result.is_a?(Tamoz::TaskResult::Cancelled) }
    assert_equal ["redirected"], results.map(&:reason).uniq
    wait_until { tamoz_pool_threads.empty? }
  ensure
    token&.cancel!("cleanup")
    canceller&.join(0.5)
  end

  def test_uncooperative_worker_becomes_stuck_and_opens_circuit
    token = Tamoz::CancellationToken.new
    started = Queue.new
    release = Queue.new
    pool = Tamoz::Pool.for(
      :threads,
      size: 1,
      queue_capacity: 1,
      cancellation: token,
      cancellation_grace: 0.01,
      stuck_worker_limit: 1
    )
    canceller = Thread.new do
      started.pop
      token.cancel!("shutdown")
    end
    results = pool.map([1]) do
      started << true
      release.pop
      :late
    end

    assert_instance_of Tamoz::TaskResult::Stuck, results.first
    assert pool.circuit_open?
    assert_equal 1, pool.stuck_workers
    assert_raises(Tamoz::PoolCircuitOpenError) { pool.map([2]) { :never } }
  ensure
    release&.push(true)
    canceller&.join(0.5)
    wait_until { tamoz_pool_threads.empty? } if release
  end

  def test_task_count_and_pool_configuration_are_bounded
    pool = Tamoz::Pool.for(:inline, max_tasks: 2)

    assert_raises(Tamoz::ConfigurationError) { pool.map([1, 2, 3]) { _1 } }
    assert_raises(Tamoz::ConfigurationError) { Tamoz::Pool.for(:threads, size: 0) }
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Pool.for(:threads, size: 1, queue_capacity: 0)
    end
    assert_raises(Tamoz::ConfigurationError) { Tamoz::Pool.for(:fibers) }
    assert_raises(Tamoz::ConfigurationError) { Tamoz::Pool.for(:processes) }
  end

  def test_pool_implementation_contains_no_asynchronous_thread_termination
    source = ROOT.join("gems", "tamoz-core", "lib", "tamoz", "pool.rb").read

    refute_match(/Thread\s*#?\s*(?:kill|raise)|\.kill\b|\.raise\b|Timeout\.timeout/, source)
  end

  private

  def tamoz_pool_threads
    Thread.list.select { |thread| thread.name&.start_with?("tamoz-pool-") }
  end

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not reached within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
