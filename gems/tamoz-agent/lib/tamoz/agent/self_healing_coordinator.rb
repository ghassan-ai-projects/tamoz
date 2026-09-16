# frozen_string_literal: true

module Tamoz
  module Agent
    # The composition-root seam ADR-052 §3 reserves for `tamoz-agent`: it wires
    # the healing vertical onto a real failure path. Given a typed
    # `Healing::FailureRecord`, it finds the versioned rule that triggers on it,
    # enforces a durable circuit and a durable, fingerprint-keyed attempt bound,
    # and runs `Healing::Remediation.run` — or escalates.
    #
    # The shipped default is an EMPTY `RuleRegistry`: no rule triggers, so every
    # failure escalates and the runtime behaves exactly as it did before healing
    # was wired. An operator makes remediation live by staging a rule (ADR-028);
    # only then are the per-call remediation collaborators (critic, perform,
    # reconcile) reached.
    #
    # F20-REL-01: the healing gem takes `attempt:` from its caller and never
    # bounds it, so a caller that passes `attempt: 1` every cycle is unbounded.
    # This coordinator owns that bound instead — on a durable counter the caller
    # cannot reset by re-invoking — and refuses before the protocol runs.
    class SelfHealingCoordinator
      MAX_DURABLE_ATTEMPTS = 3
      ATTEMPTS_NAMESPACE = "tamoz.healing.attempts"

      # Uniform result: `recovered?` is the one predicate the failure path reads;
      # `remediation` carries the gem's own `Remediation::Outcome` when a rule ran.
      Decision = Data.define(:state, :reason, :remediation) do
        def recovered? = state == :recovered
        def escalated? = state == :escalated
      end

      def initialize(store:, rules:, owner_id:, clock: -> { Time.now },
                     max_durable_attempts: MAX_DURABLE_ATTEMPTS, remediation: Healing::Remediation)
        @store = store
        @rules = rules
        @owner_id = String(owner_id).dup.freeze
        @clock = clock
        @max_durable_attempts = Integer(max_durable_attempts)
        @remediation = remediation
        raise ArgumentError, "max_durable_attempts must be >= 1" if @max_durable_attempts < 1
      end

      # `record` is a `Healing::FailureRecord`. The remediation collaborators are
      # supplied per call by the staged program; they are only touched once a rule
      # matches, so the default empty-registry path never needs them.
      def remediate(record, toolbox:, critic: nil, original_invariant: nil,
                    minimal_change: nil, stop_conditions: [], perform: nil,
                    reconcile: nil, compensation: nil, escalation_sink: nil)
        unless record.is_a?(Healing::FailureRecord)
          raise ArgumentError, "remediate requires a Healing::FailureRecord"
        end

        rule = match_rule(record)
        return escalated("no_matching_rule") unless rule

        fingerprint = record.fingerprint
        attempts = durable_attempts(fingerprint)
        return escalated("durable_attempt_bound_exceeded") if attempts >= @max_durable_attempts

        circuit = build_circuit(rule)
        return escalated("circuit_open") if circuit.open?

        # Durable-first: persist the increment BEFORE the protocol runs, so a crash
        # mid-remediation cannot reset the bound to zero on the next claim.
        record_attempt(fingerprint, attempts)

        outcome = @remediation.run(
          record:, rule:, toolbox:, critic:, original_invariant:, minimal_change:,
          stop_conditions:, perform:, reconcile:, compensation:, escalation_sink:,
          circuit:, attempt: attempts + 1
        )
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
        entry ? Integer(entry.value.fetch("attempts")) : 0
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
          {"attempts" => value, "updated_at_ms" => now_ms},
          if_version: @store.head_version(ATTEMPTS_NAMESPACE, fingerprint)
        )
      end

      def now_ms = Integer(@clock.call.to_f * 1000)

      def escalated(reason) = Decision.new(state: :escalated, reason:, remediation: nil)
    end
  end
end
