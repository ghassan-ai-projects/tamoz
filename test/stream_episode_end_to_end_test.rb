# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"

# THE BAR (docs/PLAN_TAMOZ_STREAM_BUILD.md §7): a supervised DIAGNOSE episode
# runs end to end on the Tamoz side. A stub stream client (the runtime's role,
# per the vendored proto) dials the Ruby EpisodeWorker over gRPC, handshakes,
# sends an EpisodeRequest (snapshot+digest+budget+token), and receives the
# complete in-order event stream: started (seq 1), model/tool events, a
# decision.proposed, exactly one terminal PRODUCED.
class StreamEpisodeEndToEndTest < Minitest::Test
  Stream = Tamoz::Stream

  def self.episode_graph
    Tamoz.graph(name: "episode-diagnose", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      state :summary, default: nil
      state :facts_used, default: []
      state :alternatives, default: []
      state :watch_metric, default: nil
      state :watch_threshold, default: nil
      node(
        :analyze,
        implementation_name: "episode.analyze",
        version: "1"
      ) do |state, context|
        facts = state.fetch(:snapshot).fetch("facts")
        pressure = facts.fetch("pressure", 0.0)
        context.emit(
          :model_started, {ordinal: 0, provider: "test", model_id: "flash"}
        )
        context.emit(:model_delta, {ordinal: 0, content: "analyzing pressure"})
        context.emit(
          :model_completed,
          {ordinal: 0, usage: {input_tokens: 9, output_tokens: 3, cost_microunits: 12}}
        )
        {
          primary_hypothesis: "bearing wear risk",
          confidence: pressure < 0.5 ? 0.3 : 0.9,
          summary: "pressure #{pressure} suggests bearing wear",
          facts_used: [{"pressure" => pressure}],
          alternatives: [{"hypothesis" => "normal wear"}],
          watch_metric: "condition_score",
          watch_threshold: 0.8
        }
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end
  end

  def worker(worker_runner)
    Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      runner: worker_runner,
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
  end

  # ONE server + ONE durable database for the class (gRPC crashes on rapid
  # RpcServer create/stop; a shared DB keeps the episode ids unique per test).
  # The runner needs no worker for the run path (lane/model resolution is
  # called only by the envelope's model_identifier, which the wire path never
  # invokes), so the worker is wired with the runner after construction.
  def self.rpc
    @rpc ||= begin
      directory = Dir.mktmpdir("tamoz-episode-e2e")
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
      app = episode_graph.compile(checkpointer: adapter)
      artifact_store = Stream::ArtifactStore.new
      runner = Stream::EpisodeRunner.new(
        durable_runner: app.durable_runner, worker: nil, artifact_store:
      )
      server_worker = Stream::EpisodeWorker.new(
        worker_version: "0.1.0.alpha.1",
        runner:,
        lane_config: Tamoz::Agent::LaneConfig.build(
          "fast" => "flash", "deep" => "pro", "batch" => "flash"
        )
      )
      server = GRPC::RpcServer.new
      # The e2e dials over TCP (the grpc-ruby server binding does not accept
      # unix:// URIs); the production worker socket (UDS + mTLS) is the server
      # wiring task, not the wire-contract test.
      port = server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
      server.handle(server_worker)
      thread = Thread.new { server.run_till_terminated }
      client = Agenticstream::Runtime::V1::EpisodeWorker::Stub.new(
        "127.0.0.1:#{port}", :this_channel_is_insecure
      )
      Minitest.after_run do
        server.stop
        thread.join(5)
        adapter.close
      end
      {client:, adapter:, artifact_store:}
    end
  end

  def client = self.class.rpc.fetch(:client)

  def snapshot_pair
    value = {
      "situation_id" => "sit-1",
      "situation_version" => 7,
      "tenant_id" => "acme",
      "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.2},
      "event_horizon" => "2026-08-19T00:00:00Z"
    }
    [Tamoz::Core.jcs(value), Tamoz::Core.digest(:snapshot, value)]
  end

  def episode_request(suffix)
    snapshot_json, snapshot_sha256 = snapshot_pair
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "e2e-#{suffix}",
      attempt_id: "at-#{suffix}",
      fence: 1,
      tenant_id: "acme",
      situation_id: "sit-1",
      situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE,
      lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R1,
      allowed_intent_types: ["create_maintenance_ticket", "recommend_operating_limit"],
      capability_token: "opaque.hmac.token",
      budget: Agenticstream::Runtime::V1::EpisodeBudget.new(max_model_calls: 5),
      snapshot_json:,
      snapshot_sha256:
    )
  end

  def raw_digest(digest)
    [digest.delete_prefix("sha256:")].pack("H*")
  end

  def raw_digest_episode_request(suffix)
    request = episode_request(suffix)
    request.snapshot_sha256 = raw_digest(request.snapshot_sha256)
    request.prompt_sha256 = raw_digest("sha256:#{"a" * 64}")
    request.tool_catalog_sha256 = raw_digest("sha256:#{"b" * 64}")
    request.decision_schema_sha256 = raw_digest("sha256:#{"c" * 64}")
    request.objective_sha256 = raw_digest("sha256:#{"d" * 64}")
    request.tool_catalog_json = JSON.generate({"tools" => ["compressor.read"]})
    request.decision_schema_json = JSON.generate({"type" => "object"})
    request.objective = "diagnose the compressor"
    request
  end

  def test_a_full_diagnose_episode_streams_a_decision_and_one_terminal
    request = episode_request("full")

    response = client.handshake(
      Agenticstream::Runtime::V1::HandshakeRequest.new(
        protocol_version: "1.0", contract_version: "1.0",
        worker_id: "tamoz-e2e", runtime_instance_id: "runtime-1",
        non_interactive: true
      )
    )
    assert_equal "1.0", response.protocol_version

    events = client.execute(request).each.to_a
    refute_empty events

    # Sequence exactly 1..N with identity on every event.
    events.each_with_index do |event, index|
      assert_equal index + 1, event.sequence
      assert_equal request.episode_id, event.episode_id
      assert_equal request.attempt_id, event.attempt_id
      assert_equal 1, event.fence
      refute_nil event.occurred_at
    end

    # Opens with started, closes with exactly one terminal PRODUCED.
    assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
    terminals = events.select { |event| event.terminal != nil }
    assert_equal 1, terminals.length

    # A decision.proposed precedes the terminal and verifies its digest.
    decision_event = events.find { |event| event.decision != nil }
    refute_nil decision_event, "a produced episode must propose a decision"
    decision_json = decision_event.decision.decision_json
    decision = JSON.parse(decision_json)
    assert Tamoz::Core.verify_digest(
      :decision, decision, decision_event.decision.decision_sha256
    )
    assert_equal request.episode_id, decision.fetch("episode_id")
    assert_equal "create_maintenance_ticket", decision.fetch("intents").fetch(0).fetch("type"),
                 "the spec allowlist must determine the admissible low-confidence action"
    assert_equal "R1", decision.fetch("intents").fetch(0).fetch("risk_class")
    assert_operator decision_event.sequence, :<, events.last.sequence

    # Budget telemetry crossed after the model call.
    budget = events.find { |event| event.budget != nil }
    refute_nil budget
    assert_equal 1, budget.budget.model_calls_used
    assert_equal 9, budget.budget.cumulative_usage.input_tokens
  end

  def test_a_tampered_snapshot_fails_before_any_model_event
    request = episode_request("tampered")
    request.snapshot_json = request.snapshot_json.sub("sit-1", "sit-9")

    events = client.execute(request).each.to_a
    assert_equal :TERMINAL_STATUS_FAILED, events.last.terminal.status
    model_events = events.select { |event| event.model_started != nil }
    assert_empty model_events, "no model call may run for a tampered snapshot"
  end

  def test_raw_wire_digests_run_to_a_decision_and_retain_artifacts
    request = raw_digest_episode_request("raw-digests")

    events = client.execute(request).each.to_a

    assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
    refute_nil events.find { |event| event.decision != nil }
    manifest = events.last.terminal.artifact_manifest
    assert_equal "sha256:#{"a" * 64}", Tamoz::Core.normalize_digest(manifest.prompt_sha256)
    assert_equal "sha256:#{"b" * 64}",
                 Tamoz::Core.normalize_digest(manifest.tool_catalog_sha256)

    store = self.class.rpc.fetch(:artifact_store)
    assert_equal JSON.generate({"tools" => ["compressor.read"]}),
                 store.resolve("sha256:#{"b" * 64}").fetch("bytes")
    assert_equal JSON.generate({"type" => "object"}),
                 store.resolve("sha256:#{"c" * 64}").fetch("bytes")
    assert_equal "diagnose the compressor",
                 store.resolve("sha256:#{"d" * 64}").fetch("bytes")
  end
end
