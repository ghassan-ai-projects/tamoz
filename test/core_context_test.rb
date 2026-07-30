# frozen_string_literal: true

require_relative "test_helper"

class CoreContextTest < Minitest::Test
  class ManualClock
    attr_accessor :value

    def initialize(value)
      @value = value
    end

    def now
      value
    end
  end

  class RecordingEmitter
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(type, namespace, data, run_id:, task_id:)
      @events << [type, namespace, data, run_id, task_id]
      true
    end
  end

  def test_context_copies_values_but_does_not_freeze_services
    metadata = {"nested" => ["value"]}
    tags = ["test"]
    namespace = ["root"]
    store = Object.new
    effects = Object.new
    context = context(metadata:, tags:, namespace:, store:, effects:)

    metadata.fetch("nested") << "mutated"
    tags << "mutated"
    namespace << "mutated"

    assert_equal({"nested" => ["value"]}, context.metadata)
    assert_equal ["test"], context.tags
    assert_equal ["root"], context.namespace
    assert context.metadata.frozen?
    assert context.metadata.fetch("nested").frozen?
    refute store.frozen?
    refute effects.frozen?
    assert context.frozen?
  end

  def test_context_rejects_sensitive_metadata
    assert_raises(Tamoz::SensitiveValueError) do
      context(metadata: {"credential" => Tamoz::Secret.new("token")})
    end
  end

  def test_child_links_run_identity_and_namespace_without_ambient_state
    store = Object.new
    parent = context(namespace: ["graph"], task_id: "task.parent", store:)
    child = parent.child("node.answer", task_id: "task.child", run_id: "run.child")

    assert_equal "run.child", child.run_id
    assert_equal parent.run_id, child.parent_run_id
    assert_equal parent.execution_id, child.execution_id
    assert_equal parent.request_id, child.request_id
    assert_equal ["graph", "node.answer"], child.namespace
    assert_equal "task.child", child.task_id
    assert_same parent.cancellation, child.cancellation
    assert_same store, child.store
  end

  def test_with_revalidates_and_rejects_unknown_fields
    original = context
    changed = original.with(metadata: {"phase" => "review"})

    assert_equal({}, original.metadata)
    assert_equal({"phase" => "review"}, changed.metadata)
    assert_raises(ArgumentError) { original.with(configurable: {}) }
  end

  def test_deadline_and_cancellation_are_distinct
    clock = ManualClock.new(9.0)
    token = Tamoz::CancellationToken.new
    value = context(clock:, cancellation: token, deadline: 10.0)

    assert value.check!
    clock.value = 10.0
    assert value.expired?
    assert_raises(Tamoz::TimeoutError) { value.check! }

    clock.value = 0.0
    token.cancel!("redirected")
    error = assert_raises(Tamoz::CancelledError) { value.check! }
    assert_equal "cancelled", error.category
  end

  def test_cancellation_is_idempotent_waitable_and_unsubscribable
    token = Tamoz::CancellationToken.new
    reasons = []
    retained = token.on_cancel { |reason| reasons << ["retained", reason] }
    removed = token.on_cancel { |reason| reasons << ["removed", reason] }

    assert removed.unsubscribe
    refute removed.unsubscribe
    refute token.wait(timeout: 0)
    assert token.cancel!("shutdown")
    refute token.cancel!("second")
    assert token.wait(timeout: 0)
    assert_equal "shutdown", token.reason
    assert_equal [["retained", "shutdown"]], reasons
    refute retained.unsubscribe
  end

  def test_cancellation_callbacks_are_bounded_and_race_safe
    token = Tamoz::CancellationToken.new(max_callbacks: 1)
    subscription = token.on_cancel { |_reason| nil }
    assert_raises(Tamoz::StateLimitError) { token.on_cancel { |_reason| nil } }
    assert subscription.unsubscribe

    100.times do
      raced = Tamoz::CancellationToken.new
      callbacks = Queue.new
      subscribers = 4.times.map do
        Thread.new { raced.on_cancel { |reason| callbacks << reason } }
      end
      canceller = Thread.new { raced.cancel!("race") }
      (subscribers << canceller).each(&:join)

      assert_equal 4, callbacks.size
      assert_equal ["race"], 4.times.map { callbacks.pop }.uniq
    end
  end

  def test_control_characters_are_rejected_from_operational_identity
    assert_raises(Tamoz::ConfigurationError) { context(run_id: "run\nforged") }
    token = Tamoz::CancellationToken.new
    assert_raises(ArgumentError) { token.cancel!("cancelled\rforged") }
    refute token.cancelled?
  end

  def test_context_emission_carries_explicit_identity
    emitter = RecordingEmitter.new
    value = context(namespace: ["graph"], task_id: "task.1", emitter:)

    assert value.emit(:task_start, {"node" => "answer"})
    assert_equal(
      [[:task_start, ["graph"], {"node" => "answer"}, "run.1", "task.1"]],
      emitter.events
    )
  end

  def test_context_inspection_never_displays_metadata_values
    value = context(metadata: {"credential" => "must-not-appear", "safe" => "also-hidden"})

    assert_includes value.inspect, "credential"
    refute_includes value.inspect, "must-not-appear"
    refute_includes value.inspect, "also-hidden"
  end

  private

  def context(**overrides)
    Tamoz::Context.new(
      run_id: "run.1",
      execution_id: "execution.1",
      request_id: "request.1",
      **overrides
    )
  end
end
