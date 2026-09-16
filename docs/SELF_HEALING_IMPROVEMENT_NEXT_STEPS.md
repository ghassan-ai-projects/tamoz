# Self-healing & self-improvement — next steps

Date: 2026-09-17 · Follows [`GEM_WIRING_PLAN_2026-09-16.md`](GEM_WIRING_PLAN_2026-09-16.md)

## Where it stands

Both verticals are wired and their loops proven end to end:

- **Self-healing** — the ADR-028 shadow stage (`SelfHealingAssessor`) classifies a failed turn's
  typed failure on the ephemeral (`tamoz TASK`) and durable (worker / queue / schedule / Telegram)
  paths. The `SelfHealingCoordinator` (active remediation, F20-REL-01 bound closed) is built and
  tested but not yet wired — it waits on a staged rule.
- **Self-improvement** — `tamoz improve` generates; `HeuristicImprovementPipeline` composes
  generate → holdout eval → decision → provenance; `tamoz improve promote` records a durable,
  human-gated promotion that activates at a thread's first intake. Proven against real components.

## The theme

Both are **machinery waiting for fuel**. The hard, gated parts exist; what is thin is the
operator-runnable middle and the flow of real production data. The leverage is in connecting the
mechanism to reality, not in building more mechanism.

## Self-improvement

| Item | What | Why | Size | Prereqs |
|---|---|---|---|---|
| SI-1 | Operator entry for the evaluation stage (`tamoz improve evaluate`, or an evals rake) | Generate and promote exist; the middle (run the holdout eval, write the bundle) is test-only, so the loop is not operator-runnable end to end | M | — |
| SI-2 | Export a real trajectory corpus from recorded episodes (verified + train/holdout partition) | Generation mines evals *fixtures*, not real behavior; this is what makes improvement learn from actual use | M–L | durable episode recorder |
| SI-3 | Harden the human gate (F23): bind approval to the exact candidate+report digest; resolve evidence from an out-of-band evaluator store, not a caller-supplied resolver | The audit flagged the gate as a forgeable string and the resolver as satisfiable from inside the gem — security debt on the promote path | M | — |
| SI-4 | Operator surface for monitoring + rollback (`improve status` / `improve rollback`) | Promotion records reversibility, but nothing lets an operator see post-activation telemetry or undo a promotion; reversibility is not real until reachable | S–M | — |
| SI-5 | Beyond one bounded heuristic kind (routing / verification / memory candidates) | v1 caps at one live planning-surface insert-only heuristic; more kinds need their own eval oracles | L | SI-1 |

## Self-healing

| Item | What | Why | Size | Prereqs |
|---|---|---|---|---|
| SH-1 | Stage one real healing rule through the full ADR-028 ladder (replay → shadow → fault-injection → canary → active) and wire the Coordinator's active path | This is the point — it turns shadow assessment into actual auto-recovery; the Coordinator and F20 bound are built, nothing has walked the ladder | L | SH-3 |
| SH-2 | Aggregate `healing.assessment` events into a signal (which categories/fingerprints recur, which escalate for lack of a rule) | Closes the authoring loop — tells operators which rules to write; cheap, and makes the shadow stage useful beyond a log line | S | — |
| SH-3 | Harden the Coordinator before it goes active: CAS retry on the durable counter; TTL/decay on the fingerprint bound | A transient failure class must not poison a fingerprint forever; concurrent writes must not throw. Prerequisites for the active stage | S | — |
| SH-4 | Richer failure→category mapping (use the effect receipt / retryability, not just `error_class`) | Much currently lands in `:unknown`, which can never remediate; better classification widens what is healable | S–M | — |
| SH-5 | Optional channel delivery of the assessment (e.g. into Telegram) | For some deployments, "this failed for reason X, escalating" is better UX than the generic phrase; behind a config toggle | S | — |
| SH-6 | Wire the in-process `tamoz ask` renderer | The one remaining path that does not surface the assessment (it does not go through `settle_failed_view`) | S | — |

## The idea worth chasing: close the healing↔improvement loop

Recurring *unremediable* healing escalations are exactly the signal for what to improve; verified
trajectories are exactly what healing rules should target. Today these are two separate systems. A
shared "what keeps failing / what keeps working" store would (a) tell you which healing rules to
author (from SH-2), and (b) give improvement a real, prioritized corpus (SI-2) — turning two
demo-grade features into one self-reinforcing loop. It is also the most novel work here; the rest
fills known gaps.

## Suggested sequence

**SH-2 (assessment aggregation, S) → SI-2 (real trajectory export, M) → SI-1 (operator evaluate
entry, M) → SH-1 (stage the first healing rule, L).** The first three are cheap and unlock the
fourth being worth doing. SH-3 lands alongside SH-1 as its prerequisite; SI-3 (gate hardening) is
independent and should precede any real promotion in production.
