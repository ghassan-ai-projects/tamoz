# frozen_string_literal: true

module Tamoz
  module Circuit
    # DR-2 §3/§4/§5 — the scope table, verbatim. One record type, four scopes.
    #
    # Every open condition in the plan's §3 table is expressed here as a typed
    # `Condition` whose predicate is evaluated INSIDE the atomic append
    # (`Record#with_failure`), never by a second engine in a caller.
    #
    # Condition kinds:
    #   consecutive — the owner's consecutive-failure counter reaches `threshold`
    #                 (a success resets that owner's counter, DR-2 §4);
    #   immediate   — a single occurrence of a named failure kind opens;
    #   window      — `threshold` occurrences inside `window_ms` (NOT consecutive:
    #                 a success in between does not clear the window, DR-2 C3);
    #   run         — the same fingerprint `threshold` times inside one run;
    #   rate        — failures/(failures+successes) at or above `max_rate` over
    #                 `window_ms` with at least `min_samples` observations.
    module Registry
      CONDITION_KINDS = %w[consecutive immediate window run rate].freeze

      Condition = Data.define(
        :id, :kind, :threshold, :window_ms, :max_rate, :min_samples, :failure_kinds
      ) do
        def initialize(
          id:, kind:, threshold: 1, window_ms: nil, max_rate: nil,
          min_samples: nil, failure_kinds: nil
        )
          kind_text = String(kind)
          unless CONDITION_KINDS.include?(kind_text)
            raise ConfigurationError, "unknown circuit condition kind #{kind.inspect}"
          end
          unless threshold.is_a?(Integer) && threshold >= 1
            raise ConfigurationError, "circuit condition threshold must be an integer >= 1"
          end
          if %w[window rate].include?(kind_text) &&
             !(window_ms.is_a?(Integer) && window_ms.positive?)
            raise ConfigurationError, "a #{kind_text} circuit condition requires a positive window_ms"
          end
          if kind_text == "rate" &&
             !(max_rate.is_a?(Float) && max_rate > 0.0 && max_rate <= 1.0 &&
               min_samples.is_a?(Integer) && min_samples >= 1)
            raise ConfigurationError,
                  "a rate circuit condition requires 0 < max_rate <= 1 and min_samples >= 1"
          end

          super(
            id: Circuit.identity!(id, name: "circuit condition id"),
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
        def observes_every_outcome? = kind == "rate"

        def with_threshold(value)
          with(threshold: value)
        end
      end

      Scope = Data.define(
        :scope_type, :conditions, :reset_authority, :evidence_rule,
        :in_flight_rule, :escalation_owner, :probe_window_ms, :provisional
      ) do
        def initialize(
          scope_type:, conditions:, reset_authority:, evidence_rule:,
          in_flight_rule:, escalation_owner:,
          probe_window_ms: DEFAULT_PROBE_WINDOW_MS, provisional: false
        )
          unless conditions.is_a?(Array) && !conditions.empty? &&
                 conditions.all?(Condition)
            raise ConfigurationError, "a circuit scope requires at least one Condition"
          end
          unless %w[complete_and_journal abort_to_unknown].include?(String(in_flight_rule))
            raise ConfigurationError, "unknown circuit in-flight rule #{in_flight_rule.inspect}"
          end
          unless probe_window_ms.is_a?(Integer) && probe_window_ms.positive?
            raise ConfigurationError, "probe_window_ms must be a positive duration"
          end

          super(
            scope_type: String(scope_type).freeze,
            conditions: conditions.freeze,
            reset_authority: String(reset_authority).freeze,
            evidence_rule: String(evidence_rule).freeze,
            in_flight_rule: String(in_flight_rule).freeze,
            escalation_owner: String(escalation_owner).freeze,
            probe_window_ms:,
            provisional: !!provisional
          )
        end

        def condition(id)
          conditions.find { |entry| entry.id == id }
        end

        def consecutive_condition
          conditions.find { |entry| entry.kind == "consecutive" }
        end

        # The scope's headline threshold (the plan's `"threshold"` record field).
        def threshold
          consecutive_condition&.threshold || 1
        end

        # A caller-configured threshold (P10's `circuit_threshold:`, P17's
        # egress declaration) rebinds the consecutive condition only.
        def with_threshold(value)
          unless value.is_a?(Integer) && value >= 1
            raise ConfigurationError, "circuit threshold must be an integer >= 1"
          end
          return self unless consecutive_condition

          with(
            conditions: conditions.map do |entry|
              entry.kind == "consecutive" ? entry.with_threshold(value) : entry
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
          rates = conditions.select(&:observes_every_outcome?)
          specific = conditions.select do |entry|
            !entry.observes_every_outcome? && entry.specific? && entry.consumes?(name)
          end
          return (specific + rates).freeze unless specific.empty?

          fallback = conditions.select do |entry|
            !entry.observes_every_outcome? && !entry.specific?
          end
          (fallback + rates).freeze
        end
      end

      # --- DR-2 §3 table ----------------------------------------------------

      SERVER = Scope.new(
        scope_type: "server",
        conditions: [
          Condition.new(
            id: "consecutive_transport_failures", kind: "consecutive", threshold: 3
          )
        ],
        # DR-2 §5: the P10 §8 "until the caller resets" contract — an operator
        # command record, NOT a plan review.
        reset_authority: "owner",
        evidence_rule: "caller_command",
        # An already-dispatched MCP call is never cut when the circuit opens:
        # the gate is at dispatch (`Invocation.ensure_available!`), and a
        # transport failure after the request was sent becomes `:unknown`
        # (design §7, invariants 21/37).
        in_flight_rule: "complete_and_journal",
        escalation_owner: "operator_command_channel"
      )

      RULE_TARGET = Scope.new(
        scope_type: "rule_target",
        conditions: [
          # SELF_HEALING_DESIGN §10, in order.
          Condition.new(
            id: "verification_failed_in_window", kind: "window", threshold: 2,
            window_ms: 900_000, failure_kinds: %w[verification_failed]
          ),
          Condition.new(
            id: "compensation_failed", kind: "immediate",
            failure_kinds: %w[compensation_failed rollback_failed]
          ),
          Condition.new(
            id: "fingerprint_repeat_in_run", kind: "run", threshold: 3,
            failure_kinds: %w[fingerprint_recurrence]
          ),
          Condition.new(
            id: "unknown_effect_for_safe_retry", kind: "immediate",
            failure_kinds: %w[unknown_effect]
          ),
          Condition.new(
            id: "budget_exceeded", kind: "rate", window_ms: 900_000,
            max_rate: 0.5, min_samples: 4
          ),
          Condition.new(
            id: "detector_confidence_below_gate", kind: "immediate",
            failure_kinds: %w[detector_confidence_below_gate]
          ),
          Condition.new(
            id: "artifact_unverifiable", kind: "immediate",
            failure_kinds: %w[artifact_unverifiable]
          ),
          Condition.new(
            id: "consecutive_remediation_failures", kind: "consecutive", threshold: 3
          )
        ],
        # DR-2 §5: `tamoz-evals` or a human-approved plan, with plan/eval
        # evidence and normally a new rule version.
        reset_authority: "tamoz-evals",
        evidence_rule: "reviewed_plan",
        # A remediation effect already dispatched when the circuit opens is
        # journaled `:unknown` and reconciled — never aborted silently, never
        # retried blindly (SELF_HEALING_DESIGN §7).
        in_flight_rule: "abort_to_unknown",
        escalation_owner: "tamoz.escalations"
      )

      SCHEDULE = Scope.new(
        scope_type: "schedule",
        conditions: [
          Condition.new(
            id: "consecutive_execution_failures", kind: "consecutive", threshold: 3
          ),
          # DR-2 §3 note: the budget row EXTENDS SCHEDULER_DESIGN §10 (which
          # names consecutive failures only). Flagged as an addition, not a
          # mapping.
          Condition.new(
            id: "budget_exceeded", kind: "rate", window_ms: 900_000,
            max_rate: 0.5, min_samples: 4
          )
        ],
        reset_authority: "owner",
        evidence_rule: "owner_or_evals",
        # Opening blocks NEW claims; an occurrence already claimed and running
        # completes and records its truthful outcome (SCHEDULER_DESIGN §10).
        in_flight_rule: "complete_and_journal",
        escalation_owner: "schedule_owner"
      )

      EGRESS = Scope.new(
        scope_type: "egress",
        conditions: [
          Condition.new(
            id: "consecutive_connect_failures", kind: "consecutive", threshold: 3
          ),
          # P17's operator-declared non-consecutive condition: ONE response over
          # the declared `max_response_bytes` opens the circuit.
          Condition.new(
            id: "budget_breach", kind: "immediate", failure_kinds: %w[budget_breach]
          )
        ],
        reset_authority: "owner",
        evidence_rule: "operator_command",
        in_flight_rule: "complete_and_journal",
        escalation_owner: "egress_profile_owner",
        # DR-2 §3: no reviewed input yet NAMES an egress circuit (the P17 plan
        # proposes it). The scope stays marked provisional until P17's source is
        # accepted.
        provisional: true
      )

      SCOPES = [SERVER, RULE_TARGET, SCHEDULE, EGRESS]
                 .to_h { |scope| [scope.scope_type, scope] }
                 .freeze

      module_function

      def fetch(scope_type)
        return scope_type if scope_type.is_a?(Scope)

        SCOPES.fetch(String(scope_type)) do
          raise ConfigurationError,
                "unknown circuit scope type #{scope_type.inspect}; " \
                "DR-2 registers #{SCOPES.keys.join(", ")}"
        end
      end

      def scope_types
        SCOPES.keys
      end

      def provisional?(scope_type)
        fetch(scope_type).provisional
      end
    end
  end
end
