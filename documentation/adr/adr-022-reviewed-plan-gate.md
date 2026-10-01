# ADR-022 — Every task action requires a reviewed, digest-bound plan

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Partial — the durable deliberation path gates every action; the coding work loop gates only file mutations and checks, and lets reads, web research, and read-only delegation run before a plan is accepted
**Relates to:** [ADR-053](./adr-053-approval-gem.md) (approval decides whether a planned action may proceed); [ADR-023](./adr-023-self-improvement-promotion.md), [ADR-028](./adr-028-self-healing-is-bounded-remediation-not-catch-and-retry.md) (neither may act outside this gate)

No task action runs without an accepted review of the exact persisted plan version that authorizes
it. A material change makes a new version and closes the gate until it is reviewed again.

## Context

An agent that decides and acts in one step leaves no seam where a human, a critic, or a replay can
see what was intended before it happened. A system-prompt instruction to "plan first" is not
durable, not inspectable, and not enforceable across tools, sub-agents, resume, and replanning.

## Decision

- Every new task — user, scheduled, delegated, or internal — persists a plan, even a one-step one.
- Deterministic structural and semantic review always runs; medium/high-risk plans also get an
  independent critic; human review follows approval policy (ADR-053).
- The accepted review binds the plan's canonical digest. A change to goal, steps, tools, effect
  class, budget, approval, or verification is a new version; no further action runs until it is
  accepted. Crash resume reuses the checkpointed exact version.
- When evidence is missing, an accepted discovery plan may use only locally classified read-only
  capabilities; its evidence feeds a separately reviewed action plan and authorizes nothing.

## Consequences

On the deliberation path, and for the work loop's plan-bound tools, every action has exactly one
accepted plan version that authorized it. Replanning and resume
cannot smuggle unreviewed work. **Cost:** every task pays for a plan and a review, including
one-step work; the latency and token cost of that has not been measured.

## Invariants

- 25 — reviewed plan gates task action.
- 26 — material change requires re-review.
- 55 — discovery is reviewed, read-only, and cannot authorize action.

## Threat model

**Asset:** the authority to act — mutate the workspace, run a command, call an effectful tool,
delegate. **Adversary:** a mistaken or prompt-injected model.

| Threat | Mitigation |
|---|---|
| An action runs that no plan authorized | Action paths require an accepted plan version |
| A plan is swapped after review | Material change is a new version and re-closes the gate |
| Resume replays an unreviewed plan | Resume reuses the checkpointed reviewed version |
| Discovery escalates into action | Discovery uses read-only capabilities and authorizes nothing |
| Injected text claims to be approval | Authority is the review record bound to a digest, never text in context |

**Residual risk:** in the coding work loop, reads, web research, and read-only delegation run
before any plan; they can exfiltrate context through queries (governed only by approval policy and
egress rules, ADR-054).

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A system-prompt "always plan first" | Not enforceable and cannot prove which plan authorized an action |
| Plan only high-risk actions | The risk classifier becomes the hole; the gate must be structural |
| Gate effects only and let reads run freely *(retrospective, 2026-10-01)* | Credible and cheaper; lost because reads can still leak context and steer later action — but the shipped work loop does this today, so it is the open question below |

## Reopen when

The work-loop divergence must be resolved: either this ADR narrows to "effect-bearing actions"
(with reads governed by approval policy and egress), or the work loop gates reads behind a
discovery plan. A loosening ADR must show that every ungated tool is read-only by local
classification and state what an injected read can still leak.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| No execution when no plan passes review | `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` | `test/agent_runtime_test.rb` — `test_never_executes_when_no_plan_passes_review` | Durable deliberation path |
| A semantic reviewer can force replanning before action | same | `test/agent_runtime_test.rb` — `test_semantic_reviewer_can_force_replanning_before_action` | — |
| Read-only work discovers before planning | session routing | `test/agent_durable_routing_test.rb` — `test_read_only_work_uses_durable_discovery_before_read_only_plan` | — |
| Work loop: mutations before an accepted plan are refused; widening scope returns to review | `gems/tamoz-agent-session/lib/tamoz/agent/work_gate.rb` (`PLAN_BOUND_TOOLS`) | `test/work_loop_test.rb` — `test_mutations_before_an_accepted_plan_are_refused_and_fed_back`, `test_widening_the_scope_goes_back_to_review_and_narrowing_does_not` | Only `apply_patch`, `create_file`, `run_check` are plan-bound |
