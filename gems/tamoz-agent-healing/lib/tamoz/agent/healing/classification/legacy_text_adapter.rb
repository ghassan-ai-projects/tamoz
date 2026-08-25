# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Classification
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
        # :reek:TooManyStatements — the constructor's refusals are a checklist and
        # each one names a distinct way an adapter can be inadmissible.
        # :reek:MissingSafeMethod — both validators raise; there is no useful
        # predicate form of "this adapter may not exist".
        # :reek:FeatureEnvy — the validators interrogate the arguments they are
        # handed, before any of it becomes state.
        class LegacyTextAdapter
          attr_reader :adapter_id, :measured_precision, :precision_gate

          # One text-derived proposal: a category, a confidence, and the action
          # family it would put the failure on. Never mutating by construction —
          # `mutating?` is hardcoded false, because text alone must not move a
          # failure onto a mutating family without typed corroboration.
          Proposal = Data.define(:category, :confidence, :action_family, :adapter_id, :matched) do
            def mutating? = false
          end

          def initialize(adapter_id:, patterns:, measured_precision:, precision_gate:)
            validate_precision!(adapter_id, measured_precision, precision_gate)
            validate_patterns!(patterns)

            @adapter_id = String(adapter_id).dup.freeze
            @patterns = patterns.freeze
            @measured_precision = measured_precision.to_f
            @precision_gate = precision_gate.to_f
            freeze
          end

          # The gate is the point of the adapter: a text-derived proposal is only
          # admissible if the adapter's MEASURED precision meets the gate it
          # declares. All three refusals fire before any state is assigned, in
          # the order an operator would check them.
          def validate_precision!(adapter_id, measured_precision, precision_gate)
            assert_precision_range!(measured_precision, 'measured precision')
            assert_precision_range!(precision_gate, 'precision gate')
            return unless measured_precision < precision_gate

            raise HealingPolicyError,
                  "legacy text adapter #{adapter_id.inspect} measured precision " \
                  "#{measured_precision} is below its gate #{precision_gate}"
          end

          def assert_precision_range!(value, name)
            return if value.is_a?(Numeric) && value.between?(0.0, 1.0)

            raise HealingPolicyError,
                  "a legacy text adapter requires a #{name} in 0.0..1.0"
          end

          def validate_patterns!(patterns)
            unless patterns.is_a?(Hash) && !patterns.empty?
              raise HealingPolicyError, 'a legacy text adapter requires patterns'
            end

            patterns.each_key do |category|
              next if FailureRecord::CATEGORIES.include?(category)

              raise HealingPolicyError, "unknown proposed category #{category.inspect}"
            end
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
      end
    end
  end
end
