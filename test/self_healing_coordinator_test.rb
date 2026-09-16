# frozen_string_literal: true

require_relative "test_helper"

# The composition-root wiring that makes `tamoz-agent-healing` reachable from a
# real failure path. These prove the coordinator's OWN contract — rule matching,
# the durable circuit, and the durable attempt bound that closes F20-REL-01 — with
# an injected remediation runner where a full protocol run is not the unit here.
class SelfHealingCoordinatorTest < Minitest::Test
  Coordinator = Tamoz::Agent::SelfHealingCoordinator
  Healing = Tamoz::Agent::Healing

  # A terminal-outcome double: the coordinator reads only `state`/`recovered?`.
  FakeOutcome = Data.define(:state) do
    def recovered? = state == :recovered
  end

  # An injectable remediation runner that records the call it received.
  class FakeRemediation
    attr_reader :calls

    def initialize(outcome_state:, on_call: nil)
      @outcome_state = outcome_state
      @on_call = on_call
      @calls = []
    end

    def run(**kwargs)
      @calls << kwargs
      @on_call&.call(kwargs)
      FakeOutcome.new(state: @outcome_state)
    end
  end

  def with_store
    Dir.mktmpdir("tamoz-healing") do |dir|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, "healing.sqlite3"))
      yield adapter.store
    ensure
      adapter&.close
    end
  end

  def build_rule
    Healing::HealingRule.new(
      rule_id: "rule.stale-conditional-file-edit", version: 1,
      owner: "human:owner", lifecycle_mode: :shadow,
      trigger: {"categories" => %w[stale_precondition]},
      minimum_confidence: 1.0, risk_class: :low, effect_class: :reconcilable,
      authorized_scopes: ["workspace"], authorized_resources: ["answer.txt"],
      plan_review_policy: {
        "plan_required" => true, "semantic_critic_required" => true,
        "human_approval_required" => true
      },
      preconditions: Healing::Preflight::CHECK_IDS.map(&:to_s),
      remediation_steps: [
        {"form" => "refresh_recompute", "safety" => "reconcilable", "creates" => false}
      ],
      effect_identity: {"domain" => Healing::EffectIdentity::DOMAIN},
      budgets: {"max_attempts" => 2, "max_magnitude" => 1.0, "max_cost" => 1.0, "max_seconds" => 30.0},
      verification_oracle: {"kind" => "configured_check", "check_name" => "answer", "digest" => "sha256:#{"c" * 64}"},
      compensation: {"kind" => "restore_preimage"},
      circuit_conditions: %w[verification_failed_twice compensation_failed],
      reset_authority: "human:owner",
      escalation_contract: {"sink" => "tamoz.escalations", "recommended_next_action" => "re-read"},
      eval_suite: "tamoz.evals.healing.stale-edit", created_at_ms: 1_700_000_000_000
    )
  end

  def build_record(category: :stale_precondition)
    Healing::FailureRecord.new(
      failure_code: "stale.answer", category:, operation: "tool.apply_patch",
      tool: "apply_patch", target_resource: "answer.txt", effect_state: :not_attempted,
      policy_version: "policy/1", behavior_version: "tamoz.agent.session/1",
      retryability: {"pre_dispatch" => false, "effect_safety" => "reconcilable"},
      trusted_context: {"original_operation_authorized" => true},
      observed_at_ms: 1_700_000_000_000
    )
  end

  def registry_with(rule)
    registry = Healing::RuleRegistry.new
    registry.register(rule)
    registry
  end

  def coordinator(store, rules, remediation: Healing::Remediation)
    Coordinator.new(store:, rules:, owner_id: "rule.stale-conditional-file-edit",
                    clock: -> { Time.at(1_700_000_000) }, remediation:)
  end

  def collaborators
    {toolbox: Object.new, critic: ->(_) {}, original_invariant: "x",
     minimal_change: "y", stop_conditions: [], perform: -> {}}
  end

  # An empty registry is the shipped default: nothing triggers, so wiring is a
  # safe no-op — the failure path escalates exactly as before healing was wired.
  def test_no_matching_rule_escalates
    with_store do |store|
      decision = coordinator(store, Healing::RuleRegistry.new).remediate(build_record, toolbox: Object.new)
      assert decision.escalated?
      assert_equal "no_matching_rule", decision.reason
    end
  end

  # F20-REL-01 REGRESSION: the durable counter — not the caller's `attempt:` — is
  # the bound. At the ceiling the protocol is refused BEFORE it runs.
  def test_durable_attempt_bound_refuses_before_running
    with_store do |store|
      record = build_record
      store.put(Coordinator::ATTEMPTS_NAMESPACE, record.fingerprint,
                {"attempts" => Coordinator::MAX_DURABLE_ATTEMPTS, "updated_at_ms" => 0}, if_version: nil)

      remediation = FakeRemediation.new(outcome_state: :recovered)
      decision = coordinator(store, registry_with(build_rule), remediation:).remediate(record, **collaborators)

      assert decision.escalated?
      assert_equal "durable_attempt_bound_exceeded", decision.reason
      assert_empty remediation.calls, "the bounded protocol must not run once the durable ceiling is reached"
      seeded = store.get(Coordinator::ATTEMPTS_NAMESPACE, record.fingerprint).value.fetch("attempts")
      assert_equal Coordinator::MAX_DURABLE_ATTEMPTS, seeded, "a refused attempt must not increment the counter"
    end
  end

  # A durable open circuit is honoured across a fresh coordinator instance.
  def test_open_durable_circuit_escalates
    with_store do |store|
      rule = build_rule
      circuit = Tamoz::SQLite::CircuitStore.new(
        store:, scope: :rule_target, scope_id: rule.rule_id, owner_id: rule.rule_id,
        clock: -> { Time.at(1_700_000_000) }
      )
      circuit.record_failure(kind: :verification_failed) until circuit.open?

      remediation = FakeRemediation.new(outcome_state: :recovered)
      decision = coordinator(store, registry_with(rule), remediation:).remediate(build_record, **collaborators)

      assert decision.escalated?
      assert_equal "circuit_open", decision.reason
      assert_empty remediation.calls
    end
  end

  # Happy path: a matching rule under the bound with a closed circuit runs the
  # protocol with a durable-first increment, and a recovery clears the counter.
  def test_matching_rule_runs_protocol_and_clears_counter_on_recovery
    with_store do |store|
      record = build_record
      persisted = nil
      remediation = FakeRemediation.new(
        outcome_state: :recovered,
        on_call: ->(_) { persisted = store.get(Coordinator::ATTEMPTS_NAMESPACE, record.fingerprint)&.value&.fetch("attempts") }
      )
      decision = coordinator(store, registry_with(build_rule), remediation:).remediate(record, **collaborators)

      assert decision.recovered?
      call = remediation.calls.fetch(0)
      assert_equal 1, call.fetch(:attempt), "the gem receives the durable attempt count, not a caller-owned 1"
      assert_equal 1, persisted, "durable-first: the increment is persisted before the protocol runs"
      refute_nil call.fetch(:circuit), "the durable circuit is passed in, not built fresh per call"
      cleared = store.get(Coordinator::ATTEMPTS_NAMESPACE, record.fingerprint).value.fetch("attempts")
      assert_equal 0, cleared, "a recovered outcome clears the durable counter"
    end
  end

  # A non-recovered outcome leaves the durable increment standing, so a repeated
  # failure walks toward the ceiling instead of resetting each turn.
  def test_non_recovery_keeps_durable_increment
    with_store do |store|
      record = build_record
      remediation = FakeRemediation.new(outcome_state: :escalated)
      coordinator(store, registry_with(build_rule), remediation:).remediate(record, **collaborators)
      kept = store.get(Coordinator::ATTEMPTS_NAMESPACE, record.fingerprint).value.fetch("attempts")
      assert_equal 1, kept
    end
  end
end
