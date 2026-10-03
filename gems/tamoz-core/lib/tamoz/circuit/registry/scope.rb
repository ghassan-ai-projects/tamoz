# frozen_string_literal: true

module Tamoz
  module Circuit
    module Registry
      Scope = Data.define(
        :scope_type, :conditions, :reset_authority, :evidence_rule,
        :in_flight_rule, :escalation_owner, :probe_window_ms, :provisional
      ) do
        def initialize( # rubocop:disable Metrics/ParameterLists
          scope_type:, conditions:, reset_authority:, evidence_rule:,
          in_flight_rule:, escalation_owner:,
          probe_window_ms: DEFAULT_PROBE_WINDOW_MS, provisional: false
        )
          validate_scope!(conditions, in_flight_rule, probe_window_ms)
          super(
            scope_type: frozen_text(scope_type), conditions: conditions.freeze,
            reset_authority: frozen_text(reset_authority), evidence_rule: frozen_text(evidence_rule),
            in_flight_rule: frozen_text(in_flight_rule), escalation_owner: frozen_text(escalation_owner),
            probe_window_ms:, provisional: !!provisional
          )
        end

        def condition(id)
          conditions.find { |entry| entry.id == id }
        end

        def consecutive_condition
          conditions.find { |entry| entry.kind == 'consecutive' }
        end

        # The scope's headline threshold (the plan's `"threshold"` record field).
        def threshold
          consecutive_condition&.threshold || 1
        end

        # A caller-configured threshold (P10's `circuit_threshold:`, P17's
        # egress declaration) rebinds the consecutive condition only.
        def with_threshold(value)
          unless value.is_a?(Integer) && value >= 1
            raise ConfigurationError, 'circuit threshold must be an integer >= 1'
          end
          return self unless consecutive_condition

          with(
            conditions: conditions.map do |entry|
              entry.kind == 'consecutive' ? entry.with_threshold(value) : entry
            end.freeze
          )
        end

        # Drops conditions the operator did not declare (P17's
        # `circuit.budget_breach: false` is exactly this case).
        def without_condition(id)
          remaining = conditions.reject { |entry| entry.id == id }
          return self if remaining.length == conditions.length

          with(conditions: remaining.freeze)
        end

        # The conditions whose predicate a `record_failure(kind:)` feeds: a
        # specifically declared kind wins, otherwise the catch-all applies, and
        # every rate condition always observes.
        def conditions_for(failure_kind)
          name = String(failure_kind)
          gated = conditions.reject(&:observes_every_outcome?)
          specific = gated.select { |entry| entry.specific? && entry.consumes?(name) }
          chosen = specific.empty? ? gated.reject(&:specific?) : specific
          (chosen + conditions.select(&:observes_every_outcome?)).freeze
        end

        private

        def validate_scope!(conditions, in_flight_rule, probe_window_ms)
          unless conditions.is_a?(Array) && !conditions.empty? && conditions.all?(Condition)
            raise ConfigurationError, 'a circuit scope requires at least one Condition'
          end
          unless %w[complete_and_journal abort_to_unknown].include?(String(in_flight_rule))
            raise ConfigurationError, "unknown circuit in-flight rule #{in_flight_rule.inspect}"
          end
          return if probe_window_ms.is_a?(Integer) && probe_window_ms.positive?

          raise ConfigurationError, 'probe_window_ms must be a positive duration'
        end

        def frozen_text(value)
          String(value).freeze
        end
      end
    end
  end
end
