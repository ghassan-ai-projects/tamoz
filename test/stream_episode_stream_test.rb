# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"

# T2.1/T2.2 (PLAN_TAMOZ_STREAM_BUILD): the wire event vocabulary. The episode
# stream builds EpisodeEvent payloads with exact sequence 1..N, identity on
# every event, and exactly one terminal; the adapter maps the graph's emitter
# events (tasks, model calls with usage) to the wire; the budget ceiling turns
# a run into TIMED_OUT or BUDGET_EXHAUSTED.
class StreamEpisodeStreamTest < Minitest::Test
  Stream = Tamoz::Stream

  def worker
    Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
  end

  def snapshot_pair
    value = {
      "situation_id" => "sit-1",
      "situation_version" => 7,
      "tenant_id" => "acme",
      "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 1e-7},
      "event_horizon" => "2026-08-19T00:00:00Z"
    }
    [Tamoz::Core.jcs(value), Tamoz::Core.digest(:snapshot, value)]
  end

  def wire_request(overrides = {})
    snapshot_json, snapshot_sha256 = snapshot_pair
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-1",
      attempt_id: "at-1",
      fence: 1,
      tenant_id: "acme",
      situation_id: "sit-1",
      situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE,
      lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      snapshot_json:,
      snapshot_sha256:,
      **overrides
    )
  end

  # A graph whose nodes surface tool + model events through the context
  # emitter — the shape the episode graph takes in T2.4.
  def eventful_graph
    Tamoz.graph(name: "episode-eventful", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :answers, reduce: :merge, default: {}
      node(
        :inspect,
        implementation_name: "episode.inspect",
        version: "1"
      ) do |state, context|
        context.emit(
          :model_started, {ordinal: 0, provider: "test", model_id: "flash"}
        )
        context.emit(
          :model_delta, {ordinal: 0, content: "bearing wear likely"}
        )
        context.emit(
          :model_completed,
          {ordinal: 0, usage: {input_tokens: 12, output_tokens: 4, cost_microunits: 30}}
        )
        {answers: {"inspection" => "bearing wear likely"}}
      end
      edge Tamoz::START, :inspect
      edge :inspect, Tamoz::END
    end
  end

  def with_eventful_app
    Dir.mktmpdir("tamoz-episode-stream") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
      app = eventful_graph.compile(checkpointer: adapter)
      runner = Stream::EpisodeRunner.new(durable_runner: app.durable_runner, worker:)
      yield runner
      adapter.close
    end
  end

  def test_the_event_stream_has_exact_sequence_identity_and_one_terminal
    with_eventful_app do |runner|
      events = runner.run(wire_request).to_a

      assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
      events.each_with_index do |event, index|
        assert_equal index + 1, event.sequence, "sequence must be exactly 1..N"
        assert_equal "ep-1", event.episode_id
        assert_equal "at-1", event.attempt_id
        assert_equal 1, event.fence
        refute_nil event.occurred_at
      end
      terminals = events.select { |event| event.terminal != nil }
      assert_equal 1, terminals.length, "exactly one terminal"
    end
  end

  def test_model_and_tool_events_cross_the_wire_with_usage_and_budget
    with_eventful_app do |runner|
      events = runner.run(wire_request).to_a

      started = events.find { |event| event.started != nil }
      refute_nil started, "the stream must open with episode.started"
      model = events.find { |event| event.model_completed != nil }
      refute_nil model, "a model_completed event must cross"
      assert_equal 12, model.model_completed.usage.input_tokens
      assert_equal 4, model.model_completed.usage.output_tokens
      assert_equal 30, model.model_completed.usage.cost_microunits

      budget = events.find { |event| event.budget != nil }
      refute_nil budget, "a budget.updated event must cross after usage"
      assert_equal 1, budget.budget.model_calls_used
    end
  end

  def test_a_model_call_budget_ceiling_reports_budget_exhausted
    stream = Stream::EpisodeStream.new(
      Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    )
    budget = Agenticstream::Runtime::V1::EpisodeBudget.new(max_model_calls: 1)
    adapter = Stream::EpisodeStreamAdapter.new(stream, budget:)
    adapter.model_started(ordinal: 0, provider: "test", model_id: "flash")
    adapter.model_completed(ordinal: 0, usage: {input_tokens: 5})
    adapter.model_started(ordinal: 1, provider: "test", model_id: "flash")
    adapter.model_completed(ordinal: 1, usage: {input_tokens: 5})

    status, reason = adapter.terminal_status(nil)
    assert_equal :TERMINAL_STATUS_BUDGET_EXHAUSTED, status
    assert_equal "max_model_calls", reason
  end

  def test_a_wall_time_ceiling_reports_timed_out
    stream = Stream::EpisodeStream.new(
      Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    )
    budget = Agenticstream::Runtime::V1::EpisodeBudget.new(
      wall_time: Google::Protobuf::Duration.new(seconds: 1)
    )
    adapter = Stream::EpisodeStreamAdapter.new(stream, budget:)
    adapter.instance_variable_set(:@started_at, Time.now.to_i - 5)

    status, reason = adapter.terminal_status(nil)
    assert_equal :TERMINAL_STATUS_TIMED_OUT, status
    assert_equal "wall_time", reason
  end

  def test_the_adapter_never_emits_two_terminals
    stream = Stream::EpisodeStream.new(
      Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    )
    adapter = Stream::EpisodeStreamAdapter.new(stream)
    adapter.terminal(nil)
    assert stream.terminal_emitted?
    assert_raises(Tamoz::Stream::StreamError) { adapter.terminal(nil) }
  end

  # T2.2 blocker regression: the cancellation watcher cancels the run's token
  # with the token's actual API (cancel!, positional reason).
  def test_the_cancellation_watcher_cancels_the_run_token
    flag = false
    call = Object.new
    call.define_singleton_method(:cancelled?) { flag }
    envelope = Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    context = Tamoz::Context.new(
      run_id: envelope.request_id,
      execution_id: "episode.ep-1.at-1.1",
      request_id: envelope.request_id
    )
    runner = Stream::EpisodeRunner.new(durable_runner: nil, worker:)
    watcher = runner.send(:watch_cancellation, call, context)
    sleep 0.15
    assert_equal false, context.cancellation.cancelled?,
                 "no cancellation before the call is cancelled"
    flag = true
    sleep 0.2
    assert context.cancellation.cancelled?,
           "the watcher must cancel the run token when the RPC is cancelled"
    assert_equal "rpc cancelled", context.cancellation.reason
    watcher.kill
  end

  # T2.1 blocker regression: RubyLLMModel#generate surfaces usage through the
  # emitter (data must land in the third positional slot, and the usage must
  # cross to the wire).
  def test_the_model_client_surfaces_usage_through_the_emitter
    response = Object.new
    response.define_singleton_method(:content) { "analysis" }
    response.define_singleton_method(:usage) do
      usage = Object.new
      usage.define_singleton_method(:input_tokens) { 12 }
      usage.define_singleton_method(:output_tokens) { 4 }
      usage.define_singleton_method(:cached_input_tokens) { 0 }
      usage.define_singleton_method(:reasoning_tokens) { 0 }
      usage.define_singleton_method(:cost) { 0.00003 }
      usage
    end
    chat = Object.new
    chat.define_singleton_method(:with_instructions) { |_| chat }
    chat.define_singleton_method(:ask) { |_| response }
    model_context = Object.new
    model_context.define_singleton_method(:chat) { |**_kwargs| chat }
    context_factory = Object.new
    context_factory.define_singleton_method(:call) { |&_block| model_context }

    model = Tamoz::Agent::RubyLLMModel.new(
      model: "flash", provider: "ollama", context_factory:
    )
    stream = Stream::EpisodeStream.new(
      Stream::EpisodeRequestEnvelope.new(wire_request, worker)
    )
    adapter = Stream::EpisodeStreamAdapter.new(stream)
    content = model.generate(
      stage: "episode", system: "s", prompt: "p", emitter: adapter
    )

    assert_equal "analysis", content
    completed = stream.events.find { |event| event.model_completed != nil }
    refute_nil completed, "a model_completed event must cross from the model client"
    assert_equal 12, completed.model_completed.usage.input_tokens
    assert_equal 4, completed.model_completed.usage.output_tokens
    assert_equal 30, completed.model_completed.usage.cost_microunits
    started = stream.events.find { |event| event.model_started != nil }
    refute_nil started
    assert_equal "flash", started.model_started.model_id
  end
end
