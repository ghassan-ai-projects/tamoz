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

      SCOPES = [SERVER, RULE_TARGET, SCHEDULE, EGRESS].to_h { |scope| [scope.scope_type, scope] }.freeze

      module_function

      def fetch(scope_type)
        return scope_type if scope_type.is_a?(Scope)

        SCOPES.fetch(String(scope_type)) do
          raise ConfigurationError,
                "unknown circuit scope type #{scope_type.inspect}; " \
                "DR-2 registers #{SCOPES.keys.join(", ")}"
        end
      end
    end
  end
end
