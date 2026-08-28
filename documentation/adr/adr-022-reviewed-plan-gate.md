# ADR-022 — Every task action requires a reviewed, digest-bound plan

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30 (elevated to a full page 2026-08-29)
**Relates to:** ADR-023 (self-improvement is candidate promotion), ADR-028 (self-healing is bounded remediation), ADR-030 (capability catalog), ADR-053 (approval policy), ADR-049 (evidence-gated approval).

This is the load-bearing decision behind the product's central claim: *nothing acts without a
reviewed plan bound to its exact digest.* It was previously recorded as a single terse
paragraph; its role in the safety story warrants the full treatment.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

An agent that decides and acts in one step has no seam a human, a critic, or a replay can
inspect. The failure it invites is the one every autonomous agent eventually hits: it does
something consequential that no one authorized and no record can explain. The obvious fix — a
system-prompt instruction to "plan first" — is not durable, not inspectable, and not
enforceable across tools, subagents, resume, and replanning. It is a suggestion, not a gate.

Tamoz needs the *action gate* to be a structural property of the runtime, not a behavior we
hope the model exhibits.

## 2. Decision

**Every new task — user, scheduled, delegated, or internally generated — produces a persisted
plan, and no task action runs without an accepted review of that exact persisted plan
version.**

- The plan is persisted even when the proportionate plan is one step.
- Deterministic structural and semantic review passes always run. Medium/high-risk or complex
  plans additionally use an independent critic role; human review remains policy-based.
- The accepted review **binds the canonical plan digest.** Material change creates a new
  version and blocks further task action until re-reviewed; crash resume reuses the
  checkpointed exact version.
- When material evidence is missing, an accepted **bounded discovery plan** may use only
  locally classified read-only capabilities; its evidence feeds a *separately reviewed* action
  plan. Discovery cannot mutate, delegate, execute scripts, or authorize later action.

## 3. Consequences

- The action gate is enforceable and inspectable: for any action, there is exactly one accepted
  plan version whose digest authorized it.
- Replanning is safe: a material change re-opens the gate rather than silently proceeding on a
  stale review.
- Resume is safe: the checkpoint pins the exact reviewed version, so a crash cannot smuggle an
  unreviewed plan back into execution.
- Cost: every task carries plan + review machinery even for one-step work. This is deliberate —
  a one-step plan is cheap, and the uniformity is what makes the gate a *structural* property
  rather than a risk-tiered exception.

## 4. Invariant linkage

- Establishes the plan/review/action separation the reviewed-plan invariants depend on.
- Feeds ADR-053: approval decides *whether an already-planned action may proceed*; this ADR
  guarantees a reviewed plan exists to decide about.
- Constrains ADR-023 and ADR-028: neither self-improvement nor self-healing may act outside a
  reviewed, digest-bound plan.

## 5. Threat model

**Asset:** the authority to perform a task action (mutate the workspace, call a tool with
effects, delegate to a subagent).

| Threat | Vector | Mitigation |
|---|---|---|
| An action runs that no plan authorized | Model acts mid-reasoning | No action path exists without an accepted plan version whose digest is bound |
| A reviewed plan is swapped for a different one before execution | Material edit after review | A material change makes a new version and re-blocks until re-reviewed |
| Resume replays an unreviewed plan | Crash between replan and review | Resume reuses the exact checkpointed reviewed version |
| Discovery escalates into action | A read-only probe mutates or delegates | Discovery is restricted to locally classified read-only capabilities and cannot authorize later action |
| Prompt injection issues an "approved" action | Untrusted content claims authority | Authority comes from the accepted review binding a digest, not from any text in context |

## 6. Rejected alternatives

| Rejected | Why |
|---|---|
| A system-prompt "always plan first" instruction | Not durable, inspectable, or enforceable across tools, subagents, resume, and replanning; it cannot prove which plan authorized an action |
| Plan only for high-risk actions | Leaves a class of actions ungated; the gate must be structural, not risk-tiered, or the exception becomes the hole |
| Let discovery and action share one plan | A read-only probe would then carry action authority; discovery must feed a separately reviewed action plan |

## 7. Verification

Verified against code: 2026-08-29 — `Tamoz::Agent::Deliberation` is a central high-fan-in
symbol (enola: 21 dependents) and the deliberation substrate `tamoz-agent-kernel` owns the
record/receipt/effect primitives the gate binds. Approval integrates via `tamoz-approval`
(ADR-053). *Recommended follow-up:* cite the specific conformance clause/test that proves
"no action without an accepted plan version" once the invariant suite path is confirmed.

## Next reads

- [`README.md`](./README.md) — the ADR index
- [`adr-023-self-improvement-promotion.md`](./adr-023-self-improvement-promotion.md) — the sibling learning gate
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract
