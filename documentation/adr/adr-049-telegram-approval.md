# ADR-049 — Telegram approval is evidence-gated, not transport-gated

**Status:** Accepted 2026-08-12
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

**Date:** 2026-08-12

**Relates to:** ADR-043 (Telegram v1 is deny-only and reference-bound) — this ADR is the "new ADR" ADR-043 requires before any grant mode; ADR-042 (the gateway is the only process that talks to the transport).

This decision defines when a chat identity may approve a withheld action. Approval authority is a function of the **evidence** an approver presents, not of which transport pressed the button; under the v1 policy every effect requires operator-grade evidence, so a Telegram correspondent can deny but cannot approve.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

ADR-043 made Telegram v1 deny-only: "a chat identity is weaker evidence than filesystem authority," so the channel may deny but cannot grant an approval; any future grant mode requires a new ADR. Tamoz also refuses **any** form of automatic approval.

Two facts forced a decision:

1. **The shipped code was out of compliance.** An earlier change merged an approve+deny path with no ratifying ADR — and it was approve-*everything*: the gateway recorded an `approve` decision through the same path as `deny`, with no check that the presser's authority was strong enough for the action being released. A `chat_bound` Telegram identity could therefore release any gated action.
2. **A hard revert to deny-only forecloses a shape the product wants.** Requests already route as `direct_response`, `read_only_work`, or `managed_action`, and approval interrupts fire only on `managed_action`. Conversation and read-only work are ungated. The open question is only *who may approve* at a `managed_action` gate — a permanent transport-level "never" is a blunt answer to a question really about evidence strength.

The defect and the product question share one root: approval authority was framed as a property of the transport rather than of the evidence the approver presents. ADR-043's own sentence already names the right axis.

## 2. Decision

**Approval authority is gated on evidence strength, not on transport.**

Evidence is a closed, totally ordered, two-value lattice:

```text
chat_bound  <  filesystem_operator
```

A bound Telegram correspondent supplies `chat_bound`. An authenticated local operator supplies `filesystem_operator`. Each gated action carries a `required_evidence` level; a decision resolves as *approve* only when `approver_evidence >= required_evidence`.

## 3. Evidence-gated approval invariants (INV-A..INV-E)

- **INV-A — denial is unconditional.** The bound correspondent may deny any active prompt, regardless of `required_evidence`. Denial only withholds work already gated; it is fail-safe.
- **INV-B — approval is evidence-gated.** A decision resolves as *approve* only when `approver_evidence >= required_evidence`. Approval releases withheld work; it is fail-dangerous and never shares deny's unguarded path.
- **INV-C — the requirement is trusted and pinned.** `required_evidence` comes from the engine's Decision — evaluated against the digest-pinned policy document (`gems/tamoz-approval/policy/*.yaml`) at gate time, journaled with the decision, validated against the evidence lattice when a prompt is built, and part of the prompt context the callback comparison must match. The model never sets it, and a plan cannot be re-bound to a cheaper authority after the prompt is shown.
- **INV-D — the shipped v1 profile was deny-only by evaluation.** The original v1 policy returned `required_evidence = filesystem_operator` for every effect class; the approval-policy redesign replaced that constant with per-tier defaults in the policy data (profiles may set `chat_bound`-approvable tiers deliberately). A `chat_bound` approve is refused wherever the document does not grant it — still without any transport special-case.
- **INV-E — absent or ambiguous evidence never approves.** Missing, expired, or `UNKNOWN` approver evidence resolves as withheld, never as approve.

## 4. Requirements for a future grant (the bar)

This ADR grants no Telegram approval capability. A later ADR may set `required_evidence = chat_bound` for a specific effect **only if all of the following hold**, each with a test:

1. **Reversible.** The effect has a bounded, automatic undo, or is idempotent and non-destructive.
2. **Argument-bounded.** Its risk does not depend on arguments a `chat_bound` identity could vary to escalate (e.g. no arbitrary target path); the argument schema digest is part of the requirement computation.
3. **Blast-radius stated.** The ADR names the worst outcome of an attacker with `chat_bound` evidence approving this effect, and why it is tolerable.
4. **Auditable and short-lived.** A `chat_bound` approval carries a shorter prompt TTL than an operator approval and a distinct, louder audit record (identity, evidence level, reason, timestamp).
5. **Default stays deny.** Any effect not explicitly enumerated keeps `required_evidence = filesystem_operator`.

## 5. Policy status after the approval-policy redesign (2026-08-22)

The constant `filesystem_operator` policy function was deleted: whether an action
asks, allows, or denies, and under which evidence level an approve resolves, now
lives entirely in the digest-pinned YAML documents of `gems/tamoz-approval`
(`policy/base.yaml` plus `profiles/*.yaml`). The delivery path reads the required
evidence from the journaled engine Decision (`ApprovalPrompt.build` validates it
against this lattice) and never synthesizes it. Denial stays unconditional;
approval still routes through the lattice check; absent or ambiguous evidence
still never approves. Bundled profiles keep `network`/`external_publish`
gated above what `chat_bound` can approve unless a future ADR invokes §4.

## 6. Threat model summary

**Assets.** Side-effecting/mutating actions, the workspace, and the credentials the worker holds. **Approval** is the asset — the ability to release a withheld side effect. `chat_bound` evidence means control of the bound chat or the bot token; it is weaker than `filesystem_operator` because it can be obtained without local access.

| Threat | Vector | Mitigation |
|---|---|---|
| Leaked bot token / hijacked chat approves a dangerous action | Attacker presses Approve | INV-B + INV-D: `chat_bound` cannot approve any action under v1 policy; the strongest a leaked token buys is denial (fail-safe) |
| Model or plan self-declares an action low-risk to get it approved | Compromised/mistaken plan sets a cheap requirement | INV-C: `required_evidence` is computed by trusted code from the pinned effect, never model-supplied |
| TOCTOU — a plan is re-bound to a cheaper action after the prompt is shown | Swap effect between prompt and consume | INV-C: requirement is pinned to the interrupt digest and part of the exact callback comparison |
| Replayed / cross-chat / cross-surface callback | Reuse a captured callback reference | Exact-match binding: status, TTL, reference digest, surface, correspondent, chat, message, thread, occurrence, interrupt digest, `required_evidence`, action; any mismatch is a durable refusal |
| Delivery ambiguity read as consent | Approval callback delivery `UNKNOWN` | INV-E: unknown never approves; operator-only resolution on the exact id |
| Symmetric-path bug lets a weak approve through deny's path | Code treats approve/deny alike | INV-A/INV-B are separate invariants with separate tests; approve and deny do not share a path |

**Residual risk.** With the v1 policy, `chat_bound` can never approve, so the residual approval risk is zero until a follow-up ADR lowers a specific effect to `chat_bound`. The remaining `chat_bound` capability — denial — is fail-safe.

## 7. Consequences

- The shipped approve-everything defect is closed; behavior returns to deny-only in practice, restoring the intent of ADR-043 without a blunt permanent transport ban.
- Conversation and read-only routes are unaffected — they were never gated.
- Future graduated authority (a reversible action a Telegram user may approve) becomes a small policy-table change plus a follow-up ADR meeting the bar in §4, not a rearchitecture.
- Non-goal #19 ("any form of automatic approval") is unchanged: every approval is an explicit, evidence-checked human decision.

## 8. Rejected alternatives

| Rejected | Why |
|---|---|
| Hard revert to deny-only (remove approve entirely) | Fixes the defect but bakes a transport-level "never" into code, forcing a second rewrite when a reversible chat approval is later wanted; leaves the authority rule as a special case rather than the evidence axis ADR-043 reasons about |
| Keep approve-everything | A `chat_bound` identity can release any side effect; directly contradicts ADR-043 and is the defect under repair |
| Gate on effect *class* only (`:read_only` vs `:unknown_effects`) | Tool-level class is too coarse: the same tool differs in risk by argument; authority must be computed over the argument-bound effect |
| Let the model declare an action's risk | Model output is untrusted; a compromised or mistaken plan would downgrade its own gate (violates INV-C) |
| A separate "approval strength" service/table | The requirement is a pure function of the existing pinned effect digest; a second store is a second source of truth |

## 9. Adoption

1. Route `approve` through the evidence check; add the trusted policy function returning `filesystem_operator` for every effect; add `required_evidence` to the pinned prompt context and the callback comparison.
2. Land the conformance tests: a weak approve is refused while the equivalent deny succeeds; the requirement is offline-reproducible and not model-settable; unknown/expired evidence never approves.
3. On acceptance, record the decision in the channel design's decision list and cross-link ADR-043.

## Next reads

- [`README.md`](./README.md) — the full ADR index
- [`../design/comms.md`](../design/comms.md) — the channel design and the amended ADR-043 entry
- [`../guides/telegram.md`](../guides/telegram.md) — operating the Telegram surface
- [`README.md`](./README.md) — the authoritative ADR catalog
