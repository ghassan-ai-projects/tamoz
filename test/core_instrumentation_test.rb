# frozen_string_literal: true

require_relative "test_helper"

class CoreInstrumentationTest < Minitest::Test
  ContextStub = Data.define(:notifier)

  class RecordingNotifier
    attr_reader :events

    def initialize(&behavior)
      @behavior = behavior
      @events = []
    end

    def instrument(name, payload, &block)
      @events << [name, payload]
      return @behavior.call(block) if @behavior
      return block.call if block

      true
    end
  end

  def test_no_notifier_path_preserves_block_result
    calls = 0
    context = ContextStub.new(nil)

    result = Tamoz.instrument("tamoz.test.v1", {"key" => "value"}, context:) do
      calls += 1
      :result
    end

    assert_equal :result, result
    assert_equal 1, calls
  end

  def test_notifier_cannot_replace_result_or_execute_block_twice
    calls = 0
    notifier = RecordingNotifier.new do |block|
      block.call
      block.call
      :notifier_result
    end
    context = ContextStub.new(notifier)

    result = Tamoz.instrument("tamoz.test.v1", {}, context:) do
      calls += 1
      :application_result
    end

    assert_equal :application_result, result
    assert_equal 1, calls
  end

  def test_notifier_failure_before_or_after_yield_does_not_change_result
    before = RecordingNotifier.new { |_block| raise "before" }
    after = RecordingNotifier.new do |block|
      block.call
      raise "after"
    end

    assert_equal :ok, Tamoz.instrument("tamoz.test.v1", {}, context: ContextStub.new(before)) { :ok }
    assert_equal :ok, Tamoz.instrument("tamoz.test.v1", {}, context: ContextStub.new(after)) { :ok }
  end

  def test_application_exception_wins_with_original_object
    failure = Class.new(StandardError).new("application failure")
    notifier = RecordingNotifier.new do |block|
      block.call
    rescue StandardError
      :notifier_swallowed
    end

    actual = assert_raises(failure.class) do
      Tamoz.instrument("tamoz.test.v1", {}, context: ContextStub.new(notifier)) { raise failure }
    end
    assert_same failure, actual
  end

  def test_payload_is_copied_frozen_and_rejects_secrets
    payload = {"nested" => ["value"]}
    notifier = RecordingNotifier.new
    context = ContextStub.new(notifier)

    assert Tamoz.instrument("tamoz.test.v1", payload, context:)
    observed = notifier.events.first.fetch(1)
    payload.fetch("nested") << "mutated"
    assert_equal({"nested" => ["value"]}, observed)
    assert observed.frozen?
    assert observed.fetch("nested").frozen?

    assert_raises(Tamoz::SensitiveValueError) do
      Tamoz.instrument(
        "tamoz.test.v1",
        {"secret" => Tamoz::Secret.new("token")},
        context:
      )
    end
  end

  def test_event_names_are_safe_stable_identifiers
    context = ContextStub.new(RecordingNotifier.new)

    assert Tamoz.instrument("tamoz.plan.review.v1", {}, context:)
    ["UPPERCASE", "contains space", "forged\nline", ".leading"].each do |name|
      assert_raises(ArgumentError, name) { Tamoz.instrument(name, {}, context:) }
    end
  end

  def test_configuration_values_are_frozen_and_atomically_replaced
    current = Tamoz.configuration
    begin
      configured = Tamoz.configure do |config|
        config.concurrency = :inline
        config.pool_size = 2
        config.stream_buffer = 4
      end

      assert configured.frozen?
      assert_equal :inline, configured.concurrency
      assert_equal 2, configured.pool_size
      assert_equal 4, configured.stream_buffer
      refute_same current, configured
      assert_same configured, Tamoz.configuration
      assert_raises(Tamoz::ConfigurationError) do
        Tamoz::Configuration.new(pool_size: 0)
      end
    ensure
      Tamoz.configure do |config|
        config.concurrency = current.concurrency
        config.pool_size = current.pool_size
        config.recursion_limit = current.recursion_limit
        config.stream_buffer = current.stream_buffer
        config.notifier = current.notifier
      end
    end
  end
end
