# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

# THE BAR (docs/PLAN_TAMOZ_STREAM_BUILD.md §7): a supervised DIAGNOSE episode
# runs end to end on the Tamoz side. A stub stream client (the runtime's role,
# per the vendored proto) dials the Ruby EpisodeWorker over gRPC, handshakes,
# sends an EpisodeRequest (snapshot+digest+model_policy+prompt+catalog), and
# receives the complete in-order event stream: started (seq 1), model events
# from receipts, a decision.proposed, exactly one terminal PRODUCED. P1: the
# served graph is THE fixed graph, and the model call hits a real HTTP
# fixture endpoint (labeled fixture).
class StreamEpisodeEndToEndTest < Minitest::Test
  Stream = Tamoz::Stream

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
  def self.rpc
    @rpc ||= begin
      endpoint = LocalModelEndpoint.new(
        mode: :fixture,
        responses: [Tamoz::Core.jcs(
          AquacultureDomain.document(selected: "low_dissolved_oxygen", hypothesis: "oxygen crash")
        )],
        log_path: File.join(Dir.mktmpdir("tamoz-e2e"), "endpoint.log")
      ).start
      composition = EpisodeComposition.build(
        endpoint: endpoint.base_url,
        artifact_store: Stream::ArtifactStore.new
      )
      runner = composition.fetch(:runner)
      artifact_store = runner.instance_variable_get(:@artifact_store)
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
        composition.fetch(:adapter).close
        endpoint.stop
      end
      {client:, adapter: composition.fetch(:adapter), artifact_store:}
    end
  end

  def client = self.class.rpc.fetch(:client)

  def episode_request(suffix)
    request = EpisodeComposition.wire_request(
      episode_id: "e2e-#{suffix}",
      attempt: suffix,
      allowed_intent_types: ["install_watch_condition", "start_aerator"]
    )
    request.capability_token = "opaque.hmac.token"
    request
  end

  def raw_digest(digest)
    [digest.delete_prefix("sha256:")].pack("H*")
  end

  def raw_digest_episode_request(suffix)
    request = episode_request(suffix)
    # P1: the fixed graph VERIFIES the prompt digest against the frame, so the
    # raw override must carry the ACTUAL prompt's digest (raw form) while the
    # manifest-named documents keep their own arbitrary raw digests.
    request.prompt_sha256 = raw_digest(
      EpisodeComposition.prompt_sha256(request.prompt)
    )
    request.tool_catalog_sha256 = raw_digest("sha256:#{"b" * 64}")
    request.decision_schema_sha256 = raw_digest("sha256:#{"c" * 64}")
    request.objective_sha256 = raw_digest("sha256:#{"d" * 64}")
    request.tool_catalog_json = JSON.generate({"tools" => ["compressor.read"]})
    request.decision_schema_json = JSON.generate({"type" => "object"})
    request.objective = "diagnose the pond"
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
    assert_equal "start_aerator", decision.fetch("intents").fetch(0).fetch("type"),
                 "the spec allowlist must determine the admissible low-confidence action"
    assert_equal "R1", decision.fetch("intents").fetch(0).fetch("risk_class")
    assert_operator decision_event.sequence, :<, events.last.sequence

    # Model events crossed from the RECEIPT, with digests on the wire.
    model_started = events.find { |event| event.model_started != nil }
    refute_nil model_started, "the receipt's model_started must cross"
    assert_equal 32, model_started.model_started.request_sha256.bytesize
    model_completed = events.find { |event| event.model_completed != nil }
    refute_nil model_completed, "the receipt's model_completed must cross"
    assert_equal 32, model_completed.model_completed.response_sha256.bytesize
    assert_equal 42, model_completed.model_completed.usage.input_tokens,
                 "the fixture endpoint's reported usage crosses from the receipt"
  end

  def test_a_tampered_snapshot_fails_before_any_model_event
    request = episode_request("tampered")
    request.snapshot_json = request.snapshot_json.sub("sit-do-crash", "sit-9")

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
    assert_equal(
      EpisodeComposition.prompt_sha256(request.prompt),
      Tamoz::Core.normalize_digest(manifest.prompt_sha256),
      "the manifest names the prompt under its own digest"
    )
    assert_equal "sha256:#{"b" * 64}",
                 Tamoz::Core.normalize_digest(manifest.tool_catalog_sha256)

    store = self.class.rpc.fetch(:artifact_store)
    assert_equal JSON.generate({"tools" => ["compressor.read"]}),
                 store.resolve("sha256:#{"b" * 64}").fetch("bytes")
    assert_equal JSON.generate({"type" => "object"}),
                 store.resolve("sha256:#{"c" * 64}").fetch("bytes")
    assert_equal "diagnose the pond",
                 store.resolve("sha256:#{"d" * 64}").fetch("bytes")
  end
end
