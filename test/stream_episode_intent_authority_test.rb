# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/climate_domain"
require "support/episode_composition"

# P4 (PHASE_P4_INTENT_AUTHORITY) exit gates 1, 4 + the risk-equality property:
# the intent catalog is required and digest-bound before any model call; a
# novel domain authored as DATA produces a decision whose intent risk EQUALS
# the catalog's declared risk. Fixture-labeled throughout.
class StreamEpisodeIntentAuthorityTest < Minitest::Test
  Stream = Tamoz::Stream

  def setup
    @dir = Dir.mktmpdir("tamoz-intent")
    @endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: AquacultureDomain::FIXTURE_RESPONSES,
      log_path: File.join(@dir, "endpoint.log")
    ).start
    @composition = EpisodeComposition.build(endpoint: @endpoint.base_url)
  end

  def teardown
    @endpoint&.stop
    @composition&.fetch(:adapter)&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  def run_request(request)
    events = []
    @composition.fetch(:runner).run(request).each { |event| events << event }
    events
  end

  def aquaculture_request(episode_id)
    EpisodeComposition.wire_request(episode_id:)
  end

  def test_gate1_a_missing_intent_catalog_fails_closed_before_any_model_call
    request = aquaculture_request("p4-missing-catalog")
    request.intent_catalog_json = ""
    request.intent_catalog_sha256 = ""

    events = run_request(request)
    terminal = events.map(&:terminal).compact.last
    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
    assert_equal 0, @endpoint.observed.length, "no model call may happen without the catalog"
    diagnostic = events.map(&:diagnostic).compact.last
    assert_match(/intent catalog/, diagnostic.message)
  end

  def test_gate1_a_forged_intent_catalog_digest_fails_closed_before_any_model_call
    request = aquaculture_request("p4-forged-catalog")
    request.intent_catalog_sha256 = "sha256:#{"0" * 64}"

    events = run_request(request)
    terminal = events.map(&:terminal).compact.last
    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
    assert_equal 0, @endpoint.observed.length,
                 "a forged catalog may not reach a model call"
  end

  def test_gate1_a_duplicate_intent_type_fails_closed
    duplicate = AquacultureDomain::INTENT_CATALOG + [AquacultureDomain::INTENT_CATALOG.first]
    request = aquaculture_request("p4-dup-catalog")
    request.intent_catalog_json = Tamoz::Core.jcs(duplicate)
    request.intent_catalog_sha256 = Tamoz::Core.digest(:intent_catalog, duplicate)

    events = run_request(request)
    terminal = events.map(&:terminal).compact.last
    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
    assert_equal 0, @endpoint.observed.length
  end

  def test_the_decision_carries_the_catalog_declared_risk
    _events, terminal, state = produced_run("p4-risk")
    intent = state.fetch(:decision).fetch("intents").fetch(0)
    catalog = Tamoz::Agent::IntentCatalog.from_list(AquacultureDomain::INTENT_CATALOG)
    assert_equal "start_aerator", intent.fetch("type")
    assert_equal catalog.risk_for("start_aerator"), intent.fetch("risk_class"),
                 "the intent risk equals the catalog's declared risk (B10)"
  end

  def test_gate4_a_novel_domain_produces_a_decision_with_zero_new_ruby
    # The climate domain is DATA (test/support/climate_domain.rb) — the fixed
    # graph and the builder are untouched. The produced intent's risk comes
    # from the CLIMATE catalog.
    endpoint = LocalModelEndpoint.new(
      mode: :fixture,
      responses: ClimateDomain::FIXTURE_RESPONSES,
      log_path: File.join(@dir, "climate.log")
    ).start
    begin
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      snapshot = ClimateDomain.snapshot
      request = Agenticstream::Runtime::V1::EpisodeRequest.new(
        protocol_version: "1.0",
        episode_id: "p4-climate",
        attempt_id: "at-1",
        fence: 1,
        tenant_id: snapshot.fetch("tenant_id"),
        situation_id: snapshot.fetch("situation_id"),
        situation_version: snapshot.fetch("situation_version"),
        snapshot_json: Tamoz::Core.jcs(snapshot),
        snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot),
        diagnosis_catalog_json: Tamoz::Core.jcs(ClimateDomain::CATALOG),
        diagnosis_catalog_sha256: Tamoz::Core.digest(:diagnosis_catalog, ClimateDomain::CATALOG),
        intent_catalog_json: Tamoz::Core.jcs(ClimateDomain::INTENT_CATALOG),
        intent_catalog_sha256: ClimateDomain.intent_catalog_digest,
        model_policy: "fast",
        prompt: ClimateDomain::PROMPT,
        prompt_version: "1.0",
        prompt_sha256: EpisodeComposition.prompt_sha256(ClimateDomain::PROMPT),
        objective: ClimateDomain::OBJECTIVE,
        objective_sha256: Tamoz::Core.digest(
          "situation-runtime/objective/v1\n", {"text" => ClimateDomain::OBJECTIVE}
        ),
        kind: :EPISODE_KIND_DIAGNOSE,
        lane: :EPISODE_LANE_FAST,
        risk_ceiling: :RISK_CLASS_R1,
        allowed_intent_types: %w[install_watch_condition run_vent_cycle],
        executor_name: "tamoz",
        dispatch_policy: :DISPATCH_POLICY_SHADOW
      )
      events = []
      composition.fetch(:runner).run(request).each { |event| events << event }
      terminal = events.map(&:terminal).compact.last
      assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
      result = composition.fetch(:app).durable_runner.fetch(
        thread: "episode.p4-climate",
        request_id: "episode.p4-climate.at-1.1",
        namespace: ["acme"]
      )
      state = composition.fetch(:app).state(
        thread: "episode.p4-climate",
        namespace: ["acme"],
        checkpoint_id: result.checkpoint_id
      ).state.to_h
      intent = state.fetch(:decision).fetch("intents").fetch(0)
      assert_equal "run_vent_cycle", intent.fetch("type")
      climate_catalog = Tamoz::Agent::IntentCatalog.from_list(ClimateDomain::INTENT_CATALOG)
      assert_equal climate_catalog.risk_for("run_vent_cycle"), intent.fetch("risk_class"),
                   "the novel domain's risk comes from ITS catalog"
      assert_equal "R1", intent.fetch("risk_class")
      assert_equal "zone-03", intent.fetch("parameters").fetch("entity_id")
    ensure
      composition.fetch(:adapter).close
      endpoint.stop
    end
  end

  def produced_run(suffix)
    events = run_request(aquaculture_request("p4-#{suffix}"))
    terminal = events.map(&:terminal).compact.last
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    result = @composition.fetch(:app).durable_runner.fetch(
      thread: "episode.p4-#{suffix}",
      request_id: "episode.p4-#{suffix}.at-1.1",
      namespace: ["acme"]
    )
    state = @composition.fetch(:app).state(
      thread: "episode.p4-#{suffix}",
      namespace: ["acme"],
      checkpoint_id: result.checkpoint_id
    ).state.to_h
    [events, terminal, state]
  end
end
