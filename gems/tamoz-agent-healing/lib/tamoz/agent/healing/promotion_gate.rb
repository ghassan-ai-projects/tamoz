# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      # P12-H4 owns the promotion LIFECYCLE (replay → shadow → fault_injection →
      # canary → active, the evidence at each stage, and the durable promotion
      # record). This module owns only the PURE PREDICATES that P12-H1's
      # classification evidence decides, so H4 consumes them rather than
      # re-deriving abstention arithmetic.
      #
      # Nothing here writes a lifecycle mode. `RuleRegistry#write_lifecycle_mode`
      # is the only writer and it refuses in-band callers and unbacked promotions.
      module PromotionGate
        # P12 §3: "a rule with 100% abstention cannot be promoted to active."
        # Expressed as a hard floor rather than as a threshold to be tuned: a rule
        # that abstains on everything has demonstrated nothing.
        MAX_ABSTENTION_RATE = 1.0

        # Modes that require classification evidence at all. `draft`/`replay`/
        # `shadow` are observational.
        EVIDENCE_REQUIRED_MODES = %i[fault_injection canary active].freeze

        module_function

        # `matrix` is a `Classification::Matrix.run` report. Returns
        # [promotable_boolean, [reason, ...]] — reasons are STABLE ids, never
        # prose to be parsed.
        def evaluate(matrix, mode:)
          reasons = []
          return [true, reasons.freeze] unless EVIDENCE_REQUIRED_MODES.include?(mode.to_sym)

          denominator = matrix.fetch("denominator")
          reasons << :no_denominator if denominator.zero?
          if denominator.positive? && matrix.fetch("abstention_rate") >= MAX_ABSTENTION_RATE
            reasons << :total_abstention
          end
          if matrix.fetch("per_category").any? { |name, bucket|
               FailureRecord::NEVER_MUTATE_CATEGORIES.map(&:to_s).include?(name) &&
                 bucket.fetch("mutating").positive?
             }
            reasons << :never_mutate_class_reached_a_mutating_family
          end
          reasons << :negative_abstention_quality if
            matrix.fetch("abstention_quality").fetch("score").negative?

          [reasons.empty?, reasons.freeze]
        end

        def promotable?(matrix, mode:) = evaluate(matrix, mode:).first
      end
    end
  end
end
