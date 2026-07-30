# frozen_string_literal: true

require_relative "test_helper"

class GraphCheckpointCodecTest < Minitest::Test
  def test_round_trips_a_paused_checkpoint_without_changing_runtime_values
    app = Tamoz.graph(name: "codec-round-trip", version: "1") do
      state :events, reduce: :append, default: []
      node(
        :pause,
        implementation_name: "codec.pause",
        version: "1"
      ) do |_state, context|
        answer = Tamoz.interrupt({"question" => "continue?"}, context)
        {events: [answer]}
      end
      edge Tamoz::START, :pause
      edge :pause, Tamoz::END
    end.compile

    result = app.invoke(
      {},
      thread: "thread.codec",
      request_id: "request.codec",
      execution_id: "execution.codec",
      concurrency: :inline
    )
    assert result.paused?

    checkpoint = app.checkpointer.latest(thread_id: "thread.codec", namespace: [])
    bytes = app.checkpoint_codec.dump(checkpoint.to_h)
    restored = app.checkpoint_codec.load(bytes)

    assert_equal checkpoint.graph_name, restored.fetch(:graph_name)
    assert_equal checkpoint.graph_version, restored.fetch(:graph_version)
    assert_equal checkpoint.definition_digest, restored.fetch(:definition_digest)
    assert_equal checkpoint.execution_id, restored.fetch(:execution_id)
    assert_equal checkpoint.status, restored.fetch(:status)
    assert_equal checkpoint.logical_step, restored.fetch(:logical_step)
    assert_equal checkpoint.state, restored.fetch(:state)
    assert_equal checkpoint.frontier.map(&:descriptor),
                 restored.fetch(:frontier).map(&:descriptor)
    assert_equal checkpoint.pending.transform_values(&:descriptor),
                 restored.fetch(:pending).transform_values(&:descriptor)
    assert_equal checkpoint.interrupts.map(&:to_h),
                 restored.fetch(:interrupts).map(&:to_h)
    assert_equal checkpoint.resume_values, restored.fetch(:resume_values)
    assert_equal checkpoint.attempts, restored.fetch(:attempts)
    assert_nil restored.fetch(:failure)
    assert_equal checkpoint.total_tasks, restored.fetch(:total_tasks)
  end

  def test_rejects_graph_identity_before_decoding_user_values
    decoded = 0
    value_class = Class.new do
      attr_reader :value

      def initialize(value)
        @value = value.freeze
        freeze
      end
    end
    codec = Tamoz::StateCodec.new.with_registration(
      tag: "test.identity_guard",
      version: 1,
      klass: value_class,
      encoder: ->(value) { {"value" => value.value} },
      decoder: lambda { |payload|
        decoded += 1
        value_class.new(payload.fetch("value"))
      },
      immutability: ->(value) { value.frozen? }
    )
    definition = Tamoz.graph(name: "identity-guard", version: "1") do
      state :value
      node(
        :finish,
        implementation_name: "identity.finish",
        version: "1"
      ) { |_state, _context| nil }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
    app = definition.compile(codec:)
    state = app.__send__(:state_manager).initial(
      {"value" => value_class.new("protected")},
      remaining_steps: app.limits.max_steps
    )
    attributes = checkpoint_attributes(app, state:)
    wire = JSON.parse(app.checkpoint_codec.dump(attributes))
    wire[2] = "different-graph"
    tampered = JSON.generate(wire)
    decoded_before_load = decoded

    assert_raises(Tamoz::CheckpointVersionError) do
      app.checkpoint_codec.load(tampered)
    end
    assert_equal decoded_before_load, decoded
  end

  def test_unknown_persisted_node_is_rejected_without_symbol_interning
    app = simple_app
    attributes = checkpoint_attributes(
      app,
      state: app.__send__(:state_manager).initial(
        {},
        remaining_steps: app.limits.max_steps
      )
    )
    wire = JSON.parse(app.checkpoint_codec.dump(attributes))
    unknown = "persisted-node-#{SecureRandom.hex(16)}"
    wire.fetch(9).fetch(0)[0] = unknown
    refute Symbol.all_symbols.any? { |symbol| symbol.to_s == unknown }

    assert_raises(Tamoz::CheckpointCorruptionError) do
      app.checkpoint_codec.load(JSON.generate(wire))
    end
    refute Symbol.all_symbols.any? { |symbol| symbol.to_s == unknown }
  end

  def test_rejects_noncanonical_and_oversized_envelopes
    app = simple_app
    state = app.__send__(:state_manager).initial(
      {},
      remaining_steps: app.limits.max_steps
    )
    bytes = app.checkpoint_codec.dump(checkpoint_attributes(app, state:))

    assert_raises(Tamoz::CheckpointCorruptionError) do
      app.checkpoint_codec.load(" #{bytes}")
    end

    tiny = Tamoz::Graph::CheckpointCodec.new(
      definition: app.definition,
      definition_digest: app.definition_digest,
      state_codec: app.codec,
      max_bytes: 16
    )
    assert_raises(Tamoz::CheckpointCorruptionError) do
      tiny.dump(checkpoint_attributes(app, state:))
    end
  end

  private

  def simple_app
    Tamoz.graph(name: "codec-simple", version: "1") do
      state :value, default: "initial"
      node(
        :finish,
        implementation_name: "codec.finish",
        version: "1"
      ) { |_state, _context| nil }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end.compile
  end

  def checkpoint_attributes(app, state:)
    {
      graph_name: app.name,
      graph_version: app.version,
      definition_digest: app.definition_digest,
      execution_id: "execution.codec",
      status: :running,
      logical_step: 0,
      state:,
      state_bytes: app.codec.dump(state),
      frontier: app.__send__(:route_planner).initial_frontier,
      pending: {}.freeze,
      interrupts: [].freeze,
      resume_values: {}.freeze,
      attempts: {}.freeze,
      failure: nil,
      total_tasks: 0
    }.freeze
  end
end
