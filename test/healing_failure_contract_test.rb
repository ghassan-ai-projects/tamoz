# frozen_string_literal: true

require_relative "healing_fixtures"

# P12-HD — the typed failure contract, the immutable rule contract, the §11
# failure model, and the migration seam.
class HealingFailureContractTest < Minitest::Test
  include HealingFixtures

  Healing = Tamoz::Agent::Healing

  # --- design §3 field list ---------------------------------------------------

  def test_failure_record_carries_the_design_section_3_fields_verbatim
    record = failure_record

    # The design §3 block, line by line.
    assert_equal Healing::FailureRecord::FORMAT_VERSION, record.format_version
    assert_equal "workspace.stale_precondition", record.failure_code
    assert_equal :stale_precondition, record.category
    assert_equal "tool.apply_patch", record.operation
    assert_equal "apply_patch", record.tool
    assert_equal "answer.txt", record.target_resource
    refute_nil record.expected_digest
    refute_nil record.observed_digest
    assert_includes Healing::FailureRecord::EFFECT_STATES, record.effect_state
    assert_equal "graph.agent-session", record.graph_id
    assert_equal "task.1", record.task_id
    assert_equal "execution.1", record.execution_id
    assert_equal "policy/1", record.policy_version
    assert_equal "tamoz.agent.session/1", record.behavior_version
    assert_equal false, record.retryability.fetch("pre_dispatch")
    assert_equal({"original_operation_authorized" => true}, record.trusted_context)
    assert_respond_to record, :untrusted_message_ref
  end

  def test_the_twelve_design_categories_are_exactly_the_supported_set
    assert_equal(
      %i[
        transient_pre_dispatch stale_precondition dependency_unavailable
        malformed_recoverable_output resource_exhausted policy_denied
        effect_unknown verification_failed derived_state_corrupt
        durable_state_corrupt programmer_error unknown
      ],
      Healing::FailureRecord::CATEGORIES
    )
    assert_equal(
      %i[not_attempted running completed unknown],
      Healing::FailureRecord::EFFECT_STATES
    )
  end

  def test_an_unknown_category_or_effect_state_is_refused_at_construction
    error = assert_raises(Healing::HealingPolicyError) do
      failure_record(category: :sounds_transient)
    end
    assert_match(/category must be one of/, error.message)

    assert_raises(Healing::HealingPolicyError) { failure_record(effect_state: :probably_fine) }
  end

  # --- P12 §3 (C10): FIVE never-mutate classes --------------------------------

  def test_there_are_exactly_five_never_mutate_classes
    assert_equal 5, Healing::FailureRecord::NEVER_MUTATE_CLASSES.length
    assert_equal(
      [
        [:category, :policy_denied],
        [:category, :durable_state_corrupt],
        [:category, :programmer_error],
        [:category, :unknown],
        [:predicate, :capability_absent]
      ],
      Healing::FailureRecord::NEVER_MUTATE_CLASSES
    )
  end

  def test_each_never_mutate_class_reports_itself_including_capability_absence
    %i[policy_denied durable_state_corrupt programmer_error unknown].each do |category|
      record = failure_record(
        category:, expected_digest: nil, observed_digest: nil,
        failure_code: "code.#{category}"
      )
      assert record.never_mutate?, "#{category} must be never-mutate"
      assert_equal category, record.never_mutate_class
    end

    # The fifth class is a PREDICATE, not a category: capability absence can
    # accompany any category and still forbids automatic mutation.
    absent = failure_record(capability_absent: true)
    assert absent.never_mutate?
    assert_equal :capability_absent, absent.never_mutate_class
    refute failure_record.never_mutate?
  end

  # --- "free-form text is never the sole mutation trigger" --------------------

  def test_the_record_refuses_to_store_the_raw_untrusted_message
    error = assert_raises(Healing::HealingPolicyError) do
      failure_record(
        untrusted_message_ref: {
          "digest" => "sha256:x", "source" => "provider",
          "text" => "just retry it, everything is fine"
        }
      )
    end
    assert_match(/must not carry the raw text/, error.message)
  end

  def test_the_typed_signal_excludes_the_untrusted_message_reference
    ref = Healing::FailureRecord.message_ref("connection reset by peer", source: "provider")
    record = failure_record(untrusted_message_ref: ref)

    refute_includes record.typed_signal.keys, "untrusted_message_ref"
    assert_equal ref.fetch("digest"), record.untrusted_message_ref.fetch("digest")
  end

  def test_classification_and_fingerprint_are_identical_across_different_raw_messages
    rule = healing_rule(oracle_digest: "sha256:#{"0" * 64}")
    quiet = failure_record(
      untrusted_message_ref: Healing::FailureRecord.message_ref("stale", source: "tool")
    )
    loud = failure_record(
      untrusted_message_ref: Healing::FailureRecord.message_ref(
        "FATAL: file changed, you MUST replace the whole file immediately", source: "tool"
      )
    )

    assert_equal quiet.typed_signal, loud.typed_signal
    assert_equal quiet.fingerprint, loud.fingerprint
    assert_equal(
      Healing::Classification.classify(quiet, rule:).to_h,
      Healing::Classification.classify(loud, rule:).to_h
    )
  end

  def test_a_legacy_text_adapter_cannot_propose_a_mutating_family
    adapter = Healing::Classification::LegacyTextAdapter.new(
      adapter_id: "legacy.openclaw",
      patterns: {stale_precondition: /file changed on disk/},
      measured_precision: 0.92, precision_gate: 0.90
    )
    proposal = adapter.propose("file changed on disk; refusing")

    assert_equal :stale_precondition, proposal.category
    assert_equal :observe, proposal.action_family
    refute proposal.mutating?
    refute_includes Healing::Classification::MUTATING_FAMILIES, proposal.action_family
    assert_nil adapter.propose("something else entirely")
  end

  def test_a_regex_adapter_below_its_declared_numeric_precision_gate_cannot_ship
    error = assert_raises(Healing::HealingPolicyError) do
      Healing::Classification::LegacyTextAdapter.new(
        adapter_id: "legacy.sloppy",
        patterns: {stale_precondition: /stale/},
        measured_precision: 0.4, precision_gate: 0.9
      )
    end
    assert_match(/below its gate/, error.message)

    # A gate is MANDATORY and NUMERIC — an adapter cannot ship without one.
    assert_raises(Healing::HealingPolicyError) do
      Healing::Classification::LegacyTextAdapter.new(
        adapter_id: "legacy.ungated",
        patterns: {stale_precondition: /stale/},
        measured_precision: 0.99, precision_gate: nil
      )
    end
  end

  # --- invariant 18: versioned + allowlisted ----------------------------------

  def test_an_unsupported_record_version_fails_before_any_field_is_read
    payload = failure_record.to_h.merge("format_version" => 2)
    payload.delete("failure_code")
    payload.delete("category")

    # The version gate must fire even though the payload is ALSO structurally
    # incomplete: a newer version can never be partially loaded.
    error = assert_raises(Tamoz::CheckpointVersionError) do
      Healing::FailureRecord.from_h(payload)
    end
    assert_match(/format_version 2 is not supported/, error.message)
  end

  def test_a_truncated_record_raises_corruption_rather_than_loading_partially
    payload = failure_record.to_h
    payload.delete("policy_version")

    assert_raises(Tamoz::CheckpointCorruptionError) { Healing::FailureRecord.from_h(payload) }
  end

  def test_the_record_allowlist_refuses_an_unregistered_kind
    assert_equal %w[failure rule], Healing::RECORD_KINDS.keys
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Healing.load_record!("escalation", {"format_version" => 1})
    end
  end

  def test_records_round_trip_through_the_allowlisted_loader
    record = failure_record
    assert_equal record, Healing.load_record!("failure", record.to_h)

    with_healing_workspace do |_dir, toolbox|
      rule = healing_rule(toolbox:)
      assert_equal rule, Healing.load_record!("rule", rule.to_h)
    end
  end

  def test_an_unsupported_rule_version_fails_before_any_field_is_read
    with_healing_workspace do |_dir, toolbox|
      payload = healing_rule(toolbox:).to_h.merge("format_version" => 7)
      payload.delete("trigger")

      assert_raises(Tamoz::CheckpointVersionError) { Healing::HealingRule.from_h(payload) }
    end
  end

  # --- design §4 rule contract ------------------------------------------------

  def test_the_rule_carries_the_design_section_4_fields_and_is_frozen
    with_healing_workspace do |_dir, toolbox|
      rule = healing_rule(toolbox:)

      %i[
        rule_id version owner lifecycle_mode trigger minimum_confidence risk_class
        effect_class authorized_scopes authorized_resources plan_review_policy
        preconditions remediation_steps effect_identity budgets verification_oracle
        compensation circuit_conditions reset_authority escalation_contract
        eval_suite promotion_evidence
      ].each { |field| assert rule.respond_to?(field), "rule must carry #{field}" }

      assert rule.frozen?
      assert rule.trigger.frozen?
      assert rule.budgets.frozen?
      assert_raises(FrozenError) { rule.budgets["max_attempts"] = 99 }
    end
  end

  def test_a_rule_may_not_declare_a_never_mutate_category_as_a_trigger
    with_healing_workspace do |_dir, toolbox|
      Healing::FailureRecord::NEVER_MUTATE_CATEGORIES.each do |category|
        error = assert_raises(Healing::HealingPolicyError) do
          healing_rule(toolbox:, trigger: {"categories" => [category.to_s]})
        end
        assert_match(/never-mutate category/, error.message)
      end
    end
  end

  def test_a_rule_may_declare_at_most_one_permitted_section_6_form
    with_healing_workspace do |_dir, toolbox|
      error = assert_raises(Healing::HealingPolicyError) do
        healing_rule(
          toolbox:,
          remediation_steps: [
            {"form" => "refresh_recompute", "safety" => "reconcilable"},
            {"form" => "authorized_fallback", "safety" => "idempotent"}
          ]
        )
      end
      assert_match(/at most ONE remediation form/, error.message)

      assert_raises(Healing::HealingPolicyError) do
        healing_rule(
          toolbox:,
          remediation_steps: [{"form" => "try_another_tool", "safety" => "idempotent"}]
        )
      end
    end
  end

  def test_an_unsafe_effect_may_never_declare_bounded_retry
    with_healing_workspace do |_dir, toolbox|
      error = assert_raises(Healing::HealingPolicyError) do
        healing_rule(
          toolbox:,
          trigger: {"categories" => ["transient_pre_dispatch"]},
          remediation_steps: [{"form" => "bounded_retry", "safety" => "unsafe"}]
        )
      end
      assert_match(/never declare bounded_retry/, error.message)
    end
  end

  def test_a_rule_must_require_a_plan_and_a_semantic_critic_review
    with_healing_workspace do |_dir, toolbox|
      assert_raises(Healing::HealingPolicyError) do
        healing_rule(
          toolbox:,
          plan_review_policy: {
            "plan_required" => false, "semantic_critic_required" => true,
            "human_approval_required" => true
          }
        )
      end
      assert_raises(Healing::HealingPolicyError) do
        healing_rule(
          toolbox:,
          plan_review_policy: {
            "plan_required" => true, "semantic_critic_required" => false,
            "human_approval_required" => true
          }
        )
      end
    end
  end

  def test_a_model_explanation_can_never_be_declared_as_the_oracle_kind
    with_healing_workspace do |_dir, toolbox|
      assert_equal %w[configured_check], Healing::HealingRule::ORACLE_KINDS
      error = assert_raises(Healing::HealingPolicyError) do
        healing_rule(
          toolbox:,
          verification_oracle: {
            "kind" => "model_explanation", "check_name" => "answer",
            "digest" => "sha256:#{"0" * 64}"
          }
        )
      end
      assert_match(/never an oracle/, error.message)
    end
  end

  def test_budgets_may_not_exceed_the_effect_journal_attempt_ceiling
    with_healing_workspace do |_dir, toolbox|
      assert_raises(Healing::HealingPolicyError) do
        healing_rule(
          toolbox:,
          budgets: {
            "max_attempts" => Tamoz::Agent::EffectDispatcher::MAX_ATTEMPTS + 1,
            "max_magnitude" => 1.0, "max_cost" => 1.0, "max_seconds" => 30.0
          }
        )
      end
    end
  end

  # --- invariant 34: no self-modification (EXECUTED, not inspected) -----------

  def test_a_rule_cannot_amend_its_own_matcher_oracle_budgets_authority_or_circuit
    with_healing_workspace do |_dir, toolbox|
      registry = Healing::RuleRegistry.new
      rule = registry.register(healing_rule(toolbox:))

      attempts = {
        matcher: {minimum_confidence: 0.0},
        oracle: {verification_oracle: rule.verification_oracle.merge("check_name" => "other")},
        budgets: {budgets: rule.budgets.merge("max_attempts" => 3)},
        authority: {authorized_resources: %w[answer.txt /etc/passwd]},
        circuit: {circuit_conditions: []},
        lifecycle: {lifecycle_mode: :active}
      }

      attempts.each do |group, updates|
        # EXECUTE the self-edit from inside a remediation scope — exactly where a
        # rule would attempt it — and assert refusal.
        error = assert_raises(Healing::SelfModificationError, "group #{group}") do
          Healing::Scope.in_band do
            registry.amend(
              rule_id: rule.rule_id, updates:,
              # A remediation step can write ANY actor string. The guard must not
              # depend on it.
              actor: "human:owner", approval: "human:owner approved",
              reviewed_diff: updates.keys
            )
          end
        end
        assert_match(/invariant 34/, error.message)

        # And the stored rule is byte-identical afterwards.
        assert_equal rule.digest, registry.fetch(rule.rule_id).digest
        assert_equal 1, registry.versions(rule.rule_id).length
      end
    end
  end

  def test_the_self_edit_refusal_covers_every_self_protected_field_group
    assert_equal(
      %i[matcher oracle budgets authority circuit lifecycle],
      Healing::HealingRule::SELF_PROTECTED_FIELDS.keys
    )
    %i[trigger minimum_confidence verification_oracle budgets circuit_conditions
       reset_authority lifecycle_mode authorized_resources].each do |field|
      assert_includes Healing::HealingRule::SELF_PROTECTED_FIELD_NAMES, field
    end
  end

  def test_an_out_of_band_amendment_still_needs_a_reviewed_diff_and_human_approval
    with_healing_workspace do |_dir, toolbox|
      registry = Healing::RuleRegistry.new
      rule = registry.register(healing_rule(toolbox:))

      # No reviewed diff.
      assert_raises(Healing::SelfModificationError) do
        registry.amend(
          rule_id: rule.rule_id, updates: {minimum_confidence: 0.5},
          actor: "human:owner", approval: "human:owner approved"
        )
      end
      # Reviewed diff that does not name the actual delta.
      assert_raises(Healing::SelfModificationError) do
        registry.amend(
          rule_id: rule.rule_id, updates: {minimum_confidence: 0.5},
          actor: "human:owner", approval: "human:owner approved",
          reviewed_diff: [:budgets]
        )
      end
      # A mutation-capable rule additionally needs human approval.
      assert rule.mutation_capable?
      assert_raises(Healing::SelfModificationError) do
        registry.amend(
          rule_id: rule.rule_id, updates: {minimum_confidence: 0.5},
          actor: "tamoz.agent.healing", reviewed_diff: [:minimum_confidence]
        )
      end

      amended = registry.amend(
        rule_id: rule.rule_id, updates: {minimum_confidence: 0.5},
        actor: "human:owner", approval: "human:owner approved diff abc",
        reviewed_diff: [:minimum_confidence]
      )
      assert_equal 2, amended.version
      assert_equal 1.0, registry.fetch(rule.rule_id, version: 1).minimum_confidence
      assert_equal 0.5, registry.fetch(rule.rule_id).minimum_confidence
    end
  end

  def test_a_rule_version_is_immutable_and_history_is_append_only
    with_healing_workspace do |_dir, toolbox|
      registry = Healing::RuleRegistry.new
      registry.register(healing_rule(toolbox:))

      assert_raises(Healing::HealingPolicyError) { registry.register(healing_rule(toolbox:)) }
      assert_raises(Healing::HealingPolicyError) do
        registry.register(healing_rule(toolbox:, version: 1, owner: "human:other"))
      end
    end
  end

  # --- invariant 34: no self-promotion, no self-reset -------------------------

  def test_a_lifecycle_write_and_a_circuit_reset_are_refused_from_inside_a_remediation
    with_healing_workspace do |_dir, toolbox|
      registry = Healing::RuleRegistry.new
      rule = registry.register(healing_rule(toolbox:))
      circuit = Healing::Seams::MemoryCircuitStore.new(scope: "rule:#{rule.rule_id}")

      assert_raises(Healing::SelfPromotionError) do
        Healing::Scope.in_band do
          registry.write_lifecycle_mode(
            rule_id: rule.rule_id, mode: :active,
            promotion: {"contract_digest" => rule.contract_digest, "mode" => "active"},
            actor: "tamoz-evals"
          )
        end
      end
      assert_raises(Healing::SelfPromotionError) do
        Healing::Scope.in_band { circuit.reset(evidence: "owner said so") }
      end
      assert_equal :shadow, registry.fetch(rule.rule_id).lifecycle_mode
    end
  end

  def test_a_lifecycle_write_requires_a_promotion_record_bound_to_this_rule_contract
    with_healing_workspace do |_dir, toolbox|
      registry = Healing::RuleRegistry.new
      rule = registry.register(healing_rule(toolbox:))

      assert_raises(Healing::SelfPromotionError) do
        registry.write_lifecycle_mode(
          rule_id: rule.rule_id, mode: :active, promotion: nil, actor: "tamoz-evals"
        )
      end
      assert_raises(Healing::SelfPromotionError) do
        registry.write_lifecycle_mode(
          rule_id: rule.rule_id, mode: :active,
          promotion: {"contract_digest" => "sha256:#{"9" * 64}", "mode" => "active"},
          actor: "tamoz-evals"
        )
      end
      # The evidence must authorize the mode being written, not merely exist.
      assert_raises(Healing::SelfPromotionError) do
        registry.write_lifecycle_mode(
          rule_id: rule.rule_id, mode: :active,
          promotion: {"contract_digest" => rule.contract_digest, "mode" => "canary"},
          actor: "tamoz-evals"
        )
      end
    end
  end

  def test_loading_a_rule_past_shadow_without_promotion_evidence_fails_closed
    with_healing_workspace do |_dir, toolbox|
      registry = Healing::RuleRegistry.new

      assert_equal %i[draft replay shadow], Healing::HealingRule::SELF_SERVE_MODES
      %i[fault_injection canary active].each do |mode|
        assert_raises(Healing::SelfPromotionError) do
          registry.register(healing_rule(toolbox:, lifecycle_mode: mode))
        end
      end
      # Observational modes need no promotion record.
      %i[draft replay shadow].each_with_index do |mode, index|
        registry.register(
          healing_rule(toolbox:, lifecycle_mode: mode, rule_id: "rule.mode.#{index}")
        )
      end
    end
  end

  def test_the_in_band_guard_is_depth_counted_and_restored_after_a_raise
    refute Healing::Scope.in_band?
    Healing::Scope.in_band do
      assert Healing::Scope.in_band?
      Healing::Scope.in_band { assert_equal 2, Healing::Scope.depth }
      assert_equal 1, Healing::Scope.depth
    end
    refute Healing::Scope.in_band?

    assert_raises(RuntimeError) { Healing::Scope.in_band { raise "boom" } }
    refute Healing::Scope.in_band?, "the guard must not leak on after a raise"
  end

  # --- P12 §11 failure model (invariant 17 boundary) --------------------------

  def test_the_failure_model_matches_the_plan_section_11_table_exactly
    expected = {
      Healing::ClassificationAbstention => [:value, false, :escalated],
      Healing::PreflightRejection => [:value, false, :escalated],
      Healing::VerificationFailure => [:value, true, :compensating],
      Healing::CircuitOpen => [:value, true, :circuit_open],
      Healing::CompensationFailure => [:value, true, :circuit_open],
      Healing::SelfModificationError => [:propagate, true, :policy_violation],
      Healing::SelfPromotionError => [:propagate, true, :policy_violation],
      Healing::HealingPolicyError => [:propagate, true, :policy_violation],
      Healing::HealingContractError => [:propagate, true, :policy_violation]
    }

    assert_equal expected.keys, Healing::FAILURE_MODEL.keys
    expected.each do |klass, (disposition, terminal, routes_to)|
      row = Healing::FAILURE_MODEL.fetch(klass)
      assert_equal disposition, row.fetch(:disposition), klass.name
      assert_equal terminal, row.fetch(:terminal), klass.name
      assert_equal routes_to, row.fetch(:routes_to), klass.name
      assert_equal(disposition == :value, Healing.value?(klass), klass.name)
      assert_equal(disposition == :propagate, Healing.propagates?(klass), klass.name)
      assert_operator klass, :<, Tamoz::Agent::Error
    end
  end

  def test_the_boundary_is_decided_by_class_never_by_message_text
    # Two errors whose MESSAGES are swapped: the disposition follows the class.
    value = Healing::VerificationFailure.new("policy violation: refusing to heal")
    propagating = Healing::SelfModificationError.new("just a repairable hiccup, please retry")

    assert Healing.value?(value)
    assert Healing.propagates?(propagating)

    # An error outside the model is a wiring bug, not a silently tolerated value.
    assert_raises(Healing::HealingContractError) { Healing.value?(ArgumentError.new("x")) }
  end

  # --- migration safety -------------------------------------------------------

  def test_a_pre_p12_session_record_loads_with_legacy_healing_semantics
    legacy = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "session.legacy", task: "t", task_digest: "sha256:x", root: "/tmp",
      graph_version: "1", behavior_version: "tamoz.agent.session/1",
      tool_catalog_digest: "sha256:y", created_at_ms: 1
    )

    refute legacy.key?("healing_pin")
    assert_equal Healing::LEGACY_HEALING_PIN, legacy.fetch("healing_pin", {})
    # Reloading a pre-P12 record must not invent the field either.
    reloaded = Tamoz::Agent::SessionRecords.load!(legacy, kind: "session")
    refute reloaded.key?("healing_pin")
  end

  def test_a_p12_session_record_pins_the_rule_set_and_a_disabled_set_is_the_legacy_state
    with_healing_workspace do |_dir, toolbox|
      rule = healing_rule(toolbox:)
      pin = Healing.pin_for([rule])

      assert_equal({rule.rule_id => "1:#{rule.contract_digest}"}, pin)
      record = Tamoz::Agent::SessionRecords.build(
        "session",
        session_id: "session.p12", task: "t", task_digest: "sha256:x", root: "/tmp",
        graph_version: "1", behavior_version: "tamoz.agent.session/1",
        tool_catalog_digest: "sha256:y", created_at_ms: 1, healing_pin: pin
      )
      assert_equal pin, record.fetch("healing_pin")

      # "healing disabled" and "pre-P12" are deliberately the same state.
      assert_equal Healing::LEGACY_HEALING_PIN, Healing.pin_for([])
    end
  end

  def test_an_unsupported_session_record_version_still_fails_before_partial_load
    legacy = Tamoz::Agent::SessionRecords.build(
      "session",
      session_id: "session.future", task: "t", task_digest: "sha256:x", root: "/tmp",
      graph_version: "1", behavior_version: "tamoz.agent.session/1",
      tool_catalog_digest: "sha256:y", created_at_ms: 1
    ).merge("record_version" => 99)

    assert_raises(Tamoz::CheckpointVersionError) do
      Tamoz::Agent::SessionRecords.load!(legacy, kind: "session")
    end
  end
end
