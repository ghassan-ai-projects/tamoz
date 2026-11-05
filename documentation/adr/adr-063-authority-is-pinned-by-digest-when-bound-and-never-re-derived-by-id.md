# ADR-063 — Authority is pinned by digest when it is bound, and never re-derived by id

**Status:** Accepted 2026-11-04
**Date:** 2026-09-15
**Tier:** F
**Implementation:** Complete — thread and child profiles
**Relates to:** [ADR-053](./adr-053-approval-gem.md) (the policy a profile carries)

A thread's authority is the profile digest recorded when the thread was bound, so a profile changed on disk afterwards cannot widen or silently alter what a running thread may do.

## Context

Profiles live in files an operator edits, and a thread or child task can resume long after it was bound. Looking a profile up again by its id would hand a resumed thread whatever the file says today, including authority it was never given. The rule existed only in `AGENTS.md`, which the ADR bar counts as a missing ADR.

## Decision

- **A worker refuses a thread whose profile changed.** `WorkerRuntime#validate_thread_profile` compares the profile it holds with the digest recorded at binding and raises `ToolPolicyError` on a difference. On the thread path a worker caches each profile, so an edit reaches it at restart.
- **The gateway opens a fresh thread instead.** When a conversation's thread is bound to older authority, admission binds the new turn to a new thread.
- **The CLI keeps a thread on its pinned digest** and says so.
- **A child keeps its parent's digest.** `WorkerRuntime#child_profile_for` raises `ToolPolicyError` when the parent profile changed after the child was enqueued.
- **No recorded digest is a refusal.** A binding with no digest is refused the same way; a profile that does not resolve raises an error. Nothing falls back to the current file.
- **A role's expected digest is checked too.** Resolving a model role against a different profile digest fails closed.

## Consequences

Editing a file cannot widen a running thread. **Cost:** any profile edit strands worker-bound threads: they refuse until the old profile is back, and a channel conversation continues on a new thread without its old thread state. Narrowing a profile does not narrow a thread the CLI has pinned; `profile activate` records an explicit transition for a CLI session.

## Invariants

- 35 — capability authority is local, intersected, and content-addressed.
- 40 — scheduled authority cannot widen while delayed or unattended.

## Threat model

**Asset:** what a thread or child may do. **Adversary:** whoever can write the profile file after binding.

| Threat | Mitigation |
|---|---|
| A profile edited after binding widens a running thread | The worker refuses it; the gateway opens a new thread; the CLI keeps the pinned digest |
| A child resumes under a changed parent profile | `child_profile_for` refuses it |

**Residual risk:** a digest pins the profile's content, not the code that interprets it.

## History

- 2026-11-04: recorded at the owner's request; the rule stood in `AGENTS.md` from 2026-09-15.
