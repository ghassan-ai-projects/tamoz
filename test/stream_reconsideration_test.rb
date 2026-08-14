# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require_relative "fixtures/episode_diagnose"

# T6 (PLAN_TAMOZ_STREAM_BUILD T6.1): RECONSIDER episodes. The worker routes
# kind: RECONSIDER with the prior Decision/commands/outcomes/correction; the
# judgment module decides withdraw / downgrade / let-stand; compensating
# intents carry their OWN risk class (maintenance → R1, transfer in motion →
# R3), never assumed safe because they undo something, and never above the
# episode's risk ceiling. The freezer golden trace produces a DOWNGRADE —
# the false urgent ticket becomes routine, the audit trail stays intact.
class StreamReconsiderationTest < Minitest::Test
  Reconsideration = Tamoz::Stream::Reconsideration

  def worker
    Tamoz::Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
  end

  def snapshot
    {
      "situation_id" => "sit-1", "situation_version" => 7,
      "tenant_id" => "acme", "situation_type" => "equipment",
      "entity" => {"type" => "compressor", "id" => "c-01"},
      "facts" => {"pressure" => 0.2}
    }
  end

  def episode(risk_ceiling: "r2")
    {
      episode_id: "ep-1", attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      risk_ceiling:
    }
  end

  def prior_decision
    {
      "decision_id" => "decision.ep-1.at-1.1",
      "episode_id" => "ep-1", "attempt_id" => "at-1", "fence" => 1,
      "snapshot_digest" => "sha256:#{"0" * 64}",
      "confidence" => 0.9,
      "intents" => [{
        "intent_id" => "intent.ep-1.at-1.1.maintenance.ticket",
        "decision_id" => "decision.ep-1.at-1.1",
        "tenant_id" => "acme", "situation_id" => "sit-1", "situation_version" => 7,
        "type" => "maintenance.ticket", "risk_class" => "R1",
        "parameters" => {"entity_id" => "c-01", "priority" => "urgent"},
        "expires_at" => "2026-08-19T00:00:00Z"
      }]
    }
  end

  def executed_command(status: "dispatched", command_id: "cmd_0091_a")
    {
      "command_id" => command_id,
      "intent_id" => "intent.ep-1.at-1.1.maintenance.ticket",
      "intent_type" => "maintenance.ticket",
      "risk_class" => "R1",
      "status" => status,
      "target" => {"system" => "cmms", "ticket" => "4471"},
      "parameters" => {"priority" => "urgent"}
    }
  end

  def correction(invalidates: ["cmd_0091_a"])
    {
      "reason" => "prior_action_invalidated",
      "explanation" => "Door-open event explains the initial signal.",
      "invalidates" => invalidates
    }
  end

  def wire_reconsideration(invalidates: ["cmd_0091_a"], command: nil)
    Agenticstream::Runtime::V1::Reconsideration.new(
      prior_decision_json: Tamoz::Core.jcs(prior_decision),
      executed_command_json: [Tamoz::Core.jcs(command || executed_command)],
      observed_outcome_json: [Tamoz::Core.jcs(
        {"command_id" => "cmd_0091_a", "outcome" => "executed"}
      )],
      correction_json: Tamoz::Core.jcs(correction(invalidates:))
    )
  end

  def parsed
    Reconsideration.parse(wire_reconsideration)
  end

  def envelope
    Tamoz::Stream::EpisodeRequestEnvelope.new(
      Agenticstream::Runtime::V1::EpisodeRequest.new(
        protocol_version: "1.0", episode_id: "ep-1", attempt_id: "at-1",
        fence: 1, tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
        kind: :EPISODE_KIND_RECONSIDER, lane: :EPISODE_LANE_FAST,
        risk_ceiling: :RISK_CLASS_R2,
        reconsideration: wire_reconsideration
      ),
      worker
    )
  end

  def test_parse_carries_the_prior_decision_commands_and_correction
    value = parsed
    assert_equal "decision.ep-1.at-1.1", value.prior_decision.fetch("decision_id")
    assert_equal "cmd_0091_a", value.commands.fetch(0).fetch("command_id")
    assert_equal "prior_action_invalidated", value.correction.fetch("reason")
    assert_equal "cmd_0091_a", value.to_h.fetch(:commands).fetch(0).fetch("command_id")
  end

  def test_parse_refuses_an_episode_without_the_prior_decision
    error = assert_raises(Tamoz::Stream::Reconsideration::ReconsiderationError) do
      Reconsideration.parse(
        Agenticstream::Runtime::V1::Reconsideration.new(correction_json: "{}")
      )
    end
    assert_includes error.message, "prior decision"
  end

  def test_the_freezer_trace_downgrades_the_dispatched_ticket_not_withdraws
    judgements = Reconsideration.judge(parsed:)

    assert_equal 1, judgements.length
    judgement = judgements.fetch(0)
    assert_equal :downgrade, judgement.decision,
                 "the false urgent ticket must be downgraded, not withdrawn"
    assert_equal "cmd_0091_a", judgement.command_id
  end

  def test_a_pending_command_is_withdrawn
    judgement = Reconsideration.judge(
      parsed: Reconsideration.parse(
        wire_reconsideration(command: executed_command(status: "pending"))
      )
    ).fetch(0)
    assert_equal :withdraw, judgement.decision
  end

  def test_a_command_the_correction_does_not_reference_stands
    judgements = Reconsideration.judge(
      parsed: Reconsideration.parse(wire_reconsideration(invalidates: []))
    )
    assert judgements.fetch(0).let_stand?
  end

  def test_the_downgrade_intent_carries_its_own_risk_class_and_compensates
    intents = Reconsideration.build_compensating_intents(
      Reconsideration.judge(parsed:),
      episode:, snapshot:, now: Time.utc(2026, 8, 12)
    )

    assert_equal 1, intents.length
    intent = intents.fetch(0)
    assert_equal "downgrade_maintenance_ticket", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
    assert_equal "cmd_0091_a", intent.fetch("compensates")
    assert_equal "routine", intent.fetch("parameters").fetch("priority")
    assert Tamoz::Core.verify_digest(
      :intent, intent.reject { |key, _| key == "intent_digest" },
      intent.fetch("intent_digest")
    )
  end

  def test_an_emergency_water_exchange_downgrades_as_a_valid_r1_intervention
    command = executed_command(command_id: "cmd_pond_1").merge(
      "intent_type" => "emergency_water_exchange"
    )
    judgement = Reconsideration.judge(
      parsed: Reconsideration.parse(
        wire_reconsideration(invalidates: ["cmd_pond_1"], command:)
      )
    ).fetch(0)

    intent = Reconsideration.build_compensating_intents(
      [judgement], episode: episode(risk_ceiling: "r1"), snapshot:
    ).fetch(0)

    assert_equal :downgrade, judgement.decision
    assert_equal "downgrade_intervention", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
    assert_equal "cmd_pond_1", intent.fetch("compensates")
    assert Reconsideration.valid_compensation?(intent, risk_ceiling: "r1")
  end

  def test_a_dispatch_crew_downgrade_uses_the_pump_compensation
    command = executed_command(command_id: "cmd_pump_1").merge(
      "intent_type" => "dispatch_crew", "risk_class" => "R2"
    )
    judgement = Reconsideration.judge(
      parsed: Reconsideration.parse(
        wire_reconsideration(
          invalidates: ["cmd_pump_1"], command:
        )
      )
    ).fetch(0)

    intent = Reconsideration.build_compensating_intents(
      [judgement], episode: episode(risk_ceiling: "r1"), snapshot:
    ).fetch(0)

    assert_equal :downgrade, judgement.decision
    assert_equal "downgrade_dispatch", intent.fetch("type")
    assert_equal "R1", intent.fetch("risk_class")
    assert_equal "cmd_pump_1", intent.fetch("compensates")
    assert Reconsideration.valid_compensation?(intent, risk_ceiling: "r1")
  end

  def test_a_transfer_compensation_is_classified_at_r3
    transfer_command = executed_command(
      command_id: "cmd_transfer_1",
      status: "dispatched"
    ).merge("intent_type" => "transfer.product", "risk_class" => "R2")
    judgement = Reconsideration.judge(
      parsed: Reconsideration.parse(
        wire_reconsideration(
          invalidates: ["cmd_transfer_1"], command: transfer_command
        )
      )
    ).fetch(0)
    assert_equal :downgrade, judgement.decision

    intents = Reconsideration.build_compensating_intents(
      [judgement], episode: episode(risk_ceiling: "r4"), snapshot:
    )
    assert_equal "R3", intents.fetch(0).fetch("risk_class"),
                 "a product transfer in motion compensates at R3, not R1"
  end

  def test_a_compensation_above_the_risk_ceiling_is_never_proposed
    intents = Reconsideration.build_compensating_intents(
      Reconsideration.judge(parsed:),
      episode: episode(risk_ceiling: "r0"), snapshot:
    )
    assert_empty intents,
                 "an R0 episode must not compensate at R1"
  end

  def test_the_decision_builder_includes_valid_compensations
    intents = Reconsideration.build_compensating_intents(
      Reconsideration.judge(parsed:),
      episode:, snapshot:
    )
    decision, digest = Tamoz::Stream::DecisionBuilder.build(
      envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
      outcome: {compensating_intents: intents, confidence: 0.9}
    )
    assert_equal "downgrade_maintenance_ticket",
                 decision.fetch("intents").fetch(0).fetch("type")
    assert Tamoz::Core.verify_digest(:decision, decision, digest)
  end

  def test_the_decision_builder_refuses_a_malformed_compensation
    forged = {
      "type" => "downgrade_maintenance_ticket", "risk_class" => "R1",
      "compensates" => "cmd_0091_a",
      "parameters" => {"priority" => "routine"}
    }
    assert_raises(Tamoz::Stream::StreamError) do
      Tamoz::Stream::DecisionBuilder.build(
        envelope:, snapshot:, snapshot_digest: "sha256:#{"0" * 64}",
        outcome: {compensating_intents: [forged]}
      )
    end
  end

  def test_the_envelope_refuses_a_reconsider_without_the_payload
    assert_raises(Tamoz::Stream::EpisodeRequestInvalidError) do
      Tamoz::Stream::EpisodeRequestEnvelope.new(
        Agenticstream::Runtime::V1::EpisodeRequest.new(
          protocol_version: "1.0", episode_id: "ep-1", attempt_id: "at-1",
          fence: 1, tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
          kind: :EPISODE_KIND_RECONSIDER, lane: :EPISODE_LANE_FAST,
          risk_ceiling: :RISK_CLASS_R2
        ),
        worker
      )
    end
  end

  # End to end: a RECONSIDER episode runs through the runner, the graph node
  # judges via the module, and the produced decision carries the downgrade.
  def test_a_reconsider_episode_produces_a_downgrade_decision
    directory = Dir.mktmpdir("tamoz-reconsider-e2e")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    app = build_episode_app(adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil
    )

    wire = Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-reconsider", attempt_id: "at-1", fence: 1,
      tenant_id: "acme", situation_id: "sit-1", situation_version: 7,
      kind: :EPISODE_KIND_RECONSIDER, lane: :EPISODE_LANE_FAST,
      risk_ceiling: :RISK_CLASS_R2,
      budget: Agenticstream::Runtime::V1::EpisodeBudget.new(max_model_calls: 5),
      capability_token: "opaque.hmac.token",
      reconsideration: wire_reconsideration,
      snapshot_json: Tamoz::Core.jcs(snapshot),
      snapshot_sha256: Tamoz::Core.digest(:snapshot, snapshot)
    )

    events = runner.run(wire).each.to_a
    assert_empty events.select { |event| event.model_started != nil }
    budget_events = events.select { |event| event.budget != nil }
    assert_equal 1, budget_events.length
    assert_equal 0, budget_events.fetch(0).budget.model_calls_used
    assert_equal 0, budget_events.fetch(0).budget.cumulative_usage.input_tokens
    assert_equal 0, budget_events.fetch(0).budget.cumulative_usage.output_tokens
    assert_equal 0, budget_events.fetch(0).budget.cumulative_usage.cost_microunits
    assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
    decision_event = events.find { |event| event.decision != nil }
    refute_nil decision_event, "a produced reconsider episode must propose a decision"
    decision = JSON.parse(decision_event.decision.decision_json)
    assert_equal "downgrade_maintenance_ticket",
                 decision.fetch("intents").fetch(0).fetch("type")
    assert_equal "R1", decision.fetch("intents").fetch(0).fetch("risk_class")
    assert_equal "cmd_0091_a", decision.fetch("intents").fetch(0).fetch("compensates")
    assert Tamoz::Core.verify_digest(
      :decision, decision, decision_event.decision.decision_sha256
    )
    adapter.close
  ensure
    FileUtils.remove_entry(directory) if directory
  end
end
