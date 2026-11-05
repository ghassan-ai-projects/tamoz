# frozen_string_literal: true

module Tamoz
  module Agent
    # Runs bounded remediation for a matching rule, or escalates. The gem takes
    # `attempt:` from its caller and never bounds it (F20-REL-01); the durable
    # fingerprint-keyed counter here is that bound, refused before the protocol runs.
    class SelfHealingCoordinator
      MAX_DURABLE_ATTEMPTS = 3
      ATTEMPTS_NAMESPACE = 'tamoz.healing.attempts'

      Decision = Data.define(:state, :reason, :remediation) do
        def recovered? = state == :recovered
        def escalated? = state == :escalated
      end

      INPUT_DEFAULTS = {
        critic: nil, original_invariant: nil, minimal_change: nil, stop_conditions: [], perform: nil,
        reconcile: nil, compensation: nil, escalation_sink: nil
      }.freeze

      # What the caller hands the remediation protocol: the toolbox and hooks it runs with, and the plan it must keep.
      Inputs = Data.define(:toolbox, *INPUT_DEFAULTS.keys) do
        def initialize(toolbox:, **inputs) = super(toolbox:, **INPUT_DEFAULTS.merge(inputs))
      end

      def initialize(store:, rules:, owner_id:, clock: -> { Time.now }, remediation: Healing::Remediation)
        @store = store
        @rules = rules
        @owner_id = String(owner_id).dup.freeze
        @clock = clock
        @remediation = remediation
      end

      def remediate(record, inputs)
        raise ArgumentError, 'remediate requires a Healing::FailureRecord' unless record.is_a?(Healing::FailureRecord)

        rule = match_rule(record)
        return escalated('no_matching_rule') unless rule

        fingerprint = record.fingerprint
        attempts = durable_attempts(fingerprint)
        return escalated('durable_attempt_bound_exceeded') if attempts >= MAX_DURABLE_ATTEMPTS

        circuit = build_circuit(rule)
        return escalated('circuit_open') if circuit.open?

        # Persist before running so a crash mid-remediation cannot reset the bound.
        record_attempt(fingerprint, attempts)

        outcome = @remediation.run(record:, rule:, **inputs.to_h, circuit:, attempt: attempts + 1)
        clear_attempts(fingerprint) if outcome.recovered?
        Decision.new(state: outcome.state, reason: nil, remediation: outcome)
      end

      private

      def match_rule(record)
        signal = record.typed_signal
        @rules.rule_ids.filter_map { |id| @rules.fetch(id) }.find { |rule| rule.triggers?(signal) }
      end

      def build_circuit(rule)
        Tamoz::SQLite::CircuitStore.new(
          store: @store, scope: :rule_target, scope_id: rule.rule_id,
          owner_id: @owner_id, clock: @clock
        )
      end

      def durable_attempts(fingerprint)
        entry = @store.get(ATTEMPTS_NAMESPACE, fingerprint)
        entry ? Integer(entry.value.fetch('attempts')) : 0
      end

      def record_attempt(fingerprint, current)
        write_attempts(fingerprint, current + 1)
      end

      def clear_attempts(fingerprint)
        write_attempts(fingerprint, 0)
      end

      def write_attempts(fingerprint, value)
        @store.put(
          ATTEMPTS_NAMESPACE, fingerprint,
          { 'attempts' => value, 'updated_at_ms' => now_ms },
          if_version: @store.head_version(ATTEMPTS_NAMESPACE, fingerprint)
        )
      end

      def now_ms = Integer(@clock.call.to_f * 1000)

      def escalated(reason) = Decision.new(state: :escalated, reason:, remediation: nil)
    end
  end
end
