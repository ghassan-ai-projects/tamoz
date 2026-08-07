# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Immutable terminal result of one remediation attempt.
        # :reek:NilCheck — an absent verification is a deliberate non-recovered
        # state; the predicate must never send `passed` to nil.
        Outcome = Data.define(
          :state, :classification, :failure, :plan, :plan_digest, :review,
          :review_digest, :preflight_rejection, :effect_identity, :effect_outcome,
          :verification, :compensation, :escalation_id, :transitions, :attempt,
          :performed
        ) do
          def recovered? = state == :recovered
          def terminal? = TERMINAL_STATES.include?(state)

          # Invariant 33, restated as a predicate an auditor can call: a recovered
          # outcome ALWAYS carries a passing oracle result.
          def oracle_backed?
            !verification.nil? && verification.passed == true
          end
        end
      end
    end
  end
end
