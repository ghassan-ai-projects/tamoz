# frozen_string_literal: true

require "digest"
require "json"

require_relative "remediation/outcome"
require_relative "remediation/plan_builder"
require_relative "remediation/plan_review"
require_relative "remediation/effect_execution"
require_relative "remediation/escalation_payload"
require_relative "remediation/attempt_evidence"
require_relative "remediation/preflight_check"
require_relative "remediation/compensation_flow"

module Tamoz
  module Agent
    module Healing
      # P12 §4 (P12-H2) — the bounded remediation protocol.
      #
      #   1. classify
      #   2. plan (original invariant, minimal change, effect class, authorization,
      #      verification, compensation, stop conditions)
      #   3. semantic critic review
      #   4. preflight (design §5 checklist)
      #   5. execute ONE permitted form (design §6)
      #   6. verify with the rule-supplied oracle (invariant 33)
      #   7. compensate or escalate (design §9/§10)
      #
      # Design §2's state machine is the control flow, and every transition is
      # appended to `Outcome#transitions` with the fields §2 requires: failure and
      # rule versions, plan/review digests, trace and effect ids, attempt, actor,
      # fence, timestamp, evidence, and budgets.
      #
      # Structural guarantees, each with a named test:
      #
      # * `perform` is invoked ONLY from the `:remediating` transition. Abstention,
      #   a never-mutate class, a rejected review, a preflight rejection, and an
      #   open circuit all return before it — so "no blind retry" is a property of
      #   the control flow, not of a caller's discipline.
      # * `recovered` is reachable ONLY through `Oracle.verify(...).passed`. No
      #   model text, exit code, or tool-success observation is an input to that
      #   branch (invariant 33).
      # * every phase runs inside `Healing::Scope.in_band`, so a remediation step
      #   that tries to amend its own rule, write a lifecycle mode, or reset its
      #   circuit is refused (invariant 34).
      module Remediation
        ACTOR = "tamoz.agent.healing"

        # Design §2 states, in order. `uncertain`/`reconcile` are the timeout /
        # ambiguous-effect branch.
        STATES = %i[
          observed classified planned reviewed preflighted remediating uncertain
          reconciling verifying compensating recovered escalated circuit_open
          unresolved
        ].freeze
        TERMINAL_STATES = %i[recovered escalated circuit_open unresolved].freeze

        module_function

        # The protocol's inputs are the design's inputs; collapsing them into an
        # options hash would hide the contract this method exists to enforce.
        def run(record:, rule:, toolbox:, critic:, original_invariant:, minimal_change:,
                stop_conditions:, context: nil, call_index: 0, attempt: 1,
                preflight_context: {}, perform: nil, reconcile: nil, circuit: nil,
                escalation_sink: nil, compensation: nil, original_trace_id: nil,
                original_effect_id: nil, actor: ACTOR, clock: nil)
          validate_records!(record, rule)

          session = build_session(
            record:, rule:, toolbox:, critic:, original_invariant:, minimal_change:,
            stop_conditions:, context:, call_index:, attempt:, preflight_context:,
            perform:, reconcile:, circuit:, escalation_sink:, compensation:,
            original_trace_id:, original_effect_id:, actor:, clock:
          )
          Scope.in_band { session.call }
        end

        def validate_records!(record, rule)
          unless record.is_a?(FailureRecord)
            raise HealingContractError, "remediation requires a FailureRecord"
          end
          return if rule.is_a?(HealingRule)

          raise HealingContractError, "remediation requires a HealingRule"
        end
        private_class_method :validate_records!

        def build_session(record:, rule:, toolbox:, critic:, original_invariant:,
                          minimal_change:, stop_conditions:, context:, call_index:,
                          attempt:, preflight_context:, perform:, reconcile:, circuit:,
                          escalation_sink:, compensation:, original_trace_id:,
                          original_effect_id:, actor:, clock:)
          circuit ||= Seams::MemoryCircuitStore.new(scope: "rule:#{rule.rule_id}")
          escalation_sink ||= Seams::NullEscalationSink.new
          compensation ||= Seams::ContainOnlyCompensation.new
          ticks = 0
          clock ||= -> { ticks += 1 }

          Session.new(
            record:, rule:, toolbox:, critic:, original_invariant:, minimal_change:,
            stop_conditions:, context:, call_index:, attempt:, preflight_context:,
            perform:, reconcile:, circuit:, escalation_sink:, compensation:,
            original_trace_id: original_trace_id || record.execution_id || "trace.unknown",
            original_effect_id: original_effect_id || record.operation,
            actor:, clock:
          )
        end
        private_class_method :build_session
      end
    end
  end
end

require_relative "remediation/session"
