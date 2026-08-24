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
          return [true, [].freeze] unless EVIDENCE_REQUIRED_MODES.include?(mode.to_sym)

          reasons = collect_reasons(matrix)
          [reasons.empty?, reasons.freeze]
        end

        def promotable?(matrix, mode:) = evaluate(matrix, mode:).first

        def collect_reasons(matrix)
          reasons = []
          denominator = matrix.fetch("denominator")
          reasons << :no_denominator if denominator.zero?
          reasons << :total_abstention if total_abstention?(matrix, denominator)
          reasons << :never_mutate_class_reached_a_mutating_family if never_mutate_violation?(matrix)
          reasons << :negative_abstention_quality if matrix.fetch("abstention_quality").fetch("score").negative?
          reasons
        end
        private_class_method :collect_reasons

        def total_abstention?(matrix, denominator)
          denominator.positive? && matrix.fetch("abstention_rate") >= MAX_ABSTENTION_RATE
        end
        private_class_method :total_abstention?

        def never_mutate_violation?(matrix)
          matrix.fetch("per_category").any? do |name, bucket|
            FailureRecord::NEVER_MUTATE_CATEGORIES.map(&:to_s).include?(name) &&
              bucket.fetch("mutating").positive?
          end
        end
        private_class_method :never_mutate_violation?
      end
    end
  end
end
