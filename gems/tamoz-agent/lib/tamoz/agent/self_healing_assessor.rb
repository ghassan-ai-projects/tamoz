# frozen_string_literal: true

module Tamoz
  module Agent
    # ADR-028 shadow stage, wired live. When a turn's bounded repair loop gives
    # up on a typed failure, the assessor asks the healing vertical — read-only,
    # executing nothing — "is this a known, remediable failure, and which rule
    # would own it?" and returns a typed verdict.
    #
    # This is the first stage a healing rule passes through before it earns the
    # authority to act (replay → shadow → fault-injection → canary → active). It
    # is safe by construction: it runs classification only, never a plan, effect,
    # or verification, so it can be on by default with an empty rule set — an
    # empty set simply reports every failure as "escalate", with its typed
    # category, instead of the runtime's opaque failure reason.
    class SelfHealingAssessor
      # error class → healing category, keyed by the class's short name so both the
      # fully-qualified spelling (real tool errors) and the bare one (denials) map.
      TOOL_ERROR_CATEGORY = {
        "ToolPolicyError" => :policy_denied,
        "ToolArgumentError" => :malformed_recoverable_output,
        "ModelCallError" => :dependency_unavailable
      }.freeze

      # A ToolError whose reason points at a moved/stale target is a stale
      # precondition (a remediable class); anything else is left unclassified.
      STALE_HINTS = ["expected_sha256", "file changed", "stale", "no longer"].freeze

      Assessment = Data.define(
        :remediable, :route, :category, :action_family, :rule_id, :never_mutate_class, :fingerprint, :confidence
      ) do
        def to_h
          {
            "remediable" => remediable,
            "route" => route.to_s,
            "category" => category.to_s,
            "action_family" => action_family&.to_s,
            "rule_id" => rule_id,
            "never_mutate_class" => never_mutate_class&.to_s,
            "failure_fingerprint" => fingerprint,
            "confidence" => confidence
          }
        end
      end

      def initialize(rules:, behavior_version: Tamoz::Agent::BEHAVIOR_VERSION, policy_version: "policy/active")
        @rules = rules
        @behavior_version = String(behavior_version)
        @policy_version = String(policy_version)
      end

      # `tool_failure` is the runtime's typed failure hash (see StepExecution).
      def assess_tool_failure(tool_failure)
        tool = tool_failure["tool"]
        assess(build_record(
          failure_code: "tool.#{tool || "unknown"}",
          category: tool_failure_category(tool_failure),
          operation: "tool.#{tool || "unknown"}",
          tool:, effect_state: :not_attempted
        ))
      end

      def assess_check_failure(check_receipt)
        assess(build_record(
          failure_code: "check.#{check_receipt.name}",
          category: :verification_failed,
          operation: "check.#{check_receipt.name}",
          tool: nil, effect_state: :completed
        ))
      end

      private

      def assess(record)
        rule = match_rule(record)
        unless rule
          return Assessment.new(
            remediable: false, route: :escalated, category: record.category, action_family: nil,
            rule_id: nil, never_mutate_class: record.never_mutate_class, fingerprint: record.fingerprint,
            confidence: nil
          )
        end

        decision = Healing::Classification.classify(record, rule:)
        Assessment.new(
          remediable: decision.route == :remediate,
          route: decision.route, category: record.category, action_family: decision.action_family,
          rule_id: rule.rule_id, never_mutate_class: record.never_mutate_class,
          fingerprint: record.fingerprint, confidence: decision.confidence
        )
      end

      def match_rule(record)
        signal = record.typed_signal
        @rules.rule_ids.filter_map { |id| @rules.fetch(id) }.find { |rule| rule.triggers?(signal) }
      end

      def tool_failure_category(tool_failure)
        short_name = tool_failure["error_class"].to_s.split("::").last.to_s
        return TOOL_ERROR_CATEGORY.fetch(short_name) if TOOL_ERROR_CATEGORY.key?(short_name)
        return :stale_precondition if stale?(tool_failure["reason"].to_s)

        :unknown
      end

      def stale?(reason)
        downcased = reason.downcase
        STALE_HINTS.any? { |hint| downcased.include?(hint) }
      end

      def build_record(failure_code:, category:, operation:, tool:, effect_state:)
        Healing::FailureRecord.new(
          failure_code:, category:, operation:, tool:, effect_state:,
          policy_version: @policy_version, behavior_version: @behavior_version, observed_at_ms: 0
        )
      end
    end
  end
end
