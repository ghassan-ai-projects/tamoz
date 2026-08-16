# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/agent"
require "tamoz/sqlite"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/aquaculture_domain"
require "support/climate_domain"
require "support/episode_composition"

# P6 (PHASE_P6_RECONSIDER): RECONSIDER is a graph route — intake → judge →
# compensate — with the compensation mapping from the INTENT CATALOG (never
# regex or hard-coded tables). No model call, ever. Fixture-labeled.
class StreamEpisodeReconsiderTest < Minitest::Test
  Stream = Tamoz::Stream

  def setup
    @dir = Dir.mktmpdir("tamoz-p6")
    @endpoint = LocalModelEndpoint.new(
      mode: :fixture, responses: AquacultureDomain::FIXTURE_RESPONSES,
      log_path: File.join(@dir, "reconsider.log")
    ).start
    @composition = EpisodeComposition.build(endpoint: @endpoint.base_url)
  end

  def teardown
    @endpoint&.stop
    @composition&.fetch(:adapter)&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  def prior_decision
    {"decision_id" => "decision.p6-reconsider.at-1.1",
     "episode_id" => "p6-reconsider", "attempt_id" => "at-1", "fence" => 1,
     "snapshot_digest" => "sha256:#{"0" * 64}",
     "situation_id" => "sit-1", "situation_version" => 7,
     "confidence" => 0.9, "summary" => "prior",
     "intents" => []}
  end

  def reconsideration(commands:, correction:)
    Agenticstream::Runtime::V1::Reconsideration.new(
      prior_decision_json: Tamoz::Core.jcs(prior_decision),
      executed_command_json: commands.map { |command| Tamoz::Core.jcs(command) },
      correction_json: Tamoz::Core.jcs(correction)
    )
  end

  def command(command_id:, intent_type:, status:)
    {"command_id" => command_id, "intent_type" => intent_type, "status" => status,
     "intent_digest" => "sha256:#{"a" * 64}"}
  end

  def test_a_novel_domains_reconsider_resolves_from_its_own_catalog
    # Gate 6: the climate catalog's compensation mapping drives the
    # compensation — zero new Ruby.
    prior = {"decision_id" => "d", "episode_id" => "p", "attempt_id" => "a", "fence" => 1,
             "snapshot_digest" => "sha256:#{"0" * 64}", "confidence" => 0.9, "intents" => []}
    command = {"command_id" => "c1", "intent_type" => "open_roof_louvers", "status" => "dispatched",
               "intent_digest" => "sha256:#{"a" * 64}"}
    wire = Agenticstream::Runtime::V1::Reconsideration.new(
      prior_decision_json: Tamoz::Core.jcs(prior),
      executed_command_json: [Tamoz::Core.jcs(command)],
      correction_json: Tamoz::Core.jcs({"invalidates" => ["c1"]})
    )
    snapshot = ClimateDomain.snapshot
    request = Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0", episode_id: "p6-climate-recon", attempt_id: "at-1", fence: 1,
      tenant_id: snapshot.fetch("tenant_id"), situation_id: snapshot.fetch("situation_id"),
      situation_version: snapshot.fetch("situation_version"),
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot),
      intent_catalog_json: Tamoz::Core.jcs(ClimateDomain::INTENT_CATALOG),
      intent_catalog_sha256: ClimateDomain.intent_catalog_digest,
      reconsideration: wire,
      kind: :EPISODE_KIND_RECONSIDER, lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R4, allowed_intent_types: [],
      executor_name: "tamoz", dispatch_policy: :DISPATCH_POLICY_SHADOW
    )
    events = []
    @composition.fetch(:runner).run(request).each { |event| events << event }
    terminal = events.map(&:terminal).compact.last
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    result = @composition.fetch(:app).durable_runner.fetch(
      thread: "episode.p6-climate-recon",
      request_id: "episode.p6-climate-recon.at-1.1",
      namespace: ["acme"]
    )
    decision = @composition.fetch(:app).state(
      thread: "episode.p6-climate-recon", namespace: ["acme"],
      checkpoint_id: result.checkpoint_id
    ).state.to_h.fetch(:decision)
    intent = decision.fetch("intents").first
    assert_equal "downgrade_climate_action", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
    assert_equal "c1", intent.fetch("compensates")
    # The action open_roof_louvers exists ONLY in the climate catalog — the
    # compensation resolved from the CLIMATE catalog, not a copy.
    refute AquacultureDomain::INTENT_TYPES.key?("open_roof_louvers")
  end

  def strip_wall_clock(decision)
    decision.reject { |key, _| %w[valid_until decision_id fence].include?(key) }.tap do |stripped|
      stripped["intents"] = Array(decision["intents"]).map do |intent|
        intent.reject { |key, _| %w[expires_at intent_id intent_digest decision_id].include?(key) }
      end
    end
  end

  def run_reconsider(episode_id: "p6-reconsider", risk_ceiling: :RISK_CLASS_R2, **kwargs)
    request = EpisodeComposition.wire_request(
      episode_id:, kind: :EPISODE_KIND_RECONSIDER, risk_ceiling:,
      allowed_intent_types: [], reconsideration: reconsideration(**kwargs)
    )
    events = []
    @composition.fetch(:runner).run(request).each { |event| events << event }
    terminal = events.map(&:terminal).compact.last
    result = if terminal&.status == :TERMINAL_STATUS_PRODUCED
               @composition.fetch(:app).durable_runner.fetch(
                 thread: "episode.#{episode_id}",
                 request_id: "episode.#{episode_id}.at-1.1",
                 namespace: ["acme"]
               )
             end
    state = if result
              @composition.fetch(:app).state(
                thread: "episode.#{episode_id}", namespace: ["acme"],
                checkpoint_id: result.checkpoint_id
              ).state.to_h
            end
    [events, terminal, state]
  end

  def test_a_pending_withdrawn_command_proposes_the_catalog_withdraw
    _events, terminal, state = run_reconsider(
      commands: [command(command_id: "cmd-pending", intent_type: "create_maintenance_ticket", status: "pending")],
      correction: {"invalidates" => ["cmd-pending"]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    intent = state.fetch(:decision).fetch("intents").first
    assert_equal "withdraw_ticket", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
    assert_equal "cmd-pending", intent.fetch("compensates")
  end

  def test_a_dispatched_command_is_downgraded_not_withdrawn
    _events, terminal, state = run_reconsider(
      commands: [command(command_id: "cmd-dispatched", intent_type: "create_maintenance_ticket", status: "dispatched")],
      correction: {"invalidates" => ["cmd-dispatched"]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    intent = state.fetch(:decision).fetch("intents").first
    assert_equal "downgrade_dispatch", intent.fetch("type")
    assert_equal "cmd-dispatched", intent.fetch("compensates")
  end

  def test_an_unreferenced_command_stands
    _events, terminal, state = run_reconsider(
      commands: [command(command_id: "cmd-other", intent_type: "create_maintenance_ticket", status: "dispatched")],
      correction: {"invalidates" => ["cmd-unrelated"]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    intent = state.fetch(:decision).fetch("intents").first
    assert_equal "install_watch_condition", intent.fetch("type"),
                 "an unreferenced command stands — the episode observes (R0), never compensates"
  end

  def test_a_compensation_above_the_episode_ceiling_stands
    # The transfer downgrade is R3; an R1-ceiling episode must NOT compensate.
    _events, terminal, state = run_reconsider(
      risk_ceiling: :RISK_CLASS_R1,
      commands: [command(command_id: "cmd-transfer", intent_type: "cancel_product_transfer", status: "dispatched")],
      correction: {"invalidates" => ["cmd-transfer"]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    intent = state.fetch(:decision).fetch("intents").first
    assert_equal "install_watch_condition", intent.fetch("type"),
                 "a compensation above the ceiling never fires — the episode observes (R0)"
  end

  def test_the_compensating_risk_is_the_targets_own_declared_risk
    # A transfer compensation is R3 — never "safe because it undoes".
    _events, terminal, state = run_reconsider(
      risk_ceiling: :RISK_CLASS_R4,
      commands: [command(command_id: "cmd-transfer", intent_type: "cancel_product_transfer", status: "pending")],
      correction: {"invalidates" => ["cmd-transfer"]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    intent = state.fetch(:decision).fetch("intents").first
    assert_equal "cancel_product_transfer", intent.fetch("type")
    assert_equal "R3", intent.fetch("risk_class")
  end

  def test_an_unknown_compensation_mapping_fails_closed
    # A command whose intent type has NO catalog compensation metadata for the
    # required action → typed failure, never a substitution.
    _events, terminal, _state = run_reconsider(
      commands: [command(command_id: "cmd-unknown", intent_type: "reduce_load", status: "pending")],
      correction: {"invalidates" => ["cmd-unknown"]}
    )
    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
  end

  def test_no_model_receipt_exists_in_any_reconsider_episode
    _events, terminal, state = run_reconsider(
      commands: [command(command_id: "cmd-pending", intent_type: "create_maintenance_ticket", status: "pending")],
      correction: {"invalidates" => ["cmd-pending"]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal [], state.fetch(:model_receipts),
                 "a reconsider episode never calls the model — no receipts"
    # The journal has NO model-call effects (the only model-calling node
    # never runs for a reconsider episode — verified at the SQLite table).
    adapter = @composition.fetch(:adapter)
    count = adapter.__send__(:read, operation: "reconsider.effects") do |tx|
      tx.scalar("reconsider.effects.count", "SELECT COUNT(*) FROM tamoz_effects")
    end
    assert_equal 0, count,
                 "the journal holds no model-call effects for a reconsider episode"
  end

  def test_a_refuted_intent_digest_maps_to_its_command
    # A correction REFUTES an intent digest; the judge maps it to the command
    # that executed it.
    digest = "sha256:#{"b" * 64}"
    command = {"command_id" => "cmd-refuted", "intent_type" => "create_maintenance_ticket",
               "status" => "dispatched", "intent_digest" => digest}
    _events, terminal, state = run_reconsider(
      commands: [command],
      correction: {"refutes" => [digest]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    intent = state.fetch(:decision).fetch("intents").first
    assert_equal "downgrade_dispatch", intent.fetch("type")
    assert_equal "cmd-refuted", intent.fetch("compensates")
  end

  def test_a_reconsider_replay_is_byte_identical
    _events, terminal, state = run_reconsider(
      commands: [command(command_id: "cmd-pending", intent_type: "create_maintenance_ticket", status: "pending")],
      correction: {"invalidates" => ["cmd-pending"]}
    )
    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    decision1 = state.fetch(:decision)

    events2 = []
    @composition.fetch(:runner).run(
      EpisodeComposition.wire_request(
        episode_id: "p6-reconsider", kind: :EPISODE_KIND_RECONSIDER,
        risk_ceiling: :RISK_CLASS_R2, allowed_intent_types: [],
        reconsideration: reconsideration(
          commands: [command(command_id: "cmd-pending", intent_type: "create_maintenance_ticket", status: "pending")],
          correction: {"invalidates" => ["cmd-pending"]}
        ),
        fence: 2
      )
    ).each { |event| events2 << event }
    result2 = @composition.fetch(:app).durable_runner.fetch(
      thread: "episode.p6-reconsider",
      request_id: "episode.p6-reconsider.at-1.2",
      namespace: ["acme"]
    )
    state2 = @composition.fetch(:app).state(
      thread: "episode.p6-reconsider", namespace: ["acme"],
      checkpoint_id: result2.checkpoint_id
    ).state.to_h
    assert_equal strip_wall_clock(decision1), strip_wall_clock(state2.fetch(:decision)),
                 "a reconsider replay is byte-identical (modulo the wall-clock expires_at)"
  end
end
