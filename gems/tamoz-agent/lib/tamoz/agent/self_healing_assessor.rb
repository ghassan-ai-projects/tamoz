# frozen_string_literal: true

module Tamoz
  module Agent
    # ADR-028 shadow stage: classify a failed turn's typed failure against the
    # staged rules, read-only. Runs no plan, effect, or verification, so it is safe
    # on by default; an empty rule set reports the typed category and escalates.
    class SelfHealingAssessor
      # Keyed by short name so both the fully-qualified spelling (tool errors) and
      # the bare one (denials) map.
      TOOL_ERROR_CATEGORY = {
        "ToolPolicyError" => :policy_denied,
        "ToolArgumentError" => :malformed_recoverable_output,
        "ModelCallError" => :dependency_unavailable
      }.freeze

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
        assess_failed_check(name: check_receipt.name)
      end

      def assess_failed_check(name:)
        assess(build_record(
          failure_code: "check.#{name}", category: :verification_failed,
          operation: "check.#{name}", tool: nil, effect_state: :completed
        ))
      end

      # Classify the last typed failure in a durable turn's observation list
      # (`view.state[:observations]`), or nil when there is none.
      def assess_observations(observations)
        entries = Array(observations).select { |entry| entry.is_a?(Hash) }
        failure = entries.reverse.find { |entry| entry["failure"] }
        return assess_tool_failure(failure.fetch("failure")) if failure

        check = entries.reverse.find { |entry| entry["check"].is_a?(Hash) && entry["check"]["passed"] == false }
        return assess_failed_check(name: check.fetch("check").fetch("name")) if check

        nil
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
