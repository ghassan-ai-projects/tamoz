# frozen_string_literal: true

require_relative "test_helper"

# The live ADR-028 shadow stage: classify a failed turn's typed failure against
# the operator's staged rules, read-only, executing nothing.
class SelfHealingAssessorTest < Minitest::Test
  Assessor = Tamoz::Agent::SelfHealingAssessor
  Healing = Tamoz::Agent::Healing

  def rule_on(category, family: "refresh_recompute", min_confidence: 1.0)
    Healing::HealingRule.new(
      rule_id: "rule.#{category}", version: 1, owner: "human:owner", lifecycle_mode: :shadow,
      trigger: {"categories" => [category.to_s]},
      minimum_confidence: min_confidence, risk_class: :low, effect_class: :reconcilable,
      authorized_scopes: ["workspace"], authorized_resources: ["a.rb"],
      plan_review_policy: {"plan_required" => true, "semantic_critic_required" => true, "human_approval_required" => true},
      preconditions: Healing::Preflight::CHECK_IDS.map(&:to_s),
      remediation_steps: [{"form" => family, "safety" => "reconcilable", "creates" => false}],
      effect_identity: {"domain" => Healing::EffectIdentity::DOMAIN},
      budgets: {"max_attempts" => 2, "max_magnitude" => 1.0, "max_cost" => 1.0, "max_seconds" => 30.0},
      verification_oracle: {"kind" => "configured_check", "check_name" => "a", "digest" => "sha256:#{"c" * 64}"},
      compensation: {"kind" => "restore_preimage"},
      circuit_conditions: %w[verification_failed_twice], reset_authority: "human:owner",
      escalation_contract: {"sink" => "tamoz.escalations", "recommended_next_action" => "re-read"},
      eval_suite: "tamoz.evals.healing.x", created_at_ms: 1_700_000_000_000
    )
  end

  def registry_with(*rules)
    registry = Healing::RuleRegistry.new
    rules.each { |rule| registry.register(rule) }
    registry
  end

  def tool_failure(error_class:, tool: "apply_patch", reason: "boom")
    {"kind" => "tool_error", "tool" => tool, "error_class" => error_class,
     "reason" => reason, "failure_signature" => "sig"}
  end

  def check_failure(name: "values")
    Tamoz::Tools::CheckReceipt.new(name:, outcome: "exit_1", stdout: "", stderr: "nope")
  end

  # No staged rule (the default): the failure is still typed, and the verdict is
  # a clear escalate — strictly more information than an opaque failure reason.
  def test_no_rule_types_the_failure_and_escalates
    verdict = Assessor.new(rules: Healing::RuleRegistry.new).assess_check_failure(check_failure)
    refute verdict.remediable
    assert_equal :escalated, verdict.route
    assert_equal :verification_failed, verdict.category
    assert_nil verdict.rule_id
  end

  # A never-mutate class is named as such and can never be remediable.
  def test_policy_denied_is_never_mutate
    verdict = Assessor.new(rules: Healing::RuleRegistry.new)
                      .assess_tool_failure(tool_failure(error_class: "Tamoz::Agent::ToolPolicyError"))
    refute verdict.remediable
    assert_equal :policy_denied, verdict.category
    assert_equal :policy_denied, verdict.never_mutate_class
  end

  # The payoff: a recoverable failure with a matching staged rule is reported as
  # remediable, with the rule and the action family that would own it.
  def test_matching_rule_reports_remediable
    verdict = Assessor.new(rules: registry_with(rule_on(:malformed_recoverable_output)))
                      .assess_tool_failure(tool_failure(error_class: "Tamoz::Agent::ToolArgumentError"))
    assert verdict.remediable
    assert_equal :remediate, verdict.route
    assert_equal :malformed_recoverable_output, verdict.category
    assert_equal :refresh_recompute, verdict.action_family
    assert_equal "rule.malformed_recoverable_output", verdict.rule_id
  end

  # The durable path (worker/session, which Telegram rides) hands the assessor the
  # turn's observation list. It classifies the last typed failure in it.
  def test_assess_observations_reads_a_tool_failure
    obs = [
      {"tool" => "read_file", "output" => "ok"},
      {"tool" => "apply_patch", "failure" => {"tool" => "apply_patch",
                                              "error_class" => "Tamoz::Agent::ToolArgumentError", "reason" => "bad"}}
    ]
    verdict = Assessor.new(rules: registry_with(rule_on(:malformed_recoverable_output)))
                      .assess_observations(obs)
    assert verdict.remediable
    assert_equal :malformed_recoverable_output, verdict.category
  end

  def test_assess_observations_reads_a_failed_check
    obs = [{"tool" => "run_check", "check" => {"name" => "values", "outcome" => "exit_1", "passed" => false}}]
    verdict = Assessor.new(rules: Healing::RuleRegistry.new).assess_observations(obs)
    assert_equal :verification_failed, verdict.category
    assert_equal :escalated, verdict.route
  end

  def test_assess_observations_returns_nil_without_a_typed_failure
    assert_nil Assessor.new(rules: Healing::RuleRegistry.new)
                       .assess_observations([{"tool" => "read_file", "output" => "fine"}])
  end

  # A generic ToolError whose reason points at a moved target is a stale
  # precondition — a recoverable class — not an opaque unknown.
  def test_stale_hint_maps_to_stale_precondition
    verdict = Assessor.new(rules: Healing::RuleRegistry.new)
                      .assess_tool_failure(tool_failure(error_class: "Tamoz::Agent::ToolError",
                                                        reason: "expected_sha256 did not match; file changed"))
    assert_equal :stale_precondition, verdict.category
  end
end
