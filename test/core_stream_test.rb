# frozen_string_literal: true

require_relative "test_helper"

class CoreStreamTest < Minitest::Test
  class ManualClock
    def initialize
      @value = 0.0
    end

    def now
      value = @value
      @value += 0.001
      value
    end
  end

  def test_stream_part_is_immutable_and_inspection_redacts_payload
    data = {"content" => ["must-not-appear"]}
    part = Tamoz::StreamPart.new(
      type: :message_chunk,
      namespace: ["graph", "node"],
      run_id: "run.1",
      task_id: "task.1",
      sequence: 0,
      data:,
      emitted_at: 1.25
    )
    data.fetch("content") << "mutated"

    assert_equal({"content" => ["must-not-appear"]}, part.data)
    assert part.frozen?
    assert part.data.frozen?
    assert part.data.fetch("content").frozen?
    refute_includes part.inspect, "must-not-appear"
    assert_includes part.inspect, "[REDACTED"
  end

  def test_stream_part_rejects_unknown_types_and_secrets
    base = {
      namespace: [],
      run_id: "run.1",
      sequence: 0,
      emitted_at: 0.0
    }

    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::StreamPart.new(type: "attacker_defined", data: {}, **base)
    end
    assert_raises(Tamoz::SensitiveValueError) do
      Tamoz::StreamPart.new(
        type: :custom,
        data: {"secret" => Tamoz::Secret.new("token")},
        **base
      )
    end
  end

  def test_sequences_are_monotonic_per_namespace
    sink = sink(capacity: 4)
    first = sink.emit(:custom, ["a"], {})
    second = sink.emit(:custom, ["a"], {})
    other = sink.emit(:custom, ["b"], {})
    sink.finish

    assert_equal [0, 1, 0], [first.sequence, second.sequence, other.sequence]
    assert_equal [first, second, other], sink.each.to_a
    refute sink.cancellation.cancelled?
  end

  def test_namespace_history_is_bounded_and_invalid_names_do_not_consume_capacity
    sink = sink(capacity: 3, max_namespaces: 2)

    assert_raises(Tamoz::ConfigurationError) do
      sink.emit(:custom, ["x" * 257], {})
    end
    assert_raises(Tamoz::SensitiveValueError) do
      sink.emit(:custom, ["invalid-payload"], {"secret" => Tamoz::Secret.new("token")})
    end
    sink.emit(:custom, ["a"], {})
    sink.emit(:custom, ["b"], {})
    assert_raises(Tamoz::StateLimitError) { sink.emit(:custom, ["c"], {}) }
    assert_equal 2, sink.size
  ensure
    sink&.close
  end

  def test_concurrent_emission_order_matches_reserved_sequence
    sink = sink(capacity: 32)
    producers = 20.times.map do |index|
      Thread.new { sink.emit(:custom, ["shared"], {"producer" => index}) }
    end
    producers.each(&:join)
    sink.finish

    sequences = sink.each.map(&:sequence)
    assert_equal (0...20).to_a, sequences
  ensure
    sink&.close
    producers&.each { |producer| producer.join(0.5) }
  end

  def test_capacity_applies_backpressure_and_consumer_release_unblocks_producer
    sink = sink(capacity: 1)
    sink.emit(:custom, ["a"], {"index" => 1})
    producer_result = Queue.new
    producer = Thread.new do
      producer_result << sink.emit(:custom, ["a"], {"index" => 2})
    rescue StandardError => error
      producer_result << error
    end

    wait_until { producer.status == "sleep" }
    assert_equal 1, sink.size
    stream = sink.each
    assert_equal 1, stream.next.data.fetch("index")
    wait_until { !producer.alive? }
    assert_instance_of Tamoz::StreamPart, producer_result.pop
    sink.finish
    assert_equal 2, stream.next.data.fetch("index")
    assert_raises(StopIteration) { stream.next }
    producer.join
  ensure
    sink&.close
    producer&.join(0.5)
  end

  def test_early_consumer_close_cancels_and_rejects_late_emission
    sink = sink(capacity: 2)
    sink.emit(:custom, ["a"], {"index" => 1})
    sink.emit(:custom, ["a"], {"index" => 2})

    assert_equal [1], sink.each.take(1).map { |part| part.data.fetch("index") }
    assert sink.cancellation.cancelled?
    assert sink.closed?
    assert_equal "consumer_closed", sink.cancellation.reason
    assert_raises(Tamoz::StreamClosedError) do
      sink.emit(:custom, ["a"], {"index" => 3})
    end
  end

  def test_close_wakes_a_blocked_producer
    sink = sink(capacity: 1)
    sink.emit(:custom, ["a"], {"index" => 1})
    result = Queue.new
    producer = Thread.new do
      sink.emit(:custom, ["a"], {"index" => 2})
      result << :unexpected_success
    rescue StandardError => error
      result << error
    end

    wait_until { producer.status == "sleep" }
    assert sink.close(reason: "test_close")
    assert producer.join(0.5), "blocked producer did not wake after close"
    assert_instance_of Tamoz::StreamClosedError, result.pop
    assert_equal "test_close", sink.cancellation.reason
  ensure
    sink&.close
    producer&.join(0.5)
  end

  def test_natural_finish_drains_without_cancellation
    sink = sink(capacity: 3)
    3.times { |index| sink.emit(:custom, ["a"], {"index" => index}) }
    assert sink.finish
    refute sink.finish

    assert_equal [0, 1, 2], sink.each.map { |part| part.data.fetch("index") }
    refute sink.cancellation.cancelled?
    assert sink.finished?
    refute sink.close(reason: "invalid\nreason")
  end

  def test_only_one_consumer_can_start
    sink = sink(capacity: 2)
    sink.emit(:custom, ["a"], {})
    first = sink.each
    first.next

    second = sink.each
    assert_raises(Tamoz::ConfigurationError) { second.next }
  ensure
    sink&.close
  end

  def test_external_cancellation_closes_stream
    token = Tamoz::CancellationToken.new
    sink = sink(capacity: 1, cancellation: token)

    assert token.cancel!("external")
    assert sink.closed?
    assert_equal "external", sink.closed_reason
    assert_raises(Tamoz::StreamClosedError) { sink.emit(:custom, [], {}) }
  end

  def test_stream_identity_and_reasons_reject_control_characters
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::StreamPart.new(
        type: :custom,
        namespace: ["forged\nnamespace"],
        run_id: "run.1",
        sequence: 0,
        emitted_at: 0.0
      )
    end

    sink = sink(capacity: 1)
    assert_raises(ArgumentError) { sink.close(reason: "forged\rreason") }
    refute sink.closed?
  ensure
    sink&.close
  end

  private

  def sink(capacity:, cancellation: Tamoz::CancellationToken.new, **options)
    Tamoz::StreamSink.new(
      capacity:,
      cancellation:,
      clock: ManualClock.new,
      run_id: "run.1",
      **options
    )
  end

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not reached within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end
end
