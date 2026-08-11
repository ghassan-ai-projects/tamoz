# frozen_string_literal: true

module Tamoz
  module Observability
    class Producer
      attr_reader :recorder, :policy

      def initialize(recorder:, policy: ContentPolicy::NONE, clock: -> { (Time.now.to_f * 1_000).to_i })
        @recorder = recorder
        @policy = policy
        @clock = clock
      end

      def emit(name, correlation: {}, attributes: {}, content: nil, timing: :point,
               started_at_ms: nil, ended_at_ms: nil, outcome: :ok, error_class: nil,
               observed_at_ms: @clock.call)
        entry = Catalog.fetch(name)
        policy_result = policy.apply(content)
        attributes = attributes.merge(outcome: outcome) if entry.required.key?(:outcome)
        signal = Signal.build(
          kind: entry.kind,
          name: entry.name,
          correlation:,
          timing:,
          started_at_ms:,
          ended_at_ms:,
          observed_at_ms:,
          attributes:,
          content: policy_result.fetch(:content),
          policy_digest: policy_result.fetch(:policy_digest),
          outcome:,
          error_class:
        )
        recorder.record(signal)
      rescue StandardError
        :dropped
      end

      def around(name, correlation: {}, attributes: {}, content: nil, outcome_attributes: {})
        started_at_ms = @clock.call
        result = yield
        ended_at_ms = @clock.call
        interval_attributes = build_interval_attributes(name, attributes, outcome_attributes,
                                                         started_at_ms, ended_at_ms)
        emit(
          name, correlation:, attributes: interval_attributes, content:,
          timing: :interval, started_at_ms:, ended_at_ms:, outcome: :ok
        )
        result
      rescue Exception => error # rubocop:disable Lint/RescueException
        ended_at_ms = @clock.call
        interval_attributes = build_interval_attributes(name, attributes, outcome_attributes,
                                                         started_at_ms, ended_at_ms)
        emit(
          name, correlation:, attributes: interval_attributes, content:,
          timing: :interval, started_at_ms:, ended_at_ms:, outcome: :error,
          error_class: error.class.name
        )
        raise
      end

      private

      def build_interval_attributes(name, attributes, outcome_attributes, started_at_ms, ended_at_ms)
        merged = attributes.merge(outcome_attributes)
        merged[:duration_ms] = ended_at_ms - started_at_ms if Catalog.fetch(name).optional.key?(:duration_ms)
        merged
      rescue StandardError
        attributes.merge(outcome_attributes)
      end
    end
  end
end
