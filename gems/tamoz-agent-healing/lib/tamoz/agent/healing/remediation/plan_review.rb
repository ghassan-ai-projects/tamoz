# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Validates and normalizes the semantic critic's decision about one
        # remediation plan. This keeps model output outside Session until it has
        # satisfied invariant 26's typed review contract.
        # :reek:FeatureEnvy — this boundary necessarily inspects untrusted review data.
        # :reek:ManualDispatch — callability is part of the existing critic contract.
        # :reek:MissingSafeMethod — every validator is a fail-fast contract guard;
        # predicate twins would let callers bypass the refusal.
        # :reek:TooManyStatements — call spells out the contract's required error order.
        class PlanReview
          DECISIONS = %w[accept revise needs_input].freeze

          def initialize(rule:, critic:)
            @rule = rule
            @critic = critic
          end

          def call(plan)
            validate_policy!
            validate_critic!
            review = @critic.call(plan)
            validate_shape!(review)
            validate_decision!(review)
            validate_issues!(review)
            normalize(review)
          end

          private

          def validate_policy!
            return if @rule.plan_review_policy.fetch('semantic_critic_required') == true

            raise HealingContractError,
                  "rule #{@rule.rule_id} does not require a semantic critic review " \
                  '(invariant 26)'
          end

          def validate_critic!
            return if @critic.respond_to?(:call)

            raise HealingContractError, 'a semantic critic review is required'
          end

          def validate_shape!(review)
            return if review.is_a?(Hash) && review.key?('decision') && review.key?('issues')

            raise HealingContractError,
                  'the semantic critic must return decision and issues'
          end

          def validate_decision!(review)
            return if DECISIONS.include?(String(review.fetch('decision')))

            raise HealingContractError,
                  'the semantic critic decision must be accept, revise, or needs_input'
          end

          def validate_issues!(review)
            return if review.fetch('decision') == 'accept'
            return unless Array(review.fetch('issues')).empty?

            raise HealingContractError,
                  'a non-accepting semantic critic review must name issues'
          end

          def normalize(review)
            Tamoz::Core.deep_freeze(
              {
                'decision' => String(review.fetch('decision')),
                'issues' => Array(review.fetch('issues')).map(&:to_s),
                'rationale' => String(review['rationale'].to_s)
              }
            )
          end
        end
      end
    end
  end
end
