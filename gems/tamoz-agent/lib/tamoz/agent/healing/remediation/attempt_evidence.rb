# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Owns the ordered evidence ledger and the canonical digests recorded in
        # it. Session decides when transitions occur; this object fixes their wire
        # representation.
        # :reek:ManualDispatch — an optional execution_id is the fence contract.
        # :reek:InstanceVariableAssumption — keyword capture initializes the fixed schema.
        # :reek:LongParameterList — record receives the four changing transition fields.
        # :reek:TooManyInstanceVariables — fields mirror the transition schema.
        # :reek:UtilityFunction — canonical evidence digests share this wire-format owner.
        class AttemptEvidence
          attr_reader :transitions

          def initialize(**arguments)
            arguments.each { |name, value| instance_variable_set(:"@#{name}", value) }
            @transitions = []
          end

          def digest(value, label)
            canonical = JSON.generate(Tamoz::Core.canonical(value))
            body = "tamoz.agent.healing.#{label}.v1\n#{canonical}"
            "sha256:#{Digest::SHA256.hexdigest(body)}"
          end

          def record(state, plan_digest:, review_digest:, evidence:)
            @transitions << {
              'state' => state.to_s,
              'failure_format_version' => @record.format_version,
              'failure_fingerprint' => @record.fingerprint,
              'rule_id' => @rule.rule_id,
              'rule_version' => @rule.version,
              'plan_digest' => plan_digest,
              'review_digest' => review_digest,
              'trace_id' => @original_trace_id,
              'effect_id' => @original_effect_id,
              'attempt' => @attempt,
              'actor' => @actor,
              'fence' => fence,
              'at' => @clock.call,
              'evidence' => evidence,
              'budgets' => @rule.budgets
            }.freeze
          end

          private

          def fence
            @context.respond_to?(:execution_id) ? @context.execution_id : nil
          end
        end
      end
    end
  end
end
