# frozen_string_literal: true

require_relative 'test_helper'

class ObservabilitySignalTest < Minitest::Test
  Signal = Tamoz::Observability::Signal

  def build_point(**overrides)
    Signal.build(
      kind: :event, name: 'tamoz.model.call', timing: :point,
      correlation: { thread_id: 'thread.1', execution_id: 'execution.1' },
      observed_at_ms: 1_000, **overrides
    )
  end

  def test_a_signal_is_frozen_through_its_attributes
    signal = build_point(attributes: { provider: 'fake' })

    assert_predicate signal, :frozen?
    assert_predicate signal.attributes, :frozen?
    assert_predicate signal.correlation, :frozen?
  end

  def test_attributes_cannot_be_mutated_through_the_signal_or_the_source
    attributes = { provider: 'fake' }
    signal = build_point(attributes:)

    assert_raises(FrozenError) { signal.attributes[:provider] = 'mutated' }
    attributes[:provider] = 'mutated'

    assert_equal 'fake', signal.attributes.fetch(:provider)
  end

  def test_schema_version_defaults_to_the_catalog_version
    assert_equal Tamoz::Observability::SCHEMA_VERSION, build_point.schema_version
  end

  def test_kind_timing_and_outcome_are_closed_sets
    assert_raises(Tamoz::Observability::ValidationError) { build_point(kind: :metric) }
    assert_raises(Tamoz::Observability::ValidationError) { build_point(timing: :sometimes) }
    assert_raises(Tamoz::Observability::ValidationError) { build_point(outcome: :fine) }
  end

  def test_an_interval_carries_bounds_and_a_duration
    signal = Signal.build(
      kind: :span, name: 'tamoz.model.call', timing: :interval,
      correlation: {}, started_at_ms: 100, ended_at_ms: 250, observed_at_ms: 250
    )

    assert_equal 150, signal.duration_ms
    assert_raises(Tamoz::Observability::ValidationError) do
      Signal.build(
        kind: :span, name: 'tamoz.model.call', timing: :interval,
        correlation: {}, started_at_ms: 250, ended_at_ms: 100, observed_at_ms: 250
      )
    end
    assert_raises(Tamoz::Observability::ValidationError) do
      Signal.build(
        kind: :span, name: 'tamoz.model.call', timing: :interval,
        correlation: {}, observed_at_ms: 250
      )
    end
  end

  def test_an_ordering_only_span_has_no_duration
    signal = Signal.build(
      kind: :span, name: 'tamoz.plan.review', timing: :ordering_only,
      correlation: {}, observed_at_ms: 250
    )

    assert_nil signal.duration_ms
    assert_nil signal.started_at_ms
    assert_raises(Tamoz::Observability::ValidationError) do
      Signal.build(
        kind: :span, name: 'tamoz.plan.review', timing: :ordering_only,
        correlation: {}, started_at_ms: 100, observed_at_ms: 250
      )
    end
  end

  def test_error_outcomes_carry_a_typed_error_class
    signal = build_point(outcome: :error, error_class: 'Tamoz::TimeoutError')

    assert_equal %i[error], [signal.outcome]
    assert_equal 'Tamoz::TimeoutError', signal.error_class
  end

  def test_error_class_is_required_exactly_when_the_outcome_is_not_ok
    assert_raises(Tamoz::Observability::ValidationError) { build_point(outcome: :unknown) }
    assert_raises(Tamoz::Observability::ValidationError) do
      build_point(outcome: :ok, error_class: 'Tamoz::TimeoutError')
    end
  end

  def test_attribute_size_and_count_are_bounded
    assert_raises(Tamoz::Observability::ValidationError) do
      build_point(attributes: { blob: 'x' * (Signal::MAX_ATTRIBUTE_STRING_BYTES + 1) })
    end
    assert_raises(Tamoz::Observability::ValidationError) do
      build_point(attributes: (1..(Signal::MAX_ATTRIBUTES + 1)).to_h { |i| [:"k#{i}", i] })
    end
  end

  def test_attribute_values_are_typed
    assert_raises(Tamoz::Observability::ValidationError) do
      build_point(attributes: { value: Float::NAN })
    end
    assert_raises(Tamoz::Observability::ValidationError) do
      build_point(attributes: { value: Object.new })
    end
  end
end
