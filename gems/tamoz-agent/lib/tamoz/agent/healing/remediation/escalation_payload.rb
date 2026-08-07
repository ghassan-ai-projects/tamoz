# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Renders the stable design §10 issue contract for a terminal attempt.
        # Keeping this pure makes payload compatibility review independent from
        # Session's state-machine orchestration.
        # :reek:FeatureEnvy — the renderer intentionally reads its two domain records.
        # :reek:TooManyInstanceVariables — fields mirror the stable escalation schema.
        class EscalationPayload
          def initialize(record:, rule:, attempt:, transitions:, digests:)
            @record = record
            @rule = rule
            @attempt = attempt
            @transitions = transitions
            @plan_digest = digests.fetch(:plan)
            @review_digest = digests.fetch(:review)
          end

          def call(terminal)
            failure_fields
              .merge(rule_fields)
              .merge(decision_fields(terminal))
              .merge(effect_fields(terminal))
          end

          private

          def failure_fields
            {
              'failure_fingerprint' => @record.fingerprint,
              'failure_digest' => @record.digest,
              'failure_category' => @record.category.to_s,
              'never_mutate_class' => @record.never_mutate_class&.to_s
            }
          end

          def rule_fields
            {
              'rule_id' => @rule.rule_id,
              'rule_version' => @rule.version,
              'rule_digest' => @rule.digest,
              'lifecycle_mode' => @rule.lifecycle_mode.to_s,
              'attempts' => @attempt
            }
          end

          def decision_fields(terminal)
            {
              'terminal_state' => terminal.fetch(:state).to_s,
              'classification' => terminal.fetch(:classification)&.to_h,
              'plan_digest' => @plan_digest,
              'review_digest' => @review_digest,
              'preflight_precondition' =>
                terminal.fetch(:preflight_rejection)&.precondition&.to_s,
              'verification' => terminal.fetch(:verification)&.to_h,
              'compensation' => terminal.fetch(:compensation)
            }
          end

          def effect_fields(terminal)
            {
              'containment' => @rule.compensation,
              'effect_identity' => terminal.fetch(:effect_identity),
              'before_digest' => @record.expected_digest,
              'after_digest' => @record.observed_digest,
              'failure_type' => terminal.fetch(:failure)&.class&.name,
              'transitions' => @transitions.dup,
              'recommended_next_action' =>
                @rule.escalation_contract['recommended_next_action']
            }
          end
        end
      end
    end
  end
end
