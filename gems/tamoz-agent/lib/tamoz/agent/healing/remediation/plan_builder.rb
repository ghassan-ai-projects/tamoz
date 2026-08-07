# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Builds the deterministic, immutable plan reviewed before remediation.
        # :reek:LongParameterList — these five inputs are the plan's fixed source
        # material; an options hash would hide the invariant-bearing contract.
        # :reek:TooManyInstanceVariables — the builder retains only that source
        # material for one call and is never reused.
        # :reek:FeatureEnvy — validation necessarily examines each plan input.
        # :reek:ManualDispatch — empty strings and collections are both refused,
        # while typed non-collection values remain valid inputs.
        # :reek:MissingSafeMethod — invalid plans must raise the existing contract
        # error; a predicate twin would allow callers to ignore the refusal.
        # :reek:NilCheck — nil is the explicit absent-input representation.
        class PlanBuilder
          def initialize(record:, rule:, original_invariant:, minimal_change:, stop_conditions:)
            @record = record
            @rule = rule
            @original_invariant = original_invariant
            @minimal_change = minimal_change
            @stop_conditions = stop_conditions
          end

          # Invariants 25–27. A missing element is a contract error, not a
          # silently defaulted plan.
          def call(classification)
            validate_inputs!
            unless @rule.plan_review_policy.fetch('plan_required') == true
              raise HealingContractError, "rule #{@rule.rule_id} does not require a plan"
            end

            Tamoz::Core.deep_freeze(plan(classification))
          end

          private

          def validate_inputs!
            %i[original_invariant minimal_change stop_conditions].each do |name|
              value = instance_variable_get(:"@#{name}")
              next unless value.nil? || (value.respond_to?(:empty?) && value.empty?)

              raise HealingContractError,
                    "a remediation plan must name #{name} (invariant 25)"
            end
          end

          def plan(classification)
            {
              'original_invariant' => @original_invariant,
              'minimal_change' => @minimal_change,
              'effect_class' => @rule.effect_class.to_s,
              'authorization' => authorization,
              'verification' => @rule.verification_oracle,
              'compensation' => @rule.compensation,
              'stop_conditions' => Array(@stop_conditions),
              'form' => classification.action_family.to_s,
              'failure_fingerprint' => @record.fingerprint,
              'budgets' => @rule.budgets
            }
          end

          def authorization
            {
              'rule_id' => @rule.rule_id,
              'rule_version' => @rule.version,
              'rule_digest' => @rule.digest,
              'authorized_scopes' => @rule.authorized_scopes,
              'authorized_resources' => @rule.authorized_resources,
              'original_operation_authorized' =>
                @record.trusted_context['original_operation_authorized'] == true
            }
          end
        end
      end
    end
  end
end
