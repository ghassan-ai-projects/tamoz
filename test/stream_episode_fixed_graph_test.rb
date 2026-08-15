# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "tamoz/stream/decision_node_builder"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

# P1 gates 1-5, 7 via the fixed graph under the in-process driver (gate 4:
# no gRPC — the adapters are the only difference from the wire path). The
# fixture endpoint is labeled `fixture` and proves plumbing/output-dependence
# only; the real-model run lives in stream_episode_real_model_test.rb.
class StreamEpisodeFixedGraphTest < Minitest::Test
  Stream = Tamoz::Stream

  def composition(endpoint:, model: "local-model")
    directory = Dir.mktmpdir("tamoz-episode-graph")
    root = File.join(directory, "root")
    Dir.mkdir(root)
    profile = Tamoz::Agent::Profile.preview_source(
      write_profile(AquacultureDomain.profile_document(endpoint:, root:, model:))
    ).document
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
          provider: role.fetch("provider")
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
    runner = Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner,
      worker:,
      artifact_store: Stream::ArtifactStore.new
    )
    {runner:, app:, directory:, profile:}
  end

  def write_profile(document)
    path = File.join(Dir.tmpdir, "tamoz-worker-p1-#{SecureRandom.hex(4)}.yml")
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
    path
  end

  def wire_request(suffix, snapshot:, catalog_json:, prompt:, prompt_sha256:, model_policy: "fast",
                   allowlist: %w[install_watch_condition start_aerator])
    snapshot_json = Tamoz::Core.jcs(snapshot)
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "p1-graph-#{suffix}",
      attempt_id: "at-#{suffix}",
      fence: 1,
      tenant_id: snapshot.fetch("tenant_id"),
      situation_id: snapshot.fetch("situation_id"),
      situation_version: snapshot.fetch("situation_version"),
      snapshot_json: snapshot_json,
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot),
      diagnosis_catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
      diagnosis_catalog_sha256: Tamoz::Core.digest(:diagnosis_catalog, AquacultureDomain::CATALOG),
      intent_catalog_json: Tamoz::Core.jcs(AquacultureDomain::INTENT_CATALOG),
      intent_catalog_sha256: AquacultureDomain.intent_catalog_digest,
      model_policy: model_policy,
      prompt: prompt,
      prompt_version: "1.0",
      prompt_sha256: prompt_sha256,
      objective: AquacultureDomain::OBJECTIVE,
      objective_sha256: Tamoz::Core.digest("situation-runtime/objective/v1\n",
                                           {"text" => AquacultureDomain::OBJECTIVE}),
      kind: :EPISODE_KIND_DIAGNOSE,
      lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R1,
      allowed_intent_types: allowlist,
      executor_name: "tamoz",
      dispatch_policy: :DISPATCH_POLICY_SHADOW
    )
  end

  def prompt_sha256(prompt)
    EpisodeComposition.prompt_sha256(prompt)
  end

  def with_fixture_endpoint(responses: AquacultureDomain::FIXTURE_RESPONSES)
    Dir.mktmpdir("tamoz-endpoint") do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture, responses:, log_path: File.join(dir, "endpoint.log")
      ).start
      yield endpoint
    ensure
      endpoint&.stop
    end
  end

  def test_gate3_perturbed_response_changes_selected_code
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      _result, state = run_episode(composition, suffix: "perturb", endpoint:)
      codes = state.fetch(:model_receipts) # receipts present (trusted emission path)
      assert_equal 1, codes.length
      document = state.fetch(:document)
      assert_equal "low_dissolved_oxygen", document.fetch("selected_code")
    end

    # Second run, same frame, different fixture response → different code.
    with_fixture_endpoint(responses: [AquacultureDomain::FIXTURE_RESPONSES[1]]) do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      _result, state = run_episode(composition, suffix: "perturb2", endpoint:)
      assert_equal "equipment_failure", state.fetch(:document).fetch("selected_code")
    end
  end

  def test_gate2_endpoint_digests_equal_receipt_digests
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      result, state = run_episode(composition, suffix: "digest", endpoint:)
      observed = endpoint.observed.last
      receipt = state.fetch(:model_receipts).last
      assert_equal receipt.fetch("request_digest"), observed.fetch("request_digest")
      assert_equal receipt.fetch("response_digest"), observed.fetch("response_digest")
      # The decision was produced and translated by the runner.
      assert_equal :completed, result.status
      assert_kind_of Hash, state.fetch(:decision)
    end
  end

  def test_gate4_same_graph_runs_without_grpc
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      result, state = run_episode(composition, suffix: "driver", endpoint:)
      assert_equal :completed, result.status
      assert_equal "low_dissolved_oxygen", state.fetch(:document).fetch("selected_code")
      # The r1 allowlisted action is proposed from the allowlist + risk table.
      assert_equal "start_aerator", state.fetch(:decision).fetch("intents").first.fetch("type")
    end
  end

  def test_gate5_node_emitted_model_event_is_rejected
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      stream = Stream::EpisodeStream.new(
        Struct.new(:episode_id, :attempt_id, :fence).new("ep-x", "at-x", 1)
      )
      adapter = Stream::EpisodeStreamAdapter.new(stream)
      error = assert_raises(Stream::StreamError) do
        adapter.emit(:model_started, [], {ordinal: 0, provider: "test", model_id: "flash"})
      end
      assert_match(/forbidden model event/, error.message)
    end
  end

  def test_gate7_fail_closed_before_any_model_call
    # Unknown role: typed failure, zero endpoint hits.
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      snapshot = AquacultureDomain.snapshot
      request = wire_request("role", snapshot:, catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
                                      prompt: AquacultureDomain::PROMPT,
                                      prompt_sha256: prompt_sha256(AquacultureDomain::PROMPT),
                                      model_policy: "does-not-exist")
      events = collect_events(composition, request)
      assert_equal 0, endpoint.observed.length
      assert_equal :TERMINAL_STATUS_FAILED, terminal_of(events)
    end

    # Missing catalog digest: typed failure before any call.
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      snapshot = AquacultureDomain.snapshot
      request = wire_request("catalog", snapshot:, catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
                                        prompt: AquacultureDomain::PROMPT,
                                        prompt_sha256: prompt_sha256(AquacultureDomain::PROMPT))
      request.diagnosis_catalog_sha256 = "sha256:#{"0" * 64}"
      events = collect_events(composition, request)
      assert_equal 0, endpoint.observed.length
      assert_equal :TERMINAL_STATUS_FAILED, terminal_of(events)
    end

    # Prompt digest mismatch: typed failure before any call.
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      snapshot = AquacultureDomain.snapshot
      request = wire_request("prompt", snapshot:, catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
                                        prompt: AquacultureDomain::PROMPT,
                                        prompt_sha256: "sha256:#{"f" * 64}")
      events = collect_events(composition, request)
      assert_equal 0, endpoint.observed.length
      assert_equal :TERMINAL_STATUS_FAILED, terminal_of(events)
    end
  end

  def test_reconsider_episode_fails_closed
    with_fixture_endpoint do |endpoint|
      composition = composition(endpoint: endpoint.base_url)
      snapshot = AquacultureDomain.snapshot
      request = wire_request("recon", snapshot:, catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
                                       prompt: AquacultureDomain::PROMPT,
                                       prompt_sha256: prompt_sha256(AquacultureDomain::PROMPT))
      request.kind = :EPISODE_KIND_RECONSIDER
      events = collect_events(composition, request)
      assert_equal 0, endpoint.observed.length
      assert_equal :TERMINAL_STATUS_FAILED, terminal_of(events)
    end
  end

  private

  def run_episode(composition, suffix:, endpoint:)
    snapshot = AquacultureDomain.snapshot
    request = wire_request(suffix, snapshot:, catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
                                     prompt: AquacultureDomain::PROMPT,
                                     prompt_sha256: prompt_sha256(AquacultureDomain::PROMPT))
    events = collect_events(composition, request)
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal_of(events)
    result = composition.fetch(:app).durable_runner.fetch(
      thread: "episode.#{request.episode_id}",
      request_id: "episode.#{request.episode_id}.#{request.attempt_id}.#{request.fence}",
      namespace: [request.tenant_id]
    )
    state = composition.fetch(:app).state(
      thread: "episode.#{request.episode_id}",
      namespace: [request.tenant_id],
      checkpoint_id: result.checkpoint_id
    ).state.to_h
    [result, state]
  end

  def collect_events(composition, request)
    events = []
    composition.fetch(:runner).run(request).each { |event| events << event }
    events
  end

  def terminal_of(events)
    events.map(&:terminal).compact.last&.status
  end
end
