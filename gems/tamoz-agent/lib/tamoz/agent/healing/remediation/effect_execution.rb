# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Describes, dispatches, and verifies one remediation effect through the
        # existing effect journal. It does not own retry or terminal-state policy.
        # :reek:ManualDispatch — executor callability is an explicit contract guard.
        # :reek:MissingSafeMethod — invalid execution inputs must fail closed.
        # :reek:InstanceVariableAssumption — keyword capture initializes the effect boundary.
        # :reek:TooManyInstanceVariables — these are the immutable effect boundary.
        class EffectExecution
          def initialize(**arguments)
            arguments.each { |name, value| instance_variable_set(:"@#{name}", value) }
          end

          def identity(classification)
            EffectIdentity.describe(
              original_trace_id: @original_trace_id,
              original_effect_id: @original_effect_id,
              rule_id: @rule.rule_id,
              rule_version: @rule.version,
              remediation_step: classification.action_family.to_s
            )
          end

          # The yield occurs at the original @performed assignment point: after
          # validation and step lookup, immediately before journal dispatch.
          def call(identity)
            validate!
            step = @rule.remediation_steps.first
            yield
            EffectDispatcher.run(
              context: @context,
              operation: identity.fetch('operation'),
              safety: step.fetch('safety').to_sym,
              call_index: @call_index,
              request: request(step),
              actor: @actor,
              reconcile: @reconcile
            ) { @perform.call }
          end

          # Invariant 33. The only verification producer consumed by Session's
          # recovered branch.
          def verify = Oracle.verify(rule: @rule, toolbox: @toolbox)

          private

          def validate!
            raise HealingContractError, 'a mutating remediation requires an executor' unless @perform.respond_to?(:call)
            return if @context

            raise HealingContractError,
                  'a mutating remediation requires a graph Context bound to an ' \
                  'effect journal (design §7)'
          end

          def request(step)
            {
              'rule_id' => @rule.rule_id,
              'rule_version' => @rule.version,
              'form' => step.fetch('form'),
              'failure_fingerprint' => @record.fingerprint
            }
          end
        end
      end
    end
  end
end
