# ADR-049 — Telegram approval is evidence-gated, not transport-gated

- **Status:** Accepted 2026-08-12 (reviewed and approved; the amendment and §18 entry below are applied).
- **Date:** 2026-08-12
- **Relates to:** ADR-043 (Telegram v1 is deny-only and reference-bound) — this ADR is the
  "new ADR" ADR-043 requires before any grant mode; ADR-042 (the gateway is the only
  process that talks to the transport); `TELEGRAM_COMMUNICATION_FLOW_CONTRACT_2026-08-12.md`
  §2/§7.1; `TELEGRAM_COMMUNICATION_BAR.md` group C.
- **On acceptance (applied 2026-08-12):** the one-line entry (below) was added to
  `COMMS_DESIGN.md` §18 and the ADR-043 amendment (below) was applied. Both were held
  until acceptance because ADR-043 is live authority and this ADR was a draft; authority
  must not defer to an unaccepted decision.

## ADR-043 amendment (apply to `COMMS_DESIGN.md` §18 on acceptance)

ADR-043 is not overturned — its caution is preserved and made executable. Replace its entry
with:

> **ADR-043 — Telegram is deny-only by default, reference-bound.** A chat identity is weaker
> evidence than filesystem authority. The channel may submit an exact, attributable,
> expiring denial. It may not grant an approval by default: under the evidence-gated policy
> of **ADR-049**, every effect requires `filesystem_operator` evidence, which a chat
> identity does not supply. Lowering a specific, reversible, argument-bounded effect to
> `chat_bound` approval is possible only through a follow-up ADR meeting ADR-049 §4; absent
> such an ADR, Telegram remains deny-only in practice.

The original clause "any future grant mode requires a new ADR" is satisfied by ADR-049,
which supplies the mechanism and the threat model, and defers each actual grant to a further
per-effect ADR. Non-goal #19 ("any form of *automatic* approval") is unchanged: ADR-049
adds no automatic approval — every approval is an explicit, evidence-checked human decision.

## One-line entry (for the COMMS_DESIGN §18 ADR list, on acceptance)

- **ADR-049 — Telegram approval is evidence-gated, not transport-gated.** Approval authority
  is a function of evidence strength (`chat_bound < filesystem_operator`), not of which
  transport pressed a button. Denial is unconditional; approval requires
  `approver_evidence >= required_evidence`, computed by trusted code from the pinned effect
  digest. The v1 policy requires `filesystem_operator` for every effect, so Telegram is
  deny-only in practice; lowering any effect to `chat_bound` requires a follow-up ADR
  meeting the bar in §7 here. Supersedes the shipped approve-everything path, which skipped
  the check.

## 1. Context

ADR-043 made Telegram v1 deny-only: "a chat identity is weaker evidence than filesystem
authority," so the channel may deny but "cannot grant an approval; any future grant mode
requires a new ADR." Non-goal #19 lists "**any** form of automatic approval."

Two facts force a decision now:

1. **The shipped code is out of compliance.** The branch merged an approve+deny path with no
   ratifying ADR. Worse, it is approve-*everything*: `comms_gateway#resolve_callback`
   records an `approve` decision through the same path as `deny`, with no check that the
   presser's authority is strong enough for the action being released. A `chat_bound`
   Telegram identity can therefore release any gated action.
2. **A hard revert to deny-only forecloses a shape the product wants.** The system already
   routes each request as `direct_response`, `read_only_work`, or `managed_action`
   (`request_route`), and approval interrupts fire only on `managed_action`. Conversation
   and read-only work are already ungated. The open question is only *who may approve* at a
   `managed_action` gate — and a permanent transport-level "never" is a blunt answer to a
   question that is really about evidence strength.

The defect and the product question have one root: approval authority was framed as a
property of the transport (Telegram) rather than of the **evidence** the approver presents.
ADR-043's own sentence already names the right axis.

## 2. Decision

**Approval authority is gated on evidence strength, not on transport.**

Evidence is a closed, totally ordered, two-value lattice:

```text
chat_bound  <  filesystem_operator
```

A bound Telegram correspondent supplies `chat_bound`. An authenticated local operator
supplies `filesystem_operator`. Each gated action carries a `required_evidence` level, and:

- **INV-A — denial is unconditional.** The bound correspondent may deny any active prompt,
  regardless of `required_evidence`. Denial only withholds work already gated; it is
  fail-safe.
- **INV-B — approval is evidence-gated.** A decision resolves as *approve* only when
  `approver_evidence >= required_evidence`. Approval releases withheld work; it is
  fail-dangerous and never shares deny's unguarded path.
- **INV-C — the requirement is trusted and pinned.** `required_evidence` is a deterministic
  function of the pinned interrupt/effect digest that will execute, computed by the trusted
  layer that binds capabilities (from tool, argument-schema digest, effect class, target
  scope), reproducible offline, and part of the prompt context the callback comparison must
  match. The model never sets it, and a plan cannot be re-bound to a cheaper authority after
  the prompt is shown.
- **INV-D — v1 policy is deny-only by evaluation.** The v1 policy returns
  `required_evidence = filesystem_operator` for every effect class. So a `chat_bound`
  approve is refused for every action, and Telegram is deny-only in practice — without a
  hardcoded transport special-case.
- **INV-E — absent or ambiguous evidence never approves.** Missing, expired, or `UNKNOWN`
  approver evidence resolves as withheld, never as approve.

**This ADR grants no Telegram approval capability.** Under the v1 policy no effect is
`chat_bound`-approvable. It fixes the defect (routes approve through a check that currently
denies all) and establishes the framework a later, effect-specific grant would use.

Implementation is deliberately minimal: one trusted policy function returning the constant
`filesystem_operator`, and one lattice comparison at the callback. The generality lives in
this decision, not in code; a lattice is not to be built out.

## 3. Threat model (required by ADR-043)

**Assets.** Side-effecting / mutating actions (file writes, managed tool calls), the
workspace, and credentials the worker holds. Denial protects nothing an attacker wants;
**approval** is the asset — the ability to release a withheld side effect.

**Weak evidence.** `chat_bound` means control of the bound chat or the bot token. It is
weaker than `filesystem_operator` because it can be obtained without local access.

| Threat | Vector | Mitigation |
|---|---|---|
| Leaked bot token / hijacked chat approves a dangerous action | Attacker presses Approve | INV-B + INV-D: `chat_bound` cannot approve any action under v1 policy; the strongest a leaked token buys is denial (fail-safe) |
| Model or plan self-declares an action low-risk to get it approved | Compromised/mistaken plan sets a cheap requirement | INV-C: `required_evidence` is computed by trusted code from the pinned effect, never model-supplied |
| TOCTOU — a plan is re-bound to a cheaper action after the prompt is shown | Swap effect between prompt and consume | INV-C: requirement is pinned to the interrupt digest and is part of the exact callback comparison |
| Replayed / cross-chat / cross-surface callback | Reuse a captured `callback_data` | Exact-match binding (contract §7.1): status, TTL, reference digest, surface id+revision, correspondent, chat, message, thread, occurrence, interrupt digest, `required_evidence`, action; any mismatch is a durable refusal |
| Delivery ambiguity read as consent | Approval callback delivery `UNKNOWN` | INV-E: unknown never approves; operator-only resolution on the exact id (contract §7.2) |
| Symmetric-path bug lets a weak approve through deny's path | Code treats approve/deny alike | INV-A/INV-B are separate invariants with separate tests (bar C1); approve and deny do not share a path |

**Residual risk.** With the v1 policy, `chat_bound` can never approve, so the residual
approval risk is zero until a follow-up ADR lowers a specific effect to `chat_bound`. The
remaining `chat_bound` capability — denial — is fail-safe. This is why the framework is
acceptable to accept now while every grant stays deferred.

## 4. Requirements for a future grant (the bar for any ADR that lowers an effect to `chat_bound`)

A later ADR may set `required_evidence = chat_bound` for a specific effect **only if all
hold**, each with a test:

1. **Reversible.** The effect has a bounded, automatic undo, or is idempotent and
   non-destructive.
2. **Argument-bounded.** Its risk does not depend on arguments a `chat_bound` identity could
   vary to escalate (e.g. no arbitrary target path); the argument schema digest is part of
   the requirement computation.
3. **Blast-radius stated.** The ADR names the worst outcome of an attacker with `chat_bound`
   evidence approving this effect, and why it is tolerable.
4. **Auditable and short-lived.** A `chat_bound` approval carries a shorter prompt TTL than
   an operator approval and a distinct, louder audit record (identity, evidence level,
   reason, timestamp).
5. **Default stays deny.** Any effect not explicitly enumerated keeps
   `required_evidence = filesystem_operator`.

## 5. Consequences

- The shipped approve-everything defect is closed; behavior returns to deny-only in
  practice, restoring the intent of ADR-043 without a blunt permanent transport ban.
- Conversation and read-only routes are unaffected — they were never gated.
- Contract §7.1 and bar group C (C1–C3) grade this exact model; the `TELEGRAM_COMMUNICATION`
  §2 blocker resolves via "exit 2."
- Future graduated authority (a reversible action a Telegram user may approve) becomes a
  small policy-table change plus a follow-up ADR meeting §4, not a rearchitecture.

## 6. Rejected alternatives

| Rejected | Why |
|---|---|
| Hard revert to deny-only (remove approve entirely) | Fixes the defect but bakes a transport-level "never" into code, forcing a second rewrite when a reversible chat approval is later wanted; it also leaves the authority rule as a special case rather than the evidence axis ADR-043 actually reasons about |
| Keep approve-everything | A `chat_bound` identity can release any side effect; directly contradicts ADR-043 and is the defect under repair |
| Gate on effect *class* only (`:read_only` vs `:unknown_effects`) | Tool-level class is too coarse: the same tool differs in risk by argument (a write to a temp dir vs to a system path); authority must be computed over the argument-bound effect, not the tool's class |
| Let the model declare an action's risk | Model output is untrusted; a compromised or mistaken plan would downgrade its own gate (violates INV-C) |
| A separate "approval strength" service/table | The requirement is a pure function of the existing pinned effect digest; a second store would be a second source of truth (cf. `COMMS_DESIGN` §20) |

## 7. Adoption

1. Route `approve` through the evidence check; add the trusted policy function returning
   `filesystem_operator` for every effect; add `required_evidence` to the pinned prompt
   context and the callback comparison.
2. Land the bar's C1–C3 tests: a weak approve is refused while the equivalent deny succeeds;
   the requirement is offline-reproducible and not model-settable; unknown/expired evidence
   never approves.
3. On acceptance, add the §18 one-line entry to `COMMS_DESIGN.md` and cross-link ADR-043.
