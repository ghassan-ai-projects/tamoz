# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "tamoz/stream/decision_node_builder"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/episode_composition"

# P1 gate 6: the crash matrix through the fixed graph — a restart re-claims and
# re-executes the episode, and the journal's LOGICAL key makes a completed
# receipt reusable (no second provider call) while a started-without-receipt
# attempt is a typed `unknown` (no blind retry). The crash itself is simulated
# by seeding the journal's attempt state, exactly as a mid-call process death
# would leave it.
class StreamEpisodeCrashMatrixTest < Minitest::Test
  Stream = Tamoz::Stream

  def setup
    @dir = Dir.mktmpdir("tamoz-crash")
    @endpoint_dir = Dir.mktmpdir("tamoz-crash-endpoint")
    @endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: AquacultureDomain::FIXTURE_RESPONSES,
      log_path: File.join(@endpoint_dir, "endpoint.log")
    ).start
    @endpoint_base = @endpoint.base_url
  end

  def teardown
    @endpoint&.stop
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@endpoint_dir)
  end

  def test_fence_plus_one_redispatched_episode_reuses_the_completed_receipt
    composition = build_composition
    snapshot = AquacultureDomain.snapshot

    r1 = deliver(composition, snapshot, attempt: 1, fence: 1)
    assert_equal :completed, r1.status
    assert_equal 1, @endpoint.observed.length

    r2 = deliver(composition, snapshot, attempt: 1, fence: 2)
    assert_equal :completed, r2.status
    # No second provider call: the journal returned the completed receipt.
    assert_equal 1, @endpoint.observed.length

    state1 = terminal_state(composition, snapshot, attempt: 1, fence: 1)
    state2 = terminal_state(composition, snapshot, attempt: 1, fence: 2)
    assert_equal state1.fetch(:raw_response), state2.fetch(:raw_response)
    assert_equal state1.fetch(:document), state2.fetch(:document)
    # The decision body is deterministic; only attempt-scoped ids differ.
    core_intents = ->(state) do
      state.fetch(:decision).fetch("intents").map do |intent|
        intent.reject { |key, _| key == "expires_at" || key.end_with?("_id", "_digest") }
      end
    end
    assert_equal core_intents.call(state1), core_intents.call(state2)
  end

  def test_started_without_receipt_is_typed_unknown_no_blind_retry
    composition = build_composition
    snapshot = AquacultureDomain.snapshot

    # A valid run creates the thread + checkpoint (one provider call).
    r1 = deliver(composition, snapshot, attempt: 1, fence: 1)
    assert_equal :completed, r1.status
    assert_equal 1, @endpoint.observed.length

    # Seed a started-but-uncompleted attempt under a DIFFERENT logical key
    # (different prompt → different request digest): the durable residue of a
    # mid-call crash that never produced a receipt.
    seed_started_attempt(composition, snapshot, prompt: "A DIFFERENT prompt")
    assert_equal 1, @endpoint.observed.length

    events = []
    request = build_request(snapshot, attempt: 1, fence: 2, prompt: "A DIFFERENT prompt")
    composition.fetch(:runner).run(request).each { |event| events << event }
    terminal = events.map(&:terminal).compact.last
    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
    # The unknown effect was never retried with a fresh call.
    assert_equal 1, @endpoint.observed.length
  end

  private

  def build_composition
    root = File.join(@dir, "root")
    Dir.mkdir(root)
    profile = Tamoz::Agent::Profile.preview_source(
      write_profile(AquacultureDomain.profile_document(endpoint: @endpoint_base, root:, model: "local-model"))
    ).document
    checkpointer = Tamoz::SQLite::Adapter.new(
      path: File.join(@dir, "tamoz.db"),
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
    runner = Stream::EpisodeRunner.new(durable_runner: app.durable_runner, worker:)
    {app:, runner:, checkpointer:}
  end

  def write_profile(document)
    path = File.join(@dir, "profile.yml")
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
    path
  end

  def build_request(snapshot, attempt:, fence:, prompt: AquacultureDomain::PROMPT)
    Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "crash-ep",
      attempt_id: "at-#{attempt}",
      fence: fence,
      tenant_id: snapshot.fetch("tenant_id"),
      situation_id: snapshot.fetch("situation_id"),
      situation_version: snapshot.fetch("situation_version"),
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot),
      diagnosis_catalog_json: Tamoz::Core.jcs(AquacultureDomain::CATALOG),
      diagnosis_catalog_sha256: Tamoz::Core.digest(:diagnosis_catalog, AquacultureDomain::CATALOG),
      model_policy: "fast",
      prompt: prompt,
      prompt_version: "1.0",
      prompt_sha256: EpisodeComposition.prompt_sha256(prompt),
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
  end

  def deliver(composition, snapshot, attempt:, fence:)
    request = build_request(snapshot, attempt:, fence:)
    events = []
    composition.fetch(:runner).run(request).each { |event| events << event }
    terminal = events.map(&:terminal).compact.last
    refute_nil terminal
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    composition.fetch(:app).durable_runner.fetch(
      thread: "episode.#{request.episode_id}",
      request_id: "episode.#{request.episode_id}.#{request.attempt_id}.#{request.fence}",
      namespace: [request.tenant_id]
    )
  end

  def terminal_state(composition, snapshot, attempt:, fence:)
    request = build_request(snapshot, attempt:, fence:)
    result = composition.fetch(:app).durable_runner.fetch(
      thread: "episode.#{request.episode_id}",
      request_id: "episode.#{request.episode_id}.#{request.attempt_id}.#{request.fence}",
      namespace: [request.tenant_id]
    )
    composition.fetch(:app).state(
      thread: "episode.#{request.episode_id}",
      namespace: [request.tenant_id],
      checkpoint_id: result.checkpoint_id
    ).state.to_h
  end

  # Recomputes the exact logical call key the reason node will use for the
  # given prompt, then prepares and STARTS the journal attempt
  # (dispatch_started) without completing it — the durable residue of a
  # mid-call crash.
  def seed_started_attempt(composition, snapshot, prompt:)
    logical = logical_key_for(composition, snapshot, prompt:)
    store = composition.fetch(:app).checkpointer

    store.open_writer(
      thread_id: "episode.crash-ep", namespace: ["acme"],
      owner_id: "crash-seeder", ttl: store.writer_ttl
    ) do |writer|
      checkpoint = writer.latest
      decision = writer.effects.prepare(
        execution_id: checkpoint.execution_id,
        task_id: "reason",
        call_index: 0,
        operation: "episode.model.reason",
        safety: :unsafe,
        request: {"stage" => "reason", "logical_call_key" => logical.to_key},
        logical_key: logical.to_key
      )
      writer.effects.start(key: decision.record.key, attempt_token: decision.attempt_token)
    end
  end

  def logical_key_for(composition, snapshot, prompt:)
    catalog = Tamoz::Agent::DiagnosisCatalog.from_list(AquacultureDomain::CATALOG)
    # The wire canonicalizes the snapshot (JCS → sorted keys); the node's
    # frame is built from the parsed canonical bytes, so the precomputation
    # must mirror that exactly to hit the same logical key.
    canonical_snapshot = Tamoz::Core.parse_json_strict(Tamoz::Core.jcs(snapshot))
    frame = Tamoz::Agent::EpisodeFrameBuilder.new(
      catalog:, objective: AquacultureDomain::OBJECTIVE
    ).build(snapshot: canonical_snapshot, prompt:)
    transport = Tamoz::Agent::EpisodeModelTransport.new(
      endpoint: @endpoint_base, model: "local-model", provider: "ollama"
    )
    request_bytes = transport.build_request(system: frame.system, prompt: frame.user)
    Tamoz::Agent::ModelCall::LogicalCallKey.new(
      episode_id: "crash-ep", stage: "reason", slot: 0,
      request_digest: transport.request_digest(request_bytes)
    )
  end
end
