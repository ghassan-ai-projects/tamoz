# frozen_string_literal: true

require_relative "test_helper"

class GraphDefinitionTest < Minitest::Test
  class PassNode
    def self.call(_state, _context)
      nil
    end
  end

  def test_definition_compiles_to_a_stable_digest_independent_of_declaration_order
    first = graph(order: %i[count status])
    second = graph(order: %i[status count])

    assert_equal first.definition_digest, second.definition_digest
    assert_match(/\Asha256:[0-9a-f]{64}\z/, first.definition_digest)
    assert first.frozen?
    assert first.definition_digest.frozen?
    assert first.definition.frozen?
    assert first.channels.values.all?(&:frozen?)
  end

  def test_structural_change_changes_definition_digest
    first = graph(order: %i[count status], node_version: "1")
    second = graph(order: %i[count status], node_version: "2")

    refute_equal first.definition_digest, second.definition_digest
  end

  def test_equivalent_declaration_orders_have_identical_runtime_observation
    first = key_observation_graph(%i[zeta alpha]).compile
    second = key_observation_graph(%i[alpha zeta]).compile
    identity = {
      thread: "thread.order",
      request_id: "request.1",
      execution_id: "execution.1",
      concurrency: :inline
    }

    first_result = first.invoke({}, **identity)
    second_result = second.invoke({}, **identity)

    assert_equal ["alpha", "observed", "zeta"], first_result.state.fetch(:observed)
    assert_equal first_result.state, second_result.state
    assert_equal first_result.snapshot.checkpoint_id,
                 second_result.snapshot.checkpoint_id
  end

  def test_branch_requires_declared_targets_and_validates_reachability
    error = assert_raises(ArgumentError) do
      Tamoz.graph(name: "invalid", version: "1") do
        state :status
        node :start, PassNode
        branch(:start, version: "1") { |_state| Tamoz::END }
      end
    end
    assert_includes error.message, "targets"

    error = assert_raises(Tamoz::GraphDefinitionError) do
      Tamoz.graph(name: "invalid", version: "1") do
        state :status
        node :start, PassNode
        node :orphan, PassNode
        edge Tamoz::START, :start
        edge :start, Tamoz::END
      end.compile
    end
    assert_includes error.message, "unreachable"
  end

  def test_compile_rejects_unknown_targets_and_nonterminating_declared_cycles
    unknown = Tamoz.graph(name: "unknown", version: "1") do
      state :status
      node :start, PassNode
      edge Tamoz::START, :start
      edge :start, :missing
    end
    assert_raises(Tamoz::GraphDefinitionError) { unknown.compile }

    cycle = Tamoz.graph(name: "cycle", version: "1") do
      state :status
      node :left, PassNode
      node :right, PassNode
      edge Tamoz::START, :left
      edge :left, :right
      edge :right, :left
    end
    error = assert_raises(Tamoz::GraphDefinitionError) { cycle.compile }
    assert_includes error.message, "END"
  end

  def test_duplicates_and_invalid_identifiers_fail_closed
    assert_raises(Tamoz::GraphDefinitionError) do
      Tamoz.graph(name: "bad\nname", version: "1") { state :value }
    end
    assert_raises(Tamoz::GraphDefinitionError) do
      Tamoz.graph(name: "duplicate", version: "1") do
        state :value
        state :value
      end
    end
    assert_raises(Tamoz::GraphDefinitionError) do
      Tamoz.graph(name: "duplicate", version: "1") do
        state :value
        node :step, PassNode
        node :step, PassNode
      end
    end
  end

  def test_anonymous_behavior_and_custom_reducer_require_explicit_identity
    assert_raises(Tamoz::GraphDefinitionError) do
      Tamoz.graph(name: "identity", version: "1") do
        state :value
        node(:step) { |_state, _context| nil }
        edge Tamoz::START, :step
        edge :step, Tamoz::END
      end
    end

    assert_raises(Tamoz::GraphDefinitionError) do
      Tamoz.graph(name: "identity", version: "1") do
        state :value, reduce: ->(current, writes) { current + writes.sum }
      end
    end
  end

  def test_callable_default_is_canonicalized_and_must_be_deterministic
    calls = 0
    definition = Tamoz.graph(name: "defaults", version: "1") do
      state(
        :items,
        default: lambda do
          calls += 1
          []
        end,
        default_name: "empty-items",
        default_version: "1"
      )
      node :step, PassNode
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end
    compiled = definition.compile

    assert_equal 2, calls
    assert_equal [], compiled.channels.fetch(:items).default(Tamoz::StateCodec.new)

    random = 0
    assert_raises(Tamoz::GraphDefinitionError) do
      Tamoz.graph(name: "random-default", version: "1") do
        state(
          :value,
          default: -> { random += 1 },
          default_name: "counter",
          default_version: "1"
        )
      end
    end
  end

  def test_command_and_send_values_are_immutable_and_reject_unsupported_values
    input = {"item" => ["a"]}
    send_value = Tamoz.send_to(:worker, input, key: "item-1")
    command = Tamoz::Command.new(
      update: {"status" => "ready"},
      goto: [send_value, Tamoz::END]
    )
    input.fetch("item") << "mutated"

    assert_equal({"item" => ["a"]}, send_value.input)
    assert send_value.input.frozen?
    assert command.update.frozen?
    assert command.goto.frozen?
    assert_raises(Tamoz::SensitiveValueError) do
      Tamoz::Command.new(update: {"secret" => Tamoz::Secret.new("token")})
    end
    assert_raises(Tamoz::UnsupportedValueError) do
      Tamoz.send_to(:worker, {"status" => :symbol_value})
    end
  end

  def test_routing_mode_must_match_declared_successor_shape
    dynamic_with_static = Tamoz.graph(name: "dynamic-static", version: "1") do
      state :value
      node :dispatch, PassNode, routing: :dynamic, routes: [Tamoz::END]
      edge Tamoz::START, :dispatch
      edge :dispatch, Tamoz::END
    end
    assert_raises(Tamoz::GraphDefinitionError) { dynamic_with_static.compile }

    additive_without_static = Tamoz.graph(name: "additive-only", version: "1") do
      state :value
      node :dispatch, PassNode, routing: :additive, routes: [Tamoz::END]
      edge Tamoz::START, :dispatch
    end
    error = assert_raises(Tamoz::GraphDefinitionError) do
      additive_without_static.compile
    end
    assert_match(/requires a static or branch successor/, error.message)
  end

  def test_compile_rejects_invalid_runtime_dependencies_before_execution
    definition = Tamoz.graph(name: "dependencies", version: "1") do
      state :value
      node :step, PassNode
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end

    assert_raises(Tamoz::GraphDefinitionError) { definition.compile(codec: Object.new) }
    assert_raises(Tamoz::GraphDefinitionError) do
      definition.compile(checkpointer: Object.new)
    end
    assert_raises(Tamoz::GraphDefinitionError) { definition.compile(limits: Object.new) }
  end

  private

  def graph(order:, node_version: "1")
    Tamoz.graph(name: "definition", version: "1") do
      order.each do |channel|
        if channel == :count
          state :count, reduce: :max, default: 0
        else
          state :status, default: "new"
        end
      end
      node :step, PassNode, version: node_version
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end.compile
  end

  def key_observation_graph(order)
    Tamoz.graph(name: "key-observation", version: "1") do
      order.each { |name| state name }
      state :observed, default: []
      node(
        :step,
        implementation_name: "key-observation.step",
        version: "1"
      ) { |state, _context| {observed: state.keys.map(&:to_s)} }
      edge Tamoz::START, :step
      edge :step, Tamoz::END
    end
  end
end
