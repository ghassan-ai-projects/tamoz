# frozen_string_literal: true

require_relative "test_helper"

class GraphStateManagerTest < Minitest::Test
  OutcomeStub = Data.define(:task_id, :update)

  def test_initial_input_and_barrier_use_reducers_once_per_whole_batch
    calls = []
    reducer = lambda do |current, writes|
      calls << [current, writes]
      current + writes.sum
    end
    manager = manager(
      total: {
        reduce: reducer,
        reducer_name: "sum-batch",
        reducer_version: "1",
        default: 0
      },
      status: {default: "new"}
    )
    initial = manager.initial({"total" => 1}, remaining_steps: 5)
    outcomes = [
      OutcomeStub.new(task_id: "task.b", update: {total: 3}.freeze),
      OutcomeStub.new(task_id: "task.a", update: {total: 2}.freeze)
    ]
    candidate = manager.apply_outcomes(initial, outcomes, remaining_steps: 4)

    assert_equal({total: 6, status: "new"}, candidate)
    assert_equal [[0, [1]], [1, [3, 2]]], calls
    assert calls.all? { |_current, writes| writes.frozen? }
    assert candidate.frozen?
  end

  def test_last_value_conflict_names_every_writer_and_changes_nothing
    manager = manager(status: {default: "new"})
    initial = manager.initial({}, remaining_steps: 5)
    outcomes = [
      OutcomeStub.new(task_id: "task.b", update: {status: "b"}.freeze),
      OutcomeStub.new(task_id: "task.a", update: {status: "a"}.freeze)
    ]

    error = assert_raises(Tamoz::InvalidUpdateError) do
      manager.apply_outcomes(initial, outcomes, remaining_steps: 4)
    end
    assert_includes error.message, "task.a"
    assert_includes error.message, "task.b"
    assert_equal({status: "new"}, initial)
  end

  def test_managed_channel_is_computed_and_read_only
    manager = manager(
      value: {default: 0},
      remaining_steps: {managed: Tamoz::Managed::RemainingSteps}
    )
    initial = manager.initial({"value" => 1}, remaining_steps: 5)

    assert_equal 5, initial.fetch(:remaining_steps)
    assert_raises(Tamoz::InvalidUpdateError) do
      manager.normalize_update({"remaining_steps" => 99})
    end
    candidate = manager.apply_outcomes(
      initial,
      [OutcomeStub.new(task_id: "task.1", update: {value: 2}.freeze)],
      remaining_steps: 4
    )
    assert_equal 4, candidate.fetch(:remaining_steps)
  end

  def test_unknown_unsupported_and_sensitive_updates_fail_before_candidate
    manager = manager(value: {default: []})

    assert_raises(Tamoz::InvalidUpdateError) { manager.normalize_update({"unknown" => 1}) }
    assert_raises(Tamoz::UnsupportedValueError) do
      manager.normalize_update({"value" => Object.new})
    end
    assert_raises(Tamoz::SensitiveValueError) do
      manager.normalize_update({"value" => Tamoz::Secret.new("token")})
    end
  end

  private

  def manager(**specifications)
    channels = {}
    codec = Tamoz::StateCodec.new
    specifications.each do |name, options|
      options = options.dup
      reducer = Tamoz::Reducers.resolve(
        options.delete(:reduce),
        name: options.delete(:reducer_name),
        version: options.delete(:reducer_version)
      )
      channels[name] = Tamoz::Graph::Channel.new(
        name:,
        reducer:,
        default: options.delete(:default),
        default_name: nil,
        default_version: nil,
        managed: options.delete(:managed),
        codec:
      )
    end
    manager_class = Tamoz::Graph.const_get(:StateManager, false)
    manager_class.new(channels: channels.freeze, codec:)
  end
end
