# ADR-028 — Self-healing is bounded remediation, not catch-and-retry

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-022](./adr-022-reviewed-plan-gate.md) (remediation acts under a reviewed plan), [ADR-016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) (unknown effects reconcile first)

Automatic recovery runs only a versioned rule for a typed failure, under a reviewed plan and the
original authority, within budgets, and counts as recovered only when an independent verifier says
so. Otherwise it compensates or escalates, and repeated failure opens a durable circuit.

## Context

Generic "self-healing" — catch the error, try something else — cannot prove it had authority, knew
the effect state, or bounded the harm. A local audit of OpenClaw found stale reads authorizing wrong
writes. Recovery is an action, so it needs the same gates as any action, plus proof it worked.

## Decision

- A remediation needs a typed failure, a versioned rule, a reviewed exact plan, proven current
  preconditions, the original authority (never wider), known effect state (unknown effects
  reconcile first), and attempt/scope/cost/time budgets.
- A rule-supplied verifier — not the remediating model — decides recovery. Verification failure
  compensates or escalates. Repeated or uncertain failure opens a durable circuit.
- Failure classes marked never-mutate escalate without an executor.
- Rules earn authority through replay, shadow, fault injection, canary, and active stages, recorded
  by `RuleRegistry` and gated by `PromotionGate` in `tamoz-agent-healing`; a rule past `shadow` needs
  a promotion record, and a rule cannot promote or reset itself.

## Consequences

Healing cannot widen authority or claim success it did not verify. **Cost:** recovery is slow and
narrow; many failures simply escalate to a human.

## Invariants

- 32 — remediation is typed, reviewed, authorized, and bounded.
- 33 — recovery means the original invariant was independently verified.
- 34 — healing rules earn authority through staged evaluation.

## Threat model

**Asset:** the workspace and external state a remediation can touch. **Adversary:** a misdiagnosis
or a failure crafted to trigger a destructive "fix".

| Threat | Mitigation |
|---|---|
| A fix targets something outside the original authority | Scope intersection refuses it |
| False recovery | Only the rule's verifier can declare recovery |
| Retry duplicates an ambiguous effect | Unknown effects reconcile before any attempt |
| Endless retry loops | Durable circuit opens on recurrence |

**Residual risk:** a rule whose verifier is wrong can declare false recovery; staged evaluation is
the defense.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Free-form "try something else" | Cannot prove authority, effect state, recovery, or bounded harm |
| Retry with backoff only *(retrospective, 2026-10-01)* | Duplicates non-idempotent effects and never fixes a logical failure |

## Reopen when

Escalation volume shows healing never fires in practice, or a verifier is found that the
remediating model can influence.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Recovery only through the oracle | `tamoz-agent-healing` remediation | `test/healing_remediation_test.rb` — `test_full_lifecycle_recovers_only_through_the_oracle`, `test_oracle_mismatch_never_recovers` | Deterministic scenarios |
| Scope intersection refuses out-of-authority targets | same | `test/healing_remediation_test.rb` — `test_scope_intersection_refuses_a_target_outside_authorized_resources` | — |
| Unknown effects reconcile then escalate | same | `test/healing_remediation_test.rb` — `test_effect_unknown_reconciles_then_escalates_without_an_executor` | — |
| Open circuit stops before classification | same | `test/healing_remediation_test.rb` — `test_open_circuit_terminates_before_classification` | — |
| Never-mutate classes never reach a mutating family | matrix | `test/healing_matrix_test.rb` — `test_never_mutate_classes_never_reach_a_mutating_family` | — |
| A rule with total abstention cannot be promoted | `gems/tamoz-agent-healing/lib/tamoz/agent/healing/promotion_gate.rb` | `test/healing_matrix_test.rb` — `test_promotion_gate_rejects_total_abstention_and_never_mutate_leak` | — |
