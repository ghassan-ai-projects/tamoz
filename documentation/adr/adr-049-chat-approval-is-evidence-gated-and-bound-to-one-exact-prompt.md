# ADR-049 — Chat approval is evidence-gated and bound to one exact prompt

**Status:** Accepted 2026-08-12
**Date:** 2026-08-12
**Tier:** F
**Implementation:** Complete
**Supersedes:** [ADR-043](./adr-043-telegram-v1-is-deny-only-and-reference-bound.md)
**Relates to:** [ADR-053](./adr-053-approval-gem.md) (where `required_evidence` is decided), [ADR-042](./adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md) (the process that enforces this), [ADR-022](./adr-022-reviewed-plan-gate.md) (approval only applies to an already planned action)

Whether a chat press may approve a withheld action depends on the evidence the presser holds, not on
which transport carried it. Each press is checked against one single-use prompt bound to the exact
question. Today's policy lets the bound chat correspondent approve every asked action.

## Context

ADR-043 made Telegram deny-only: a chat identity is weaker evidence than local filesystem access, so
it could stop work but never release it. An approve path then shipped without a ratifying ADR and
approved everything. Reverting to deny-only would have hard-coded a transport rule into a question
that is really about evidence strength. This ADR made evidence the axis. On 2026-09-24 the owner set
the policy so the bound correspondent can approve.

## Decision

- **Evidence lattice.** Two values, totally ordered: `chat_bound < filesystem_operator`. A bound chat
  correspondent presents `chat_bound`; an authenticated local operator presents
  `filesystem_operator`.
- **Requirement.** Every `ask` decision carries `required_evidence`, read from the approval policy
  document (ADR-053), journaled with the decision, and pinned into the prompt. The model and the
  plan never set it.
- **Rule.** Deny is unconditional for the bound correspondent. Approve resolves only when presented
  evidence ≥ required evidence. Missing, expired, or unknown evidence never approves. Deny skips the evidence check;
  otherwise approve and deny share binding and consumption.
- **Binding.** A prompt carries a single-use 128-bit reference; the store keeps only its
  domain-separated digest. The prompt is inactive until its send receipt is durable. A press
  resolves only on an exact match of status, expiry, reference digest, surface, correspondent,
  chat, message, thread, occurrence, interrupt digest, required evidence, and action; consumption is
  atomic, and every mismatch is a durable refusal.
- **Current policy (2026-09-24).** `base.yaml` sets `evidence.approve: chat_bound` for the whole
  document, so every `ask` — today `local_execute`, `network`, and unclassified tools; no tool is
  classified into `external_publish` or `destructive` — is approvable from chat. Profiles cannot change the evidence level. A surface
  delivers approval prompts only when its `approvals.mode` is `deny_only` (a misnomer under this
  policy: it shows Approve and Deny); `none` and `affirmative` (a mode with approver roles that the
  delivery sink does not yet serve) deliver a notice instead.

A loosening beyond today's policy needs a new ADR with a blast-radius table per tier.

## Consequences

The operator can approve from a phone, and the evidence axis makes tightening a data edit. Replay,
substitution, and cross-chat presses are refused. **Cost:** whoever controls the bound chat account
can release any pending asked action, including destructive and publishing ones.

## Invariants

- INV-A: denial is unconditional. INV-B: approval is evidence-gated. INV-C: the requirement is
  trusted and pinned. INV-E: absent or ambiguous evidence never approves. (INV-D, "the v1 profile is
  deny-only by evaluation", described the 2026-08-12 policy and no longer holds.)
- 58 — a channel decision is exact, expiring, and cannot widen authority. Its "v1 accepts denial
  only" clause is out of date with this policy.

## Threat model

**Asset:** the authority to release a withheld side effect. **Adversary:** someone who controls the
bound Telegram account, or replays and forges callbacks.

| Threat | Mitigation |
|---|---|
| Hijacked chat account approves a dangerous action | **Not mitigated by policy today.** Bounded only by the surface's `prompt_ttl_s` (default 900 s, operator-set, no upper bound) and the exact binding |
| The plan sets a cheap requirement | `required_evidence` comes from the pinned policy document, never the model |
| Swap the action after the prompt is shown | Interrupt digest and requirement are part of the exact match |
| Replayed, cross-chat, or cross-surface press | Exact binding; single-use atomic consumption |
| Delivery ambiguity read as consent | Unknown never approves |
| An approve slips through deny's path | The evidence check guards approve only; separate tests for each |

**Residual risk:** an attacker with the chat account can approve any pending asked action within the
prompt's lifetime — a shell command, a network call, an unclassified MCP tool. (No tool is classified
into `external_publish` or `destructive` today, so destructive tools land in `local_execute`.) The
prompt pins and renders the evidence of the *first* pending interrupt, but the decision answers every
interrupt pending at that point. The
2026-08-12 bar for letting chat approve an effect (reversible, argument-bounded, blast radius
stated, shorter TTL and louder audit for chat approvals, default deny) was not applied to this
change; the owner accepted the risk.

## History

- 2026-08-12 — Accepted: evidence-gated approval; every effect required `filesystem_operator`, so
  chat stayed deny-only in practice.
- 2026-08-22 — The constant requirement moved into approval policy data (ADR-053).
- 2026-09-24 — Owner set `evidence.approve: chat_bound` in `base.yaml`; the bound correspondent can
  approve every ask. The per-effect bar was not applied; the owner accepted the risk.
- 2026-10-01 — ADR-043 retired into this ADR; threat model and residual risk rewritten to match the
  live policy.
