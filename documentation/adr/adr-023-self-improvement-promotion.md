# ADR-023 — Self-improvement is candidate promotion, never live self-mutation

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Partial — heuristic candidates get the full holdout pipeline; profile, skill, and config candidates get a human-approved, digest-bound lifecycle without a holdout; code candidates have no path
**Relates to:** [ADR-025](./adr-025-evaluation-is-a-first-class-non-runtime-gem.md) (the evaluator outside the subject); [ADR-034](./adr-034-skill-identity-is-a-tree-digest-activation-is-supply-chain-promotion.md), [ADR-028](./adr-028-self-healing-is-bounded-remediation-not-catch-and-retry.md) (the same rule for skills and healing rules)

The running agent never edits its own prompt, policy, evaluator, capabilities, or code. Improvements
are candidates that must pass a holdout, carry provenance, and be promoted to a new behavior version
that can be rolled back.

## Context

Trajectories suggest improvements: heuristics, prompts, skills, policies, code. Letting the running
agent adopt them live is fatal for an evaluated system: if the subject can change its evaluator or
permissions, no measurement of it can be trusted, and the thing that would detect a regression is
the thing that changed.

## Decision

- A candidate is generated from verified trajectories with immutable provenance. The generator
  cannot read the holdout or the evaluator's output.
- Promotion needs a paired evaluation on a holdout distinct from anything the generator saw, a
  policy gate, a new behavior version, monitoring, and byte-identical rollback.
- Capability, security, evaluator, prompt-hierarchy, and code changes need a human approval
  artifact (`human:<actor>`, asserted by the caller — not authenticated). A candidate cannot
  evaluate, approve, or promote itself.
- A resumed turn runs the behavior version recorded in its checkpoint.

The human gate may be relaxed only for a candidate class shown to be unable to widen authority
or change the evaluator by construction, with a test for each.

## Consequences

Every promoted heuristic is attributable to provenance, a holdout result, and a named approver, and
can be undone; profile, skill, and config candidates carry an approver but no holdout. **Cost:** improvement is slow by construction.

## Invariants

- 28 — self-improvement is evaluated and reversible.
- 43 — skill install, update, and self-improvement are staged and evaluated.

## Threat model

**Asset:** the active behavior and the evaluator that judges it. **Adversary:** an optimizing
generator (reward hacking) or a poisoned trajectory.

| Threat | Mitigation |
|---|---|
| The agent rewrites its evaluator to pass | Evaluator tampering is refused; evaluator changes need a human |
| A candidate approves itself | Self-evaluation and self-promotion are refused |
| An overfit candidate ships | Holdout regression refuses promotion |
| Resume adopts a newer, unvetted behavior | Resume pins the checkpoint's behavior version |
| A bad promotion cannot be undone | Rollback restores the prior epoch byte-identically |

**Residual risk:** the holdout is only as representative as its tasks; a candidate that games
something the holdout does not measure can pass.
