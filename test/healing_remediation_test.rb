# frozen_string_literal: true

require_relative "healing_fixtures"

# P12-H2 (plan §4) — the exact reviewed remediation protocol, proven by running
# it against a sandboxed fault through the REAL effect machinery:
#
#   1. classify → 2. plan → 3. semantic critic review → 4. preflight →
#   5. execute ONE permitted form → 6. verify with the rule-supplied oracle →
#   7. recover OR compensate/escalate.
#
# The proofs that matter (from the plan §4/§11 and invariants 25–27, 32–34):
#
# * `recovered` is reachable ONLY through `Oracle.verify(...).passed` — never
#   from the remediation model's explanation (invariant 33, C2).
# * A rejecting semantic critic, a failed preflight, an open circuit, and a
#   never-mutate class all terminate before `perform` is ever called ("no blind
#   retry" is control flow, not caller discipline).
# * Verification failure compensates (or escalates), never `recovered`.
# * Every non-recovered terminal writes an escalation record whose payload
#   carries the typed failure, rule identity, digests, and terminal state.
# * `run` is invoked ONLY from the `:remediating` transition (structural).
class HealingRemediationTest < Minitest::Test
  include HealingFixtures

  Healing = Tamoz::Agent::Healing

  # The minimal, exactly-authorized remediation: rewrite answer.txt to the
  # healed state. Runs through the effect journal like any reviewed effect.
  def heal_perform(toolbox)
    lambda do
      toolbox.execute(
        "apply_patch",
        {
          "path" => "answer.txt",
          "before" => "broken\n",
          "after" => "healed\n",
          "expected_sha256" => Digest::SHA256.hexdigest("broken\n")
        }
      )
    end
  end

  def run_remediation(rule: nil, critic: nil, toolbox: nil, perform: nil,
                      perform_factory: nil, reconcile: nil, **overrides)
    critic ||= accepting_critic
    with_healing_workspace do |dir, real_toolbox|
      toolbox ||= real_toolbox
      rule ||= healing_rule(toolbox:)
      preflight_context = overrides.delete(:preflight_context) || {}
      # `resources_and_locks_canonical` requires the realpath-resolved target
      # when the failure names one (design §5).
      preflight_context[:canonical_resource] ||=
        File.realpath(File.join(dir, "answer.txt"))
      with_effect_context do |context|
        outcome = Healing::Remediation.run(
          record: failure_record,
          rule:,
          toolbox:,
          critic:,
          original_invariant: "the answer file must contain the healed marker",
          minimal_change: "replace only the broken marker with the healed marker",
          stop_conditions: ["oracle answer passes"],
          perform: perform || (perform_factory ? perform_factory.call(toolbox) : heal_perform(toolbox)),
          reconcile: reconcile || -> { [:completed, {"observed" => "effect completed"}, nil] },
          context:,
          preflight_context:,
          **overrides
        )
        yield dir, outcome, context
      end
    end
  end

  # --- the happy path -----------------------------------------------------

  def test_full_lifecycle_recovers_only_through_the_oracle
    run_remediation do |_dir, outcome, _context|
      assert outcome.recovered?
      assert outcome.oracle_backed?
      assert_equal :recovered, outcome.state
      assert outcome.performed

      # The recovery is a real, checkable state: the configured check passes.
      # (the fixture's check is `grep -q healed answer.txt`.)
      states = outcome.transitions.map { |entry| entry.fetch("state").to_s }
      assert_includes states, "classified"
      assert_includes states, "planned"
      assert_includes states, "reviewed"
      assert_includes states, "preflighted"
      assert_includes states, "remediating"
      assert_includes states, "verifying"
    end
  end

  def test_recovered_always_carries_a_passing_oracle_result
    run_remediation do |_dir, outcome, _context|
      assert outcome.recovered?
      assert_equal true, outcome.verification.passed
      assert_equal "answer", outcome.verification.check_name
      assert_equal "oracle_pass", outcome.verification.reason
    end
  end

  # Invariant 33: the oracle is a configured check, pinned by digest. A rule
  # whose oracle pin does not match the real check can never produce
  # `recovered` — the verification is a digest-checked failure, whatever the
  # remediation did.
  def test_oracle_mismatch_never_recovers
    run_remediation(
      rule: healing_rule(
        oracle_digest: "sha256:#{"f" * 64}" # wrong pin for the real check
      )
    ) do |dir, outcome, _context|
      refute outcome.recovered?
      assert outcome.terminal?
      assert_equal :escalated, outcome.state
      refute outcome.oracle_backed?
      assert_equal "oracle_digest_mismatch", outcome.verification.reason
      # The workspace did not silently "recover": the oracle still fails.
      refute_equal "oracle_pass", outcome.verification.reason
    end
  end

  # --- the gates that must return BEFORE any mutation ----------------------

  def test_rejecting_critic_escalates_before_any_execution
    outcome = nil
    performed = false
    run_remediation(critic: rejecting_critic) do |_dir, result, _context|
      outcome = result
    end
    assert_equal :escalated, outcome.state
    refute outcome.performed
    refute outcome.recovered?
    # The escalation names the typed precondition, not prose.
    refute_nil outcome.failure
    assert_equal :semantic_critic_review, outcome.failure.precondition
    assert_kind_of Healing::PreflightRejection, outcome.failure
  end

  def test_preflight_rejection_escalates_without_mutation
    # A contended lock fails `resources_and_locks_canonical` → the preflight
    # rejects and the attempt escalates before any mutation.
    outcome = nil
    run_remediation(
      preflight_context: {lock_state: :contended}
    ) do |_dir, result, _context|
      outcome = result
    end
    assert_equal :escalated, outcome.state
    refute outcome.performed
    refute_nil outcome.preflight_rejection
    assert_kind_of Healing::PreflightRejection, outcome.preflight_rejection
    assert_equal :resources_and_locks_canonical, outcome.preflight_rejection.precondition
  end

  def test_open_circuit_terminates_before_classification
    circuit = Healing::Seams::MemoryCircuitStore.new(scope: "rule:rule.stale-conditional-file-edit")
    circuit.record_failure(kind: :verification)
    circuit.record_failure(kind: :verification)

    outcome = nil
    run_remediation(circuit:) do |_dir, result, _context|
      outcome = result
    end
    assert_equal :circuit_open, outcome.state
    assert outcome.terminal?
    refute outcome.performed
  end

  def test_never_mutate_class_escalates_without_an_executor
    # A policy_denied failure is never remediated automatically; the protocol
    # must escalate WITHOUT requiring (or calling) a perform executor.
    record = failure_record(
      failure_code: "policy.root_escape", category: :policy_denied,
      operation: "tool.read_file", tool: "read_file", target_resource: "/etc/passwd",
      expected_digest: nil, observed_digest: nil
    )
    outcome = nil
    with_healing_workspace do |_dir, toolbox|
      with_effect_context do |context|
        outcome = Healing::Remediation.run(
          record:,
          rule: healing_rule(toolbox:),
          toolbox:,
          critic: accepting_critic,
          original_invariant: "no file may be read outside the workspace",
          minimal_change: "none — the operation must be refused",
          stop_conditions: [],
          context:,
          perform: -> { flunk "a never-mutate class must never execute" }
        )
      end
    end
    assert_equal :escalated, outcome.state
    refute outcome.performed
  end

  # Design §2/§7 (critic probe 4): an effect_unknown condition reconciles, then
  # escalates — the reconciler IS invoked, the perform is NEVER called, and the
  # outcome is a terminal escalate, never a retry and never a recovery.
  def test_effect_unknown_reconciles_then_escalates_without_an_executor
    record = failure_record(
      failure_code: "effect.timeout_after_dispatch", category: :effect_unknown,
      operation: "tool.apply_patch", tool: "apply_patch",
      target_resource: "answer.txt",
      expected_digest: "sha256:#{"a" * 64}", observed_digest: nil,
      effect_state: :unknown
    )
    reconciled = []
    outcome = nil
    with_healing_workspace do |dir, toolbox|
      with_effect_context do |context|
        outcome = Healing::Remediation.run(
          record:,
          rule: reconcile_rule(toolbox:),
          toolbox:,
          critic: accepting_critic,
          original_invariant: "the answer file must contain the healed marker",
          minimal_change: "reconcile the unknown effect before any retry",
          stop_conditions: ["reconciliation completed"],
          preflight_context: {
            canonical_resource: File.realpath(File.join(dir, "answer.txt")),
            # The §7 gate: an unknown effect state is acceptable ONLY when a
            # reconciliation is selected (the no-blind-retry precondition).
            reconciliation_selected: true
          },
          context:,
          reconcile: lambda do
            reconciled << :invoked
            [:completed, {"observed" => "no effect applied"}, nil]
          end,
          perform: -> { flunk "an effect_unknown condition must never perform" }
        )
      end
    end
    assert_equal :escalated, outcome.state
    refute outcome.performed
    assert_equal [:invoked], reconciled
    assert_equal :effect_unknown, outcome.classification.category
    assert_nil outcome.effect_outcome
  end

  # Design §7 (critic probe 6): an effect_unknown classification WITHOUT a
  # reconciler is a contract error — the protocol refuses rather than guessing.
  def test_effect_unknown_without_a_reconciler_is_a_contract_error
    record = failure_record(
      failure_code: "effect.timeout_after_dispatch", category: :effect_unknown,
      operation: "tool.apply_patch", tool: "apply_patch",
      target_resource: "answer.txt",
      expected_digest: "sha256:#{"a" * 64}", observed_digest: nil,
      effect_state: :unknown
    )
    with_healing_workspace do |dir, toolbox|
      with_effect_context do |context|
        error = assert_raises(Healing::HealingContractError) do
          Healing::Remediation.run(
            record:,
            rule: reconcile_rule(toolbox:),
            toolbox:,
            critic: accepting_critic,
            original_invariant: "the answer file must contain the healed marker",
            minimal_change: "reconcile the unknown effect before any retry",
            stop_conditions: ["reconciliation completed"],
            preflight_context: {
              canonical_resource: File.realpath(File.join(dir, "answer.txt")),
              reconciliation_selected: true
            },
            context:,
            reconcile: nil,
            perform: -> { flunk "must not execute" }
          )
        end
        assert_includes error.message, "requires a reconciler"
      end
    end
  end

  # Design §5/§8 (critic probe 4): remediation scope is INTERSECTED with the
  # original operation's authorization — a target outside the rule's
  # authorized_resources is refused by preflight before any mutation.
  def test_scope_intersection_refuses_a_target_outside_authorized_resources
    record = failure_record(
      failure_code: "workspace.stale_precondition", category: :stale_precondition,
      operation: "tool.apply_patch", tool: "apply_patch",
      target_resource: "/etc/passwd",
      expected_digest: "sha256:#{"a" * 64}", observed_digest: "sha256:#{"b" * 64}"
    )
    outcome = nil
    with_healing_workspace do |_dir, toolbox|
      with_effect_context do |context|
        outcome = Healing::Remediation.run(
          record:,
          rule: healing_rule(toolbox:),
          toolbox:,
          critic: accepting_critic,
          original_invariant: "the answer file must contain the healed marker",
          minimal_change: "replace only the broken marker",
          stop_conditions: ["oracle answer passes"],
          context:,
          perform: -> { flunk "a resource outside the authorized scope must never mutate" }
        )
      end
    end
    assert_equal :escalated, outcome.state
    refute outcome.performed
    refute_nil outcome.preflight_rejection
    assert_equal :rule_target_environment_behavior_match,
                 outcome.preflight_rejection.precondition
  end

  # --- verification failure ------------------------------------------------

  def test_verification_failure_compensates_and_never_recovers
    # The perform writes the WRONG content; the oracle (grep healed) fails, the
    # attempt compensates (contained, honest default) and escalates.
    bad_perform_factory = lambda do |toolbox|
      lambda do
        toolbox.execute(
          "apply_patch",
          {
            "path" => "answer.txt",
            "before" => "broken\n",
            "after" => "still broken\n",
            "expected_sha256" => Digest::SHA256.hexdigest("broken\n")
          }
        )
      end
    end

    outcome = nil
    run_remediation(perform_factory: bad_perform_factory) do |_dir, result, _context|
      outcome = result
    end
    assert outcome.terminal?
    assert_equal :escalated, outcome.state
    refute outcome.recovered?
    refute outcome.oracle_backed?
    refute_nil outcome.verification
    assert_equal false, outcome.verification.passed
    refute_nil outcome.compensation
    # The default compensation never claims a rollback it did not perform.
    assert_equal "contained", outcome.compensation.fetch("status")
    assert_nil outcome.compensation.fetch("receipt_digest")
  end

  def test_escalation_record_carries_the_design_section_10_contract
    sink = Healing::Seams::NullEscalationSink.new
    outcome = nil
    run_remediation(
      escalation_sink: sink,
      critic: rejecting_critic
    ) do |_dir, result, _context|
      outcome = result
    end
    record = sink.last
    refute_nil record
    assert_equal failure_record.digest, record.fetch("failure_digest")
    assert_equal "rule.stale-conditional-file-edit", record.fetch("rule_id")
    assert_equal 1, record.fetch("rule_version")
    assert_equal "escalated", record.fetch("terminal_state")
    assert record.key?("classification")
    assert record.key?("transitions")
    assert record.key?("recommended_next_action")
  end

  # --- determinism / identity ----------------------------------------------

  def test_effect_identity_is_deterministic
    one = Healing::EffectIdentity.describe(
      original_trace_id: "trace.1", original_effect_id: "tool.apply_patch",
      rule_id: "rule.stale-conditional-file-edit", rule_version: 1,
      remediation_step: "refresh_recompute"
    )
    two = Healing::EffectIdentity.describe(
      original_trace_id: "trace.1", original_effect_id: "tool.apply_patch",
      rule_id: "rule.stale-conditional-file-edit", rule_version: 1,
      remediation_step: "refresh_recompute"
    )
    assert_equal one, two
    assert_equal one.fetch("operation"), one.fetch("operation")
    assert one.key?("operation")
  end
end
