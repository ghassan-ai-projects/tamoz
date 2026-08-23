# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      # P12 §11 (C8) — the failure model, encoded in TYPES.
      #
      # Invariant 17 is the boundary: planner-repairable conditions become typed
      # RESULT VALUES that the remediation protocol RETURNS inside its outcome;
      # policy violations and integrity breaks PROPAGATE as exceptions. Every
      # class below is a `Tamoz::Agent::Error` descendant (so a caller that
      # rescues the agent surface still sees one family) but only the ones marked
      # `disposition: :propagate` are ever raised out of `Remediation.run`.
      #
      # Nothing in this file is decided by string matching. `FAILURE_MODEL` is the
      # single source of truth and `test/healing_failure_contract_test.rb` asserts
      # it row-for-row against the plan §11 table.
      class HealingError < Error; end

      # --- typed RESULT VALUES (invariant 17: repairable -> value) -------------

      # A classifier that cannot reach the rule's `minimum_confidence` gate, or a
      # failure whose typed evidence does not identify a category, abstains.
      # Design §2: abstention routes to `escalated`. Never raised.
      class ClassificationAbstention < HealingError
        attr_reader :category, :confidence, :reason

        def initialize(message, category: nil, confidence: nil, reason: nil)
          @category = category
          @confidence = confidence
          @reason = reason
          super(message)
        end
      end

      # A design §5 precondition did not hold. Carries the STABLE id of the first
      # failed check so the escalation names it without parsing prose.
      class PreflightRejection < HealingError
        attr_reader :precondition, :detail

        def initialize(message, precondition:, detail: nil)
          @precondition = precondition
          @detail = detail
          super(message)
        end
      end

      # The rule-supplied oracle did not record a pass. Terminal for the attempt:
      # the outcome can never be `recovered` (invariant 33).
      class VerificationFailure < HealingError
        attr_reader :oracle, :receipt_outcome, :reason

        def initialize(message, oracle: nil, receipt_outcome: nil, reason: nil)
          @oracle = oracle
          @receipt_outcome = receipt_outcome
          @reason = reason
          super(message)
        end
      end

      # The rule/target circuit is open. Every mutating call fails typed; only
      # safe observation, reconciliation, and notification remain (design §10).
      class CircuitOpen < HealingError
        attr_reader :scope, :evidence

        def initialize(message, scope: nil, evidence: nil)
          @scope = scope
          @evidence = evidence
          super(message)
        end
      end

      # Compensation itself failed (design §9). Opens the circuit; the escalation
      # record marks it. Never concealed as a success.
      class CompensationFailure < HealingError
        attr_reader :receipt

        def initialize(message, receipt: nil)
          @receipt = receipt
          super(message)
        end
      end

      # --- PROPAGATING policy violations (invariant 17/34) ---------------------

      # A rule attempted to change its own matcher, oracle, budgets, authority, or
      # circuit (invariant 34). This is a policy violation, not a repairable input:
      # it propagates out of whatever called it.
      class SelfModificationError < HealingError; end

      # A lifecycle-mode write or circuit reset was attempted from inside a rule or
      # session rather than by `tamoz-evals` with digest-bound evidence.
      class SelfPromotionError < HealingError; end

      # A record or rule violates its own contract (bad field, out-of-range budget,
      # unknown remediation form). Construction-time integrity break; propagates.
      class HealingPolicyError < HealingError; end

      # The caller wired the protocol wrongly (missing oracle, missing reconciler
      # for a reconcilable effect). A programmer error; propagates.
      class HealingContractError < HealingError; end

      # P12 §11, verbatim. `disposition` decides raise-vs-return, `terminal` says
      # whether the ATTEMPT ends, `routes_to` is the §2 state-machine successor.
      FAILURE_MODEL = {
        ClassificationAbstention => {
          disposition: :value, terminal: false, routes_to: :escalated
        },
        PreflightRejection => {
          disposition: :value, terminal: false, routes_to: :escalated
        },
        VerificationFailure => {
          disposition: :value, terminal: true, routes_to: :compensating
        },
        CircuitOpen => {
          disposition: :value, terminal: true, routes_to: :circuit_open
        },
        CompensationFailure => {
          disposition: :value, terminal: true, routes_to: :circuit_open
        },
        SelfModificationError => {
          disposition: :propagate, terminal: true, routes_to: :policy_violation
        },
        SelfPromotionError => {
          disposition: :propagate, terminal: true, routes_to: :policy_violation
        },
        HealingPolicyError => {
          disposition: :propagate, terminal: true, routes_to: :policy_violation
        },
        HealingContractError => {
          disposition: :propagate, terminal: true, routes_to: :policy_violation
        }
      }.freeze

      module_function

      # True when the typed failure is returned as a value rather than raised.
      # Decided from the CLASS, never from the message (plan §3: free-form text is
      # never a control signal).
      def value?(error)
        row = FAILURE_MODEL.fetch(error.is_a?(Class) ? error : error.class) do
          raise HealingContractError,
                "#{error.inspect} is not in the P12 §11 failure model"
        end
        row.fetch(:disposition) == :value
      end

      def propagates?(error) = !value?(error)

      def routes_to(error)
        FAILURE_MODEL.fetch(error.is_a?(Class) ? error : error.class) do
          raise HealingContractError,
                "#{error.inspect} is not in the P12 §11 failure model"
        end.fetch(:routes_to)
      end
    end
  end
end
