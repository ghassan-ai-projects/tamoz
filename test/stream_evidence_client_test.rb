# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/evidence_client"

# T3 (PLAN_TAMOZ_STREAM_BUILD T3): the reverse evidence channel. The
# EvidenceClient dials a real EvidenceTools gRPC server (hosted in-process for
# the test — the stream's host lives in agentic-stream), scopes the call to
# the request identity + snapshot identity, and REFUSES a result that is
# misrouted (identity mismatch), tampered (digest mismatch), undigested, or
# out of token scope (server refusal). The containment host binds the
# evidence adapter, so an episode can fetch evidence but still holds no
# effectful capability.
class StreamEvidenceClientTest < Minitest::Test
  Client = Tamoz::Stream::EvidenceClient
  Host = Tamoz::Stream::EpisodeCapabilityHost

  def self.identity
    {
      endpoint: "127.0.0.1:1",
      capability_token: "opaque.hmac.token",
      episode_id: "ep-1", attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      entity_id: "c-01"
    }
  end

  def build_client(overrides = {})
    Client.new(**self.class.identity.merge(overrides))
  end

  # ONE EvidenceTools server for the class (gRPC crashes on rapid RpcServer
  # create/stop). The handler is a scriptable lambda over the request.
  def self.evidence_server
    @evidence_server ||= begin
      service = EvidenceToolsServiceDouble.new
      server = GRPC::RpcServer.new
      port = server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
      server.handle(service)
      thread = Thread.new { server.run_till_terminated }
      Minitest.after_run do
        server.stop
        thread.join(5)
      end
      Struct.new(:service, :port).new(service, port)
    end
  end

  def service = self.class.evidence_server.service
  def port = self.class.evidence_server.port

  class EvidenceToolsServiceDouble < Agenticstream::Runtime::V1::EvidenceTools::Service
    attr_accessor :handler

    def call(request, _call)
      handler ? handler.call(request) : refuse("unhandled")
    end

    def refuse(code)
      Agenticstream::Runtime::V1::EvidenceToolResult.new(
        episode_id: "ep-1", call_id: "c", is_error: true, error_code: code
      )
    end
  end

  def digest(document)
    Tamoz::Core.digest(Client::RESULT_DIGEST_DOMAIN, document)
  end

  def result(document:, call_id: "call-1", episode_id: "ep-1", attempt_id: "at-1",
             fence: 1, sha256: :computed, artifact: nil, truncated: false,
             row_count: 1, result_bytes: 10)
    Agenticstream::Runtime::V1::EvidenceToolResult.new(
      episode_id:, call_id:, attempt_id:, fence:,
      result_json: Tamoz::Core.jcs(document).to_s.b,
      result_sha256: sha256 == :computed ? digest(document) : sha256,
      artifact:, truncated:, row_count:, result_bytes:
    )
  end

  def test_a_scoped_evidence_call_returns_the_verified_document
    service.handler = lambda do |request|
      assert_equal "1.0", request.protocol_version
      assert_equal "ep-1", request.episode_id
      assert_equal "at-1", request.attempt_id
      assert_equal 1, request.fence
      assert_equal "acme", request.tenant_id
      assert_equal "sit-1", request.situation_id
      assert_equal 7, request.situation_version
      assert_equal "c-01", request.entity_id
      assert_equal "opaque.hmac.token", request.capability_token
      assert_equal "evidence.get", request.tool_name
      assert_equal "c-01", JSON.parse(request.arguments_json).fetch("feature")
      result(document: {"feature" => "pressure", "value" => 0.9}, call_id: request.call_id)
    end

    client = build_client(endpoint: "127.0.0.1:#{port}")
    outcome = client.call(
      tool_name: "evidence.get", arguments: {"feature" => "c-01"},
      call_id: "call-1"
    )
    assert_equal 0.9, outcome.fetch("json").fetch("value")
    assert_equal 1, outcome.fetch("row_count")
  end

  def test_a_tampered_result_is_refused
    service.handler = lambda do |request|
      # Digest over document A, payload document B — a wire corruption.
      result(
        document: {"value" => 1}, call_id: request.call_id,
        sha256: digest({"value" => 2})
      )
    end

    client = build_client(endpoint: "127.0.0.1:#{port}")
    error = assert_raises(Client::EvidenceError) do
      client.call(tool_name: "evidence.get", arguments: {}, call_id: "call-1")
    end
    assert_includes error.message, "digest mismatch"
  end

  def test_a_misrouted_result_is_refused
    service.handler = lambda do |request|
      result(document: {"value" => 1}, call_id: request.call_id, episode_id: "ep-9")
    end

    client = build_client(endpoint: "127.0.0.1:#{port}")
    error = assert_raises(Client::EvidenceError) do
      client.call(tool_name: "evidence.get", arguments: {}, call_id: "call-1")
    end
    assert_includes error.message, "identity"
  end

  def test_a_result_without_a_digest_is_refused
    service.handler = lambda do |request|
      result(document: {"value" => 1}, call_id: request.call_id, sha256: "")
    end

    client = build_client(endpoint: "127.0.0.1:#{port}")
    error = assert_raises(Client::EvidenceError) do
      client.call(tool_name: "evidence.get", arguments: {}, call_id: "call-1")
    end
    assert_includes error.message, "no digest"
  end

  def test_a_server_refusal_surfaces_the_typed_scope_error
    service.handler = lambda do |request|
      Agenticstream::Runtime::V1::EvidenceToolResult.new(
        episode_id: request.episode_id, call_id: request.call_id,
        is_error: true, error_code: "tool_out_of_scope"
      )
    end

    client = build_client(endpoint: "127.0.0.1:#{port}")
    error = assert_raises(Client::EvidenceError) do
      client.call(tool_name: "forecast.run", arguments: {}, call_id: "call-1")
    end
    assert_includes error.message, "tool_out_of_scope"
  end

  def test_truncation_and_artifact_references_are_surfaced
    artifact = Agenticstream::Runtime::V1::ArtifactRef.new(
      id: "art-1", media_type: "application/json", size_bytes: 42,
      sha256: "ab" * 32
    )
    service.handler = lambda do |request|
      result(
        document: {"page" => 1}, call_id: request.call_id,
        artifact:, truncated: true, result_bytes: 4096
      )
    end

    client = build_client(endpoint: "127.0.0.1:#{port}")
    outcome = client.call(tool_name: "features.query", arguments: {}, call_id: "call-1")
    assert outcome.fetch("truncated")
    assert_equal "art-1", outcome.fetch("artifact").fetch("id")
    assert_equal 4096, outcome.fetch("result_bytes")
  end

  def test_the_client_refuses_to_build_without_an_endpoint_or_token
    assert_raises(Client::EvidenceError) do
      build_client(endpoint: "")
    end
    assert_raises(Client::EvidenceError) do
      build_client(capability_token: "")
    end
  end

  # T3.2: the containment host binds the evidence adapter — the episode can
  # fetch evidence, the result stays bounded, and a call that is NOT part of
  # the allowlist never resolves.
  def test_the_host_binds_the_evidence_adapter_read_only
    service.handler = lambda do |request|
      result(document: {"value" => 0.9}, call_id: request.call_id)
    end
    client = build_client(endpoint: "127.0.0.1:#{port}")
    host = Host.new(Host::PERMITTED.to_h do |name|
      [name, Tamoz::Stream::EvidenceToolAdapter.new(client, tool_name: name)]
    end)

    outcome = host.execute("evidence.get", {"feature" => "c-01"})
    assert_equal 0.9, outcome.fetch("json").fetch("value")

    error = assert_raises(Tamoz::Core::ToolError) do
      host.execute("write_file", {})
    end
    assert_kind_of Tamoz::Core::ToolError, error
  end

  # T3.2 fail-closed: an episode WITHOUT an evidence channel binds refusal
  # adapters — the surface exists, evidence refuses, and no dial happens.
  def test_the_host_binds_refusal_adapters_without_a_channel
    host = Host.new(Host::PERMITTED.to_h do |name|
      [name, Tamoz::Stream::EvidenceUnavailableAdapter.new(tool_name: name)]
    end)

    error = assert_raises(Client::EvidenceError) do
      host.execute("evidence.get", {})
    end
    assert_includes error.message, "not configured"
  end

  # T3.2 end to end: a full episode whose graph node fetches evidence through
  # context.episode_tools mid-reasoning. The runner binds the evidence client
  # from the wire request; the node reads the verified result into the
  # Decision.
  def test_an_episode_fetches_evidence_mid_reasoning_and_produces
    service.handler = lambda do |request|
      assert_equal "evidence.get", request.tool_name
      assert_equal "ep-evidence", request.episode_id
      result(document: {"value" => 0.9}, call_id: request.call_id,
             episode_id: request.episode_id, attempt_id: request.attempt_id,
             fence: request.fence)
    end

    directory = Dir.mktmpdir("tamoz-evidence-e2e")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    graph = Tamoz.graph(name: "episode-evidence", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      state :summary, default: nil
      state :facts_used, default: []
      node(
        :analyze,
        implementation_name: "episode.analyze",
        version: "1"
      ) do |state, context|
        evidence = context.episode_tools.execute(
          "evidence.get", {"feature" => "pressure"}
        )
        context.emit(
          :model_started, {ordinal: 0, provider: "test", model_id: "flash"}
        )
        context.emit(
          :model_completed,
          {ordinal: 0, usage: {input_tokens: 3, output_tokens: 1}}
        )
        {
          primary_hypothesis: "bearing wear",
          confidence: 0.9,
          summary: "evidence: #{evidence.fetch("json").fetch("value")}",
          facts_used: [{"value" => evidence.fetch("json").fetch("value")}]
        }
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end
    app = graph.compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil
    )

    snapshot = {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.2}
    }
    wire = Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-evidence", attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      kind: :EPISODE_KIND_DIAGNOSE, lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      allowed_intent_types: ["maintenance.ticket"],
      capability_token: "opaque.hmac.token",
      evidence_tools_endpoint: "127.0.0.1:#{port}",
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot)
    )

    events = runner.run(wire).each.to_a
    terminal = events.last.terminal
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status,
                 "the evidence-fetching episode must produce"
    decision_event = events.find { |event| event.decision != nil }
    refute_nil decision_event, "a produced episode must propose a decision"
    decision = JSON.parse(decision_event.decision.decision_json)
    assert_includes decision.fetch("summary"), "evidence: 0.9",
                    "the graph node must have read the verified evidence"
    adapter.close
  ensure
    FileUtils.remove_entry(directory) if directory
  end
end
