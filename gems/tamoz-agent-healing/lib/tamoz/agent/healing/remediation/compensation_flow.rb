# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Applies the rule's compensation and decides the resulting terminal
        # failure. Session remains responsible for state transitions and output.
        class CompensationFlow
          # The typed handoff keeps terminal state, receipt, and failure inseparable.
          Result = Data.define(:state, :receipt, :failure)

          def initialize(rule:, record:, compensation:, circuit:)
            @rule = rule
            @record = record
            @compensation = compensation
            @circuit = circuit
          end

          def call(classification:, effect_identity:, verification:)
            receipt = @compensation.compensate(
              rule: @rule, record: @record, classification:, effect_identity:
            )
            assert_status!(receipt)
            return failed(receipt) if receipt.fetch('status') == 'failed'

            Result.new(state: :escalated, receipt:, failure: escalation_failure(verification))
          end

          private

          def assert_status!(receipt)
            return if receipt.is_a?(Hash) && receipt.key?('status')

            raise HealingContractError, 'a compensation must return a status'
          end

          def escalation_failure(verification)
            VerificationFailure.new(
              'verification did not pass; the attempt is escalated, not recovered',
              oracle: @rule.verification_oracle.fetch('check_name'),
              receipt_outcome: verification.outcome, reason: verification.reason
            )
          end

          def failed(receipt)
            # Design §9: "Failure to compensate opens the circuit."
            @circuit.record_failure(
              kind: :compensation_failed,
              context: { 'rule' => @rule.rule_id }
            )
            failure = CompensationFailure.new(
              'compensation failed; the circuit is open', receipt:
            )
            Result.new(state: :circuit_open, receipt:, failure:)
          end
        end
      end
    end
  end
end
