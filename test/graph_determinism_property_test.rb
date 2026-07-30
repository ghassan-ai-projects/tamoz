# frozen_string_literal: true

require_relative "test_helper"

class GraphDeterminismPropertyTest < Minitest::Test
  SCHEDULES = 120

  def test_generated_dags_match_an_independent_barrier_model_and_all_schedules
    random = Random.new(20_260_730)

    SCHEDULES.times do |seed|
      layers = generated_layers(random)
      delays = Random.new(seed + 91)
      definition = dag_definition(seed, layers, delays)
      inline = definition.compile
      threaded = definition.compile
      identity = {
        thread: "thread.property.#{seed}",
        request_id: "request.property",
        execution_id: "execution.property.#{seed}"
      }

      inline_result = inline.invoke({}, **identity, concurrency: :inline)
      threaded_result = threaded.invoke({}, **identity, concurrency: :threads)
      expected = reference_barriers(layers)

      assert_equal expected, inline_result.state.fetch(:events), "seed=#{seed}"
      assert_equal expected, threaded_result.state.fetch(:events), "seed=#{seed}"
      assert_equal history_bytes(inline, identity.fetch(:thread)),
                   history_bytes(threaded, identity.fetch(:thread)),
                   "seed=#{seed}"
    end
  end

  def test_generated_cycles_match_a_simple_transition_model
    random = Random.new(7_301)

    40.times do |index|
      threshold = random.rand(1..20)
      app = cycle_definition(index, threshold).compile
      result = app.invoke(
        {},
        thread: "thread.cycle.property.#{index}",
        request_id: "request.1",
        execution_id: "execution.#{index}",
        concurrency: index.even? ? :inline : :threads
      )

      assert result.completed?
      assert_equal threshold, result.state.fetch(:count)
      assert_equal threshold, result.snapshot.sequence
    end
  end

  private

  def generated_layers(random)
    Array.new(random.rand(1..4)) do |level|
      Array.new(random.rand(1..5)) { |index| :"n#{level}_#{index}" }
    end
  end

  def dag_definition(seed, layers, delays)
    Tamoz.graph(name: "property-dag-#{seed}", version: "1") do
      state :events, reduce: :append, default: []
      layers.flatten.each do |node_name|
        node(
          node_name,
          implementation_name: "property.#{seed}.#{node_name}",
          version: "1"
        ) do |state, _context|
          sleep(delays.rand * 0.0003)
          {events: ["#{node_name}@#{state[:events].length}"]}
        end
      end
      layers.first.each { |node_name| edge Tamoz::START, node_name }
      layers.each_cons(2) do |sources, targets|
        sources.each do |source|
          targets.each { |target| edge source, target }
        end
      end
      layers.last.each { |node_name| edge node_name, Tamoz::END }
    end
  end

  def reference_barriers(layers)
    events = []
    layers.each do |layer|
      observed_size = events.length
      writes = layer.sort_by(&:to_s).map do |node_name|
        "#{node_name}@#{observed_size}"
      end
      events += writes
    end
    events
  end

  def history_bytes(app, thread)
    app.history(thread:).reverse.map do |snapshot|
      {
        "id" => snapshot.checkpoint_id,
        "sequence" => snapshot.sequence,
        "status" => snapshot.status.to_s,
        "state" => snapshot.state.transform_keys(&:to_s)
      }
    end.then { |history| JSON.generate(history) }
  end

  def cycle_definition(index, threshold)
    Tamoz.graph(name: "property-cycle-#{index}", version: "1") do
      state :count, reduce: :max, default: 0
      node(
        :tick,
        implementation_name: "property.cycle.#{index}",
        version: "1"
      ) { |state, _context| {count: state[:count] + 1} }
      edge Tamoz::START, :tick
      branch :tick, version: "1", targets: [:tick, Tamoz::END] do |state|
        state[:count] < threshold ? :tick : Tamoz::END
      end
    end
  end
end
