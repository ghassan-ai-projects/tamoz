# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    module Healing
      # P12 §3 (P12-H1) — classification and abstention.
      #
      # The classifier is a PURE FUNCTION of `FailureRecord#typed_signal`. It never
      # sees the untrusted provider message (the record does not even hold it), so
      # "free-form text is never the sole mutation trigger" is a structural
      # property, not a review promise.
      module Classification
        # Design §6 permitted remediation forms, least to most consequential, with
        # their design ordinal. The set is CLOSED: a rule naming anything else is
        # rejected at construction.
        PERMITTED_FORMS = {
          refresh_recompute: 1,   # refresh state and recompute the same minimal read/action
          bounded_retry: 2,       # bounded retry after proven pre-dispatch transient failure
          reacquire_lease: 3,     # renew/reacquire a lease before new work
          rebuild_derived: 4,     # rebuild a derived cache/index from an authoritative source
          restore_preimage: 5,    # restore reversible local state from a verified preimage
          authorized_fallback: 6, # semantically equivalent, pre-authorized fallback
          compensating_action: 7, # separately authorized compensating action
          contain_escalate: 8     # contain and escalate
        }.freeze

        # Two action families are NOT §6 mutation forms:
        # * `:reconcile` is the §7 obligation that must complete BEFORE any form
        #   runs when the effect state is unknown. It is safe observation.
        # * `:abstain` is the design §2 "unknown/low confidence -> escalated" edge.
        NON_FORM_FAMILIES = %i[reconcile abstain observe].freeze
        ACTION_FAMILIES = (PERMITTED_FORMS.keys + NON_FORM_FAMILIES).freeze

        # Families that may change state. Everything else is observation only, and
        # is therefore permitted under an open circuit (design §10).
        MUTATING_FAMILIES = %i[
          refresh_recompute bounded_retry reacquire_lease rebuild_derived
          restore_preimage authorized_fallback compensating_action
        ].freeze

        # Category -> action family. Every never-mutate class lands on a
        # non-mutating family; `test_five_never_mutate_classes_never_reach_a_
        # mutating_family` asserts it over the whole table rather than trusting
        # this literal.
        CATEGORY_ACTION_FAMILY = {
          transient_pre_dispatch: :bounded_retry,
          stale_precondition: :refresh_recompute,
          dependency_unavailable: :authorized_fallback,
          malformed_recoverable_output: :refresh_recompute,
          # Budget exhaustion cannot be healed by widening the budget: that is
          # exactly the authority widening invariant 32 forbids.
          resource_exhausted: :contain_escalate,
          policy_denied: :contain_escalate,
          effect_unknown: :reconcile,
          verification_failed: :contain_escalate,
          derived_state_corrupt: :rebuild_derived,
          durable_state_corrupt: :contain_escalate,
          programmer_error: :contain_escalate,
          unknown: :abstain
        }.freeze

        # The TYPED evidence each category needs before its classification counts
        # as high confidence. Missing evidence lowers confidence to proposal grade,
        # which the rule's `minimum_confidence` gate then usually rejects.
        # Values are predicates over the frozen typed signal.
        REQUIRED_EVIDENCE = {
          transient_pre_dispatch: lambda { |signal|
            signal.dig("retryability", "pre_dispatch") == true &&
              signal["effect_state"] == "not_attempted"
          },
          stale_precondition: lambda { |signal|
            !signal["expected_digest"].nil? && !signal["observed_digest"].nil? &&
              signal["expected_digest"] != signal["observed_digest"]
          },
          dependency_unavailable: ->(signal) { !signal["target_resource"].nil? },
          malformed_recoverable_output: ->(signal) { !signal["tool"].nil? },
          resource_exhausted: ->(_signal) { true },
          policy_denied: ->(_signal) { true },
          effect_unknown: ->(signal) { signal["effect_state"] == "unknown" },
          verification_failed: ->(_signal) { true },
          derived_state_corrupt: ->(signal) { !signal["target_resource"].nil? },
          durable_state_corrupt: ->(_signal) { true },
          programmer_error: ->(_signal) { true },
          unknown: ->(_signal) { false }
        }.freeze

        # Confidence is DERIVED, not modelled: full typed evidence scores
        # `EVIDENCED_CONFIDENCE`, a typed category with incomplete evidence scores
        # `PROPOSAL_CONFIDENCE`, and `unknown` scores zero.
        EVIDENCED_CONFIDENCE = 1.0
        PROPOSAL_CONFIDENCE = 0.4
        NO_CONFIDENCE = 0.0

        # One classification decision. A VALUE — `abstained` records the design §2
        # "unknown/low confidence" edge without raising. Named `Decision` (not
        # `Classification`) so it cannot shadow the enclosing module in nested
        # scopes: `Matrix.run` calls `Classification.classify` (the module
        # function) and must resolve the MODULE, not this value class.
        Decision = Data.define(
          :category, :action_family, :confidence, :abstained, :never_mutate,
          :never_mutate_class, :reason, :evidence, :failure_fingerprint,
          :rule_id, :rule_version
        ) do
          def mutating? = MUTATING_FAMILIES.include?(action_family)

          # Design §2: abstention routes to `escalated`; so does every never-mutate
          # class. `:remediate` is the only edge that continues the state machine.
          def route
            return :escalated if abstained || never_mutate
            return :escalated if action_family == :contain_escalate

            :remediate
          end

          def abstention
            return nil unless abstained

            ClassificationAbstention.new(
              "classification abstained: #{reason}",
              category:, confidence:, reason:
            )
          end

          def to_h
            {
              "category" => category.to_s,
              "action_family" => action_family.to_s,
              "confidence" => confidence,
              "abstained" => abstained,
              "never_mutate" => never_mutate,
              "never_mutate_class" => never_mutate_class&.to_s,
              "reason" => reason,
              "evidence" => evidence,
              "failure_fingerprint" => failure_fingerprint,
              "rule_id" => rule_id,
              "rule_version" => rule_version
            }
          end
        end

        module_function

        # Classify one typed failure against one rule. Never raises for a
        # repairable condition: an unmatched trigger, missing evidence, or a
        # confidence below the rule gate all return an ABSTAINED classification.
        def classify(record, rule:)
          unless record.is_a?(FailureRecord)
            raise HealingContractError, "classification requires a FailureRecord"
          end

          signal = record.typed_signal
          fingerprint = record.fingerprint
          category = signal.fetch("category").to_sym
          never_mutate = record.never_mutate?
          never_mutate_class = record.never_mutate_class

          # A never-mutate class short-circuits BEFORE the rule trigger is even
          # consulted, so no rule can opt itself into mutating one of the five.
          if never_mutate
            family = CATEGORY_ACTION_FAMILY.fetch(category)
            family = :contain_escalate if MUTATING_FAMILIES.include?(family)
            return build(
              category:, action_family: family,
              confidence: category == :unknown ? NO_CONFIDENCE : EVIDENCED_CONFIDENCE,
              abstained: category == :unknown,
              never_mutate: true, never_mutate_class:,
              reason: "never_mutate_class:#{never_mutate_class}",
              evidence: evidence_for(signal, category),
              failure_fingerprint: fingerprint, rule:
            )
          end

          unless rule.triggers?(signal)
            return build(
              category:, action_family: :abstain, confidence: NO_CONFIDENCE,
              abstained: true, never_mutate: false, never_mutate_class: nil,
              reason: "trigger_mismatch",
              evidence: evidence_for(signal, category),
              failure_fingerprint: fingerprint, rule:
            )
          end

          confidence = confidence_for(signal, category)
          if confidence < rule.minimum_confidence
            return build(
              category:, action_family: :abstain, confidence:,
              abstained: true, never_mutate: false, never_mutate_class: nil,
              reason: "below_minimum_confidence:#{rule.minimum_confidence}",
              evidence: evidence_for(signal, category),
              failure_fingerprint: fingerprint, rule:
            )
          end

          family = CATEGORY_ACTION_FAMILY.fetch(category)
          # A rule may only take an action family it is authorized for. It may
          # NARROW (fall back to contain-and-escalate); it may never widen.
          unless rule.authorized_family?(family)
            return build(
              category:, action_family: :contain_escalate, confidence:,
              abstained: false, never_mutate: false, never_mutate_class: nil,
              reason: "family_not_authorized:#{family}",
              evidence: evidence_for(signal, category),
              failure_fingerprint: fingerprint, rule:
            )
          end

          build(
            category:, action_family: family, confidence:, abstained: false,
            never_mutate: false, never_mutate_class: nil,
            reason: "typed_evidence",
            evidence: evidence_for(signal, category),
            failure_fingerprint: fingerprint, rule:
          )
        end

        def build(category:, action_family:, confidence:, abstained:, never_mutate:,
                  never_mutate_class:, reason:, evidence:, failure_fingerprint:, rule:)
          unless ACTION_FAMILIES.include?(action_family)
            raise HealingContractError, "unknown action family #{action_family.inspect}"
          end
          if (never_mutate || abstained) && MUTATING_FAMILIES.include?(action_family)
            raise HealingPolicyError,
                  "a never-mutate or abstained classification cannot carry the " \
                  "mutating family #{action_family.inspect}"
          end

          Decision.new(
            category:, action_family:, confidence:, abstained:, never_mutate:,
            never_mutate_class:, reason:,
            evidence: Tamoz::Core.deep_freeze(evidence),
            failure_fingerprint:, rule_id: rule.rule_id, rule_version: rule.version
          )
        end

        def confidence_for(signal, category)
          return NO_CONFIDENCE if category == :unknown

          REQUIRED_EVIDENCE.fetch(category).call(signal) ? EVIDENCED_CONFIDENCE : PROPOSAL_CONFIDENCE
        end

        def evidence_for(signal, category)
          {
            "typed_evidence_complete" =>
              category == :unknown ? false : REQUIRED_EVIDENCE.fetch(category).call(signal),
            "effect_state" => signal.fetch("effect_state"),
            "pre_dispatch" => signal.dig("retryability", "pre_dispatch") == true,
            "capability_absent" => signal.fetch("capability_absent")
          }
        end

        # P12 §3: "Legacy regex adapters may propose typed classification with
        # confidence; low confidence abstains. No new regex adapter ships without a
        # defined measured precision gate with a numeric threshold."
        #
        # Two hard properties:
        # * the adapter refuses to CONSTRUCT unless its measured precision meets its
        #   declared numeric gate;
        # * a text-derived proposal is capped at `:observe` — it can never by itself
        #   put a failure on a mutating family. It must be corroborated by typed
        #   evidence, which is what `Classification.classify` consumes.
        class LegacyTextAdapter
          attr_reader :adapter_id, :measured_precision, :precision_gate

          Proposal = Data.define(:category, :confidence, :action_family, :adapter_id, :matched) do
            def mutating? = false
          end

          def initialize(adapter_id:, patterns:, measured_precision:, precision_gate:)
            unless measured_precision.is_a?(Numeric) && measured_precision.between?(0.0, 1.0)
              raise HealingPolicyError,
                    "a legacy text adapter requires a measured precision in 0.0..1.0"
            end
            unless precision_gate.is_a?(Numeric) && precision_gate.between?(0.0, 1.0)
              raise HealingPolicyError,
                    "a legacy text adapter requires a numeric precision gate in 0.0..1.0"
            end
            if measured_precision < precision_gate
              raise HealingPolicyError,
                    "legacy text adapter #{adapter_id.inspect} measured precision " \
                    "#{measured_precision} is below its gate #{precision_gate}"
            end
            unless patterns.is_a?(Hash) && !patterns.empty?
              raise HealingPolicyError, "a legacy text adapter requires patterns"
            end
            patterns.each_key do |category|
              unless FailureRecord::CATEGORIES.include?(category)
                raise HealingPolicyError, "unknown proposed category #{category.inspect}"
              end
            end

            @adapter_id = String(adapter_id).dup.freeze
            @patterns = patterns.freeze
            @measured_precision = measured_precision.to_f
            @precision_gate = precision_gate.to_f
            freeze
          end

          # Returns a NON-MUTATING proposal, or nil when nothing matched. The
          # caller must still build a typed `FailureRecord`; the proposal is
          # evidence toward that, never a remediation authorization.
          def propose(raw_message)
            text = String(raw_message)
            category, = @patterns.find { |_name, pattern| pattern.match?(text) }
            return nil unless category

            Proposal.new(
              category:, confidence: @measured_precision,
              action_family: :observe, adapter_id: @adapter_id, matched: true
            )
          end
        end

        # P12 §3 proof surface: the classification matrix with DENOMINATORS per
        # class. `cases` is [{record:, expected_family:}]; the report is pure data
        # so `tamoz-evals` (builder B/the matrix owner) can consume it without a
        # second implementation.
        module Matrix
          module_function

          def run(cases:, rule:)
            per_category = FailureRecord::CATEGORIES.to_h do |category|
              [category.to_s, {
                "denominator" => 0, "classified" => 0, "abstained" => 0,
                "correct" => 0, "mutating" => 0, "never_mutate" => 0
              }]
            end

            cases.each do |entry|
              record = entry.fetch(:record)
              expected = entry.fetch(:expected_family)
              result = Classification.classify(record, rule:)
              bucket = per_category.fetch(record.category.to_s)
              bucket["denominator"] += 1
              if result.abstained
                bucket["abstained"] += 1
              else
                bucket["classified"] += 1
              end
              bucket["correct"] += 1 if result.action_family == expected
              bucket["mutating"] += 1 if result.mutating?
              bucket["never_mutate"] += 1 if result.never_mutate
            end

            denominator = per_category.values.sum { |bucket| bucket["denominator"] }
            abstained = per_category.values.sum { |bucket| bucket["abstained"] }
            correct = per_category.values.sum { |bucket| bucket["correct"] }

            {
              "per_category" => per_category,
              "denominator" => denominator,
              "abstained" => abstained,
              "correct" => correct,
              "abstention_rate" => denominator.zero? ? 0.0 : abstained.fdiv(denominator),
              "precision" => denominator.zero? ? 0.0 : correct.fdiv(denominator),
              "abstention_quality" => abstention_quality(per_category, rule:),
              "rule_id" => rule.rule_id,
              "rule_version" => rule.version
            }
          end

          # C9: correct abstention on never-mutate classes MINUS over-abstention on
          # the classes the rule must handle. In -1.0..1.0; only the components are
          # claimed, and both denominators are reported.
          def abstention_quality(per_category, rule:)
            handled = rule.trigger_categories.map(&:to_s)
            never = FailureRecord::NEVER_MUTATE_CATEGORIES.map(&:to_s)

            never_denominator = never.sum { |name| per_category.fetch(name)["denominator"] }
            # A never-mutate class is handled CORRECTLY when it never reaches a
            # mutating family — abstention is one acceptable form of that.
            never_correct = never.sum do |name|
              bucket = per_category.fetch(name)
              bucket["denominator"] - bucket["mutating"]
            end
            handled_denominator = handled.sum { |name| per_category.fetch(name)["denominator"] }
            over_abstained = handled.sum { |name| per_category.fetch(name)["abstained"] }

            correct_rate = never_denominator.zero? ? 0.0 : never_correct.fdiv(never_denominator)
            over_rate = handled_denominator.zero? ? 0.0 : over_abstained.fdiv(handled_denominator)
            {
              "score" => correct_rate - over_rate,
              "correct_abstention_rate" => correct_rate,
              "correct_abstention_denominator" => never_denominator,
              "over_abstention_rate" => over_rate,
              "over_abstention_denominator" => handled_denominator
            }
          end
        end
      end
    end
  end
end
