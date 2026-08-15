# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "tamoz/stream/decision_node_builder"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

# P1 gates 1-2, REAL run: one aquaculture episode end to end through the fixed
# graph with a real pinned local model (ollama, proxy-mode endpoint that logs
# the raw request/response digests OUTSIDE the worker). The endpoint is a
# separately-controlled witness; the receipt's digests must equal the
# endpoint-observed digests byte for byte.
#
# This is the "A real LLM adapter path exists" claim (level 2 of 6) — a
# plumbing claim about the adapter, not an intelligence claim. It runs only
# when RUN_REAL_E2E=1 (manual evidence run) and the local model is reachable.
class StreamEpisodeRealModelTest < Minitest::Test
  Stream = Tamoz::Stream

  OLLAMA_BASE = "http://127.0.0.1:11434"
  DEFAULT_MODEL = "gemma4:latest"

  def test_one_real_call_through_the_fixed_graph
    skip "set RUN_REAL_E2E=1 for the real model run" unless ENV["RUN_REAL_E2E"] == "1"
    skip "ollama is not reachable at #{OLLAMA_BASE}" unless ollama_up?

    endpoint = LocalModelEndpoint.new(
      mode: :proxy, upstream: OLLAMA_BASE,
      log_path: File.join(Dir.mktmpdir("tamoz-real"), "endpoint.log")
    ).start

    directory = Dir.mktmpdir("tamoz-real-worker")
    root = File.join(directory, "root")
    Dir.mkdir(root)
    profile_path = File.join(directory, "profile.yml")
    File.write(
      profile_path,
      Psych.dump(AquacultureDomain.profile_document(endpoint: endpoint.base_url, root:, model: DEFAULT_MODEL))
    )
    File.chmod(0o600, profile_path)
    profile = Tamoz::Agent::Profile.preview_source(profile_path).document
    checkpointer = Tamoz::SQLite::Adapter.new(
      path: File.join(directory, "tamoz.db"),
      state_codec: Tamoz::Agent::Memory::Surface.codec
    )
    nodes = Tamoz::Agent::EpisodeNodes.new(
      profile:,
      frame_builder_factory: lambda do |catalog, objective|
        Tamoz::Agent::EpisodeFrameBuilder.new(catalog:, objective:)
      end,
      model_call_factory: lambda do |role|
        transport = Tamoz::Agent::EpisodeModelTransport.new(
          endpoint: role.fetch("endpoint"), model: role.fetch("model"),
          provider: role.fetch("provider"), timeout_seconds: 300
        )
        Tamoz::Agent::EpisodeModelCall.new(transport:)
      end,
      decision_builder: Stream::DecisionNodeBuilder.new
    )
    app = Tamoz::Agent::EpisodeGraph.build(checkpointer:, nodes:)
    worker = Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build("fast" => "flash", "deep" => "pro", "batch" => "flash")
    )
    runner = Stream::EpisodeRunner.new(durable_runner: app.durable_runner, worker:)

    snapshot = AquacultureDomain.snapshot(pond_id: "pond-07", dissolved_oxygen: 0.9)
    request = Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "p1-real-#{Process.pid}",
      attempt_id: "at-1",
      fence: 1,
      tenant_id: snapshot.fetch("tenant_id"),
      situation_id: snapshot.fetch("situation_id"),
      situation_version: snapshot.fetch("situation_version"),
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot),
      diagnosis_catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
      diagnosis_catalog_sha256: Tamoz::Core.digest(:diagnosis_catalog, AquacultureDomain::CATALOG),
      intent_catalog_json: Tamoz::Core.jcs(AquacultureDomain::INTENT_CATALOG),
      intent_catalog_sha256: AquacultureDomain.intent_catalog_digest,
      model_policy: "fast",
      prompt: AquacultureDomain::PROMPT,
      prompt_sha256: EpisodeComposition.prompt_sha256(AquacultureDomain::PROMPT),
      prompt_version: EpisodeComposition::PROMPT_VERSION,
      objective: AquacultureDomain::OBJECTIVE,
      objective_sha256: Tamoz::Core.digest("situation-runtime/objective/v1\n",
                                           {"text" => AquacultureDomain::OBJECTIVE}),
      kind: :EPISODE_KIND_DIAGNOSE,
      lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R1,
      allowed_intent_types: %w[install_watch_condition start_aerator],
      executor_name: "tamoz",
      dispatch_policy: :DISPATCH_POLICY_SHADOW
    )

    events = []
    runner.run(request).each { |event| events << event }
    terminal = events.map(&:terminal).compact.last
    refute_nil terminal, "the real run must produce a terminal"

    observed = endpoint.observed
    assert_equal 1, observed.length, "exactly one provider call in the real run"
    digest = observed.last.fetch("request_digest")

    result = app.durable_runner.fetch(
      thread: "episode.#{request.episode_id}",
      request_id: "episode.#{request.episode_id}.#{request.attempt_id}.#{request.fence}",
      namespace: [request.tenant_id]
    )
    state = app.state(
      thread: "episode.#{request.episode_id}",
      namespace: [request.tenant_id],
      checkpoint_id: result.checkpoint_id
    ).state.to_h
    receipt = state.fetch(:model_receipts).last

    # Gate 2: the endpoint (outside the worker) observed the same request
    # digest as the receipt, byte for byte.
    assert_equal digest, receipt.fetch("request_digest")
    assert_equal observed.last.fetch("response_digest"), receipt.fetch("response_digest")

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status,
                 "real run did not produce: #{terminal.inspect}"
    assert_kind_of Hash, state.fetch(:decision)
    assert_includes(
      state.fetch(:document).fetch("probabilities").map { |p| p.fetch("code") },
      state.fetch(:document).fetch("selected_code")
    )

    warn "REAL RUN OK: provider=ollama model=#{DEFAULT_MODEL} " \
         "request_digest=#{receipt.fetch("request_digest")} " \
         "selected=#{state.fetch(:document).fetch("selected_code")} " \
         "decision=intents=#{state.fetch(:decision).fetch("intents").length} " \
         "fence=#{request.fence} telemetry=buffered claim=level2/6"
  ensure
    endpoint&.stop
  end

  private

  def ollama_up?
    uri = URI.parse("#{OLLAMA_BASE}/v1/models")
    response = Net::HTTP.get_response(uri)
    response.is_a?(Net::HTTPSuccess)
  rescue StandardError
    false
  end
end
