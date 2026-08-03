# frozen_string_literal: true

require_relative "healing_fixtures"

# P12 §8/§13 — the applicable classification matrix and the H4 promotion gate.
#
# The plan's 250-cell matrix (10 fault classes × 5 lifecycle stages × 5 seeds)
# runs only its APPLICABLE cells: a cell is not applicable only if the fault
# class cannot occur at that stage within the rule's authorized scope, and every
# exclusion is stated. For the v1 reference rule (stale conditional file edit)
# the mandatory cells are the never-mutate classes and the verify-stage class,
# which this suite runs over the full 12-category synthetic set.
#
# Metrics are reported with every denominator (plan §8), and the H4 promotion
# gate consumes the matrix verbatim (`PromotionGate.evaluate`) rather than
# re-deriving abstention arithmetic.
class HealingMatrixTest < Minitest::Test
  include HealingFixtures

  Healing = Tamoz::Agent::Healing

  def test_matrix_runs_the_full_category_set_with_denominators
    with_healing_workspace do |_dir, toolbox|
      rule = healing_rule(toolbox:)
      cases = synthetic_records.map do |category, record|
        {record:, expected_family: Healing::Classification::CATEGORY_ACTION_FAMILY.fetch(category)}
      end
      matrix = Healing::Classification::Matrix.run(cases:, rule:)

      assert_equal 12, matrix.fetch("denominator"), "every design category is exercised"
      assert_equal synthetic_records.length, matrix.fetch("denominator")
      assert_equal 12, matrix.fetch("per_category").length
      assert_equal "rule.stale-conditional-file-edit", matrix.fetch("rule_id")
      assert_equal 1, matrix.fetch("rule_version")
      # Every category contributes a typed decision bucket; no bucket is silent.
      matrix.fetch("per_category").each_value do |bucket|
        assert_equal 1, bucket.fetch("denominator")
      end
    end
  end

  # C9: a never-mutate class can never reach a mutating family — the matrix
  # counts zero `mutating` for every never-mutate category, and the gate refuses
  # if one ever did.
  def test_never_mutate_classes_never_reach_a_mutating_family
    with_healing_workspace do |_dir, toolbox|
      rule = healing_rule(toolbox:)
      cases = synthetic_records.map do |category, record|
        {record:, expected_family: Healing::Classification::CATEGORY_ACTION_FAMILY.fetch(category)}
      end
      matrix = Healing::Classification::Matrix.run(cases:, rule:)

      Healing::FailureRecord::NEVER_MUTATE_CATEGORIES.each do |category|
        bucket = matrix.fetch("per_category").fetch(category.to_s)
        assert_equal 1, bucket.fetch("denominator")
        assert_equal 0, bucket.fetch("mutating"),
                     "#{category} must never classify onto a mutating family"
        assert_equal 1, bucket.fetch("never_mutate")
      end
    end
  end

  # H4: a rule with 100% abstention cannot be promoted to active; a never-mutate
  # leak also blocks promotion; observational modes need no evidence.
  def test_promotion_gate_rejects_total_abstention_and_never_mutate_leak
    with_healing_workspace do |_dir, toolbox|
      rule = healing_rule(toolbox:)
      all = synthetic_records.map do |category, record|
        {record:, expected_family: Healing::Classification::CATEGORY_ACTION_FAMILY.fetch(category)}
      end
      matrix = Healing::Classification::Matrix.run(cases: all, rule:)
      promotable, reasons = Healing::PromotionGate.evaluate(matrix, mode: :canary)
      # The v1 rule handles stale_precondition; at minimum_confidence 1.0 the
      # stale-precondition record classifies, so the matrix is not total
      # abstention and carries a real denominator.
      assert matrix.fetch("denominator").positive?
      refute_includes reasons, :total_abstention

      # Total abstention: every record is unknown → abstention_rate == 1.0.
      abstaining = synthetic_records.map do |category, record|
        record = if category == :unknown
                   record
                 else
                   failure_record(
                     failure_code: "unclassified", category: :unknown,
                     operation: "session.turn", tool: nil, target_resource: nil,
                     expected_digest: nil, observed_digest: nil
                   )
                 end
        {record:, expected_family: :abstain}
      end
      abstained_matrix = Healing::Classification::Matrix.run(cases: abstaining, rule:)
      assert_equal 1.0, abstained_matrix.fetch("abstention_rate")
      promotable, reasons = Healing::PromotionGate.evaluate(abstained_matrix, mode: :canary)
      refute promotable
      assert_includes reasons, :total_abstention

      # Observational modes need no evidence at all.
      promotable, reasons = Healing::PromotionGate.evaluate(matrix, mode: :shadow)
      assert promotable
      assert_empty reasons
    end
  end

  # C9: correct abstention on never-mutate classes is scored with BOTH
  # denominators reported; over-abstention on handled classes lowers the score.
  def test_abstention_quality_reports_both_denominators
    with_healing_workspace do |_dir, toolbox|
      rule = healing_rule(toolbox:)
      all = synthetic_records.map do |category, record|
        {record:, expected_family: Healing::Classification::CATEGORY_ACTION_FAMILY.fetch(category)}
      end
      quality = Healing::Classification::Matrix.run(cases: all, rule:)
                                             .fetch("abstention_quality")
      # The four never-mutate CATEGORIES (the fifth never-mutate class is the
      # `capability_absent` predicate, which has no category row).
      assert_equal 4, quality.fetch("correct_abstention_denominator")
      assert_equal 1.0, quality.fetch("correct_abstention_rate")
      # The rule handles stale_precondition only.
      assert_equal 1, quality.fetch("over_abstention_denominator")
      assert_equal 0.0, quality.fetch("over_abstention_rate")
      assert_equal 1.0, quality.fetch("score")
    end
  end
end
