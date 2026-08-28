# ADR-023 — Self-improvement is candidate promotion, never live self-mutation

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30 (elevated to a full page 2026-08-29)
**Relates to:** ADR-022 (reviewed-plan gate), ADR-025 (evaluation is a non-runtime gem), ADR-026/ADR-027 (memory layers and authorization), ADR-028 (self-healing), ADR-034 (skill identity and staged activation).
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

A learning agent that can rewrite its own prompt, evaluator, policy, or code can redefine what
"success" means and hide its own regressions. This decision draws the boundary: improvement is
a *promotion pipeline with a holdout and a human gate*, never a running agent editing itself.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

Trajectories naturally produce candidate improvements — new memories, heuristics, prompts,
skills, policies, configuration, even code. The tempting shortcut is to let the running agent
adopt them live. That shortcut is fatal for an evaluated system: if the subject can change its
own evaluator or permissions, no measurement of it can be trusted, and a regression becomes
unauditable because the thing that would detect it was the thing that changed.

## 2. Decision

**Self-improvement is candidate generation followed by an evaluated, versioned, reversible
promotion — never live self-mutation of the active behavior.**

Every promotion requires, without exception:

- a **distinct holdout** evaluation (separate from any set the subject saw),
- **immutable provenance** for the candidate,
- a **policy gate**, a **behavior version**, **monitoring**, and **rollback**.

And the hard limits:

- **Capability, security, evaluator, prompt-hierarchy, and code** changes require **human
  approval**; generated content **cannot approve itself**.
- **Resume pins the behavior version** recorded in the checkpoint — a resumed turn runs the
  behavior it was checkpointed with, not a newer one.

## 3. Consequences

- Every behavior change is attributable to a promotion with provenance, a holdout result, and
  an approver — reproducible after the fact.
- Regressions are catchable and reversible: monitoring plus rollback plus a pinned behavior
  version means a bad promotion is bounded and undoable.
- The subject cannot game its own evaluation, because the evaluator is outside the promotion it
  is judging (ADR-025: `tamoz-evals` is non-runtime and outside the subject).
- Cost: improvement is slow by construction — nothing lands "live." That latency is the price
  of auditability and is intentional.

## 4. Invariant linkage

- Depends on **ADR-025** (evaluation observes behavior without being in its dependency graph;
  Wisdom cannot activate without `tamoz-evals` and a behavior-version transition — ADR-026).
- Shares the **reviewed-plan gate** of ADR-022: a promotion that acts does so under a reviewed
  plan.
- Mirrors **ADR-034** for skills (staged activation, candidates cannot self-approve) and
  **ADR-028** for healing rules (cannot promote or reset themselves).

## 5. Threat model

**Asset:** the active behavior — the prompt hierarchy, evaluator, policy, capabilities, and
code that define what the agent is and how it is judged.

| Threat | Vector | Mitigation |
|---|---|---|
| The agent rewrites its own evaluator to pass | Live self-mutation of the judge | Evaluator changes require human approval; the evaluator is non-runtime and outside the subject (ADR-025) |
| A candidate approves itself | Generated content ratifies its own promotion | Generated content cannot approve itself; capability/security/code/prompt changes need a human |
| A regression ships invisibly | Live adoption with no holdout | Distinct holdout, monitoring, and rollback are mandatory before promotion |
| Resume adopts a newer, unvetted behavior | Behavior drift across a crash | Resume pins the checkpoint's behavior version |
| Provenance is lost, so a bad change can't be traced | Mutable candidate history | Immutable provenance is mandatory |

## 6. Rejected alternatives

| Rejected | Why |
|---|---|
| Let the running agent rewrite its active prompt, evaluator, policy, or code | It can change its evaluator or permissions and hide regressions; makes any measurement of it untrustworthy |
| Promote on repetition ("it worked twice, adopt it") | Repetition does not turn a claim into fact (ADR-026); a holdout, not frequency, authorizes a change |
| Auto-approve low-risk candidates | Self-approval is the hole; the human gate on capability/security/evaluator/prompt/code is non-negotiable |

## 7. Verification

Verified against code: 2026-08-29 — the self-improvement vertical is `tamoz-agent-improvement`
(gemspec: "the self-improvement vertical … candidate promotion"), separate from the runtime and
from `tamoz-evals`. *Recommended follow-up:* cite the promotion/holdout conformance suite path
once confirmed in `tamoz-evals`.

## Next reads

- [`README.md`](./README.md) — the ADR index
- [`adr-022-reviewed-plan-gate.md`](./adr-022-reviewed-plan-gate.md) — the sibling action gate
- [ADR-025 — evaluation is a non-runtime gem](./adr-025-evaluation-is-a-first-class-non-runtime-gem.md)
