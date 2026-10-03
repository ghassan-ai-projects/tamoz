# frozen_string_literal: true

module Tamoz
  module Circuit
    module Registry
      CONDITION_KINDS = %w[consecutive immediate window run rate].freeze

      Condition = Data.define(
        :id, :kind, :threshold, :window_ms, :max_rate, :min_samples, :failure_kinds
      ) do
        def initialize( # rubocop:disable Metrics/ParameterLists
          id:, kind:, threshold: 1, window_ms: nil, max_rate: nil,
          min_samples: nil, failure_kinds: nil
        )
          kind_text = validated_kind(kind)
          validate_threshold!(threshold)
          validate_window!(kind_text, window_ms)
          validate_rate!(kind_text, max_rate, min_samples)
          super(
            id: Circuit.identity!(id, name: 'circuit condition id'),
            kind: kind_text.freeze,
            threshold:,
            window_ms:,
            max_rate:,
            min_samples:,
            failure_kinds: failure_kinds&.map { |name| String(name).freeze }&.freeze
          )
        end

        # A condition with a declared kind list consumes exactly those failure
        # kinds; a condition without one is the scope's catch-all.
        def specific? = !failure_kinds.nil?

        def consumes?(failure_kind)
          failure_kinds.nil? || failure_kinds.include?(String(failure_kind))
        end

        # `rate` conditions observe EVERY outcome (successes included) — they are
        # never subject to the specific/catch-all arbitration.
        def observes_every_outcome? = kind == 'rate'

        def with_threshold(value)
          with(threshold: value)
        end

        private

        def validated_kind(kind)
          kind_text = String(kind)
          return kind_text if CONDITION_KINDS.include?(kind_text)

          raise ConfigurationError, "unknown circuit condition kind #{kind.inspect}"
        end

        def validate_threshold!(threshold)
          return if threshold.is_a?(Integer) && threshold >= 1

          raise ConfigurationError, 'circuit condition threshold must be an integer >= 1'
        end

        def validate_window!(kind_text, window_ms)
          return unless %w[window rate].include?(kind_text)
          return if window_ms.is_a?(Integer) && window_ms.positive?

          raise ConfigurationError, "a #{kind_text} circuit condition requires a positive window_ms"
        end

        def validate_rate!(kind_text, max_rate, min_samples)
          return unless kind_text == 'rate'
          return if max_rate.is_a?(Float) && max_rate > 0.0 && max_rate <= 1.0 &&
                    min_samples.is_a?(Integer) && min_samples >= 1

          raise ConfigurationError, 'a rate circuit condition requires 0 < max_rate <= 1 and min_samples >= 1'
        end
      end
    end
  end
end
