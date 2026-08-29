# ADR-053 — Approval policy is isolated into the `tamoz-approval` gem

**Status:** Accepted 2026-08-22 (implemented)
**Date:** 2026-08-29 (cataloged; adopts the previously uncataloged redesign ADR)
**Relates to:** ADR-049 (approval is evidence-gated — this gem is where `required_evidence` now lives), ADR-022 (every task action requires a reviewed plan), ADR-043 (Telegram deny-only), ADR-030 (one capability catalog), ADR-052 (agent-gem decomposition).
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

Approval is now one gem with one narrow interface over policy-as-data, instead of a rule
smeared across six sites in four gems. This ADR adopts the redesign ADR authored at
`docs/approval-policy-redesign-2026-08-22/03-redesign-adr.md`, which was fully implemented
but never given a number or a place in the catalog.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

The 2026-08-22 audit found that "approval" in Tamoz was three mechanisms sharing one word:
the durable-session interrupt gate (Pipeline A), a one-shot callback gate (Pipeline B), and
an external stream approval relay (Pipeline C). The rule answering "does this action need
approval?" was split across **six sites in four gems**; the channel evidence policy was a
hardcoded Ruby constant that neutralized the fully-built evidence mechanism of ADR-049; there
were no scoped grants, so the only escape from per-call prompting was a blanket `--all` flag;
an unanswered approval parked the turn forever; and a denial killed the turn silently.

The owner's goal: make the policy dramatically simpler, and make policy/profile changes
possible **without touching `tamoz-core` or `tamoz-agent`**.

## 2. Decision

**Create the gem `tamoz-approval` (`Tamoz::Approval`) that owns every approval *policy*
decision behind one narrow interface — `build_request / decide / resolve / simulate /
reload` — with all policy content expressed as digest-addressed YAML data, not Ruby.**

- Tier assignment, rules, profiles, evidence requirements, timeout semantics, and grant
  scopes are **data** (`gems/tamoz-approval/policy/base.yaml` + `profiles/*.yaml`), loaded
  and content-addressed by the gem.
- Pipelines A and B converge on `Engine#decide`. Pipeline C stays in `tamoz-stream` as a pure
  relay that makes no local decision.
- The gem **returns verdicts; it never executes.** Dispatchers only *describe* a call (tool,
  raw argv, realpath-canonicalized targets, the descriptor's effect class); the engine
  decides. This deletes the worst prior violation — the classifier being the same object that
  executed the call.
- `required_evidence` (ADR-049) is read from the engine `Decision`, not a hardcoded constant.
- **No legacy shims.** The old profile keys, the hardcoded constant, `ApprovalDeniedError`,
  and the scheduler's informational `approval_policy` hash are deleted outright; anything
  still calling the old seams fails to boot, deliberately.

## 3. Consequences

- A policy change — including reclassifying a tool to a stricter tier — is a YAML edit in
  `tamoz-approval`: zero Ruby changes, zero core/agent changes. A profile change is selecting
  a named profile; adding one is dropping a file. Named profiles also express the
  plan/review/implement/auto/bounded-bypass permission modes, switchable live mid-session.
- Classification collapses from 8 rule sites in 4 gems to **1 data file + 1 evaluator**.
- Denial becomes a structured tool result the model can react to; turns no longer die on the
  first "no." An unanswered approval no longer parks the turn forever.
- Session-scoped grants end the "tenth identical `run_check` prompts a tenth time" failure
  without the `--all` floodgate (deleted) and without over-bundling (argv-aware keys;
  opaque-argv tiers barred from `:session` scope).
- Three gems gain a one-directional edge on `tamoz-approval`: `tamoz-agent`, `tamoz-comms`,
  and `tamoz-sqlite` (which implements the two new store ports). `tamoz-approval` itself
  depends only on `tamoz-core`.

## 4. Invariant linkage

- Preserves ADR-049 **INV-A..INV-E**: denial unconditional; approval evidence-gated;
  `required_evidence` trusted, pinned, and never model-set; absent/ambiguous evidence never
  approves.
- Preserves ADR-022: the reviewed-plan gate is upstream; this gem decides *approval*, not
  whether a plan exists.
- Upholds ADR-030: policy assigns trust/effect-class from the application side, never from
  remote or model-supplied metadata.

## 5. Threat model

**Asset:** the verdict that releases a withheld effect.

| Threat | Vector | Mitigation |
|---|---|---|
| Classifier executes what it classifies | Same object decides and runs (the deleted `capability_binding.rb:144-147` violation) | Gem returns verdicts only; dispatchers describe, engine decides |
| Model downgrades its own gate | Plan supplies a cheap `required_evidence` | `required_evidence` is data-driven from the pinned policy digest, never model-set (ADR-049 INV-C) |
| Symlink bypasses a deny glob | A workspace symlink at `~/.ssh` dodges the `.env` deny rule | Targets are realpath-canonicalized inside `Engine#build_request` before matching |
| Over-broad session grant | `:session` scope releases more than intended | Argv-aware grant keys; opaque-argv tiers barred from `:session` |

## 6. Rejected alternatives

| Rejected | Why |
|---|---|
| Keep policy spread across core/agent/comms/sqlite | 8 rule sites drift; a policy change needs Ruby edits in four gems |
| Policy as Ruby methods | Cannot change classification without a code change and redeploy; data + digest gives offline reproducibility |
| Keep the `--all` blanket flag | All-or-nothing; scoped grants give the ergonomics without the floodgate |
| A compatibility layer for the old seams | Two policy paths to audit; a clean break makes stale callers fail loudly (ADR-052 boundary discipline) |

## 7. Verification

Verified against code: 2026-08-29 — `gems/tamoz-approval/lib/tamoz/approval.rb` and
`gems/tamoz-approval/policy/{base.yaml,profiles/}` exist; ADR-049's standalone page (§5)
already references the digest-pinned YAML documents of `gems/tamoz-approval` as the live home
of `required_evidence`. Implementation evidence: `05-implementation-plan.md` phases 1–12 and
`08-implementation-bars.md` in `docs/approval-policy-redesign-2026-08-22/`.

## Next reads

- [`adr-049-telegram-approval.md`](./adr-049-telegram-approval.md) — the evidence lattice this gem serves
- [`README.md`](./README.md) — the ADR index
- [`../../docs/approval-policy-redesign-2026-08-22/`](../../docs/approval-policy-redesign-2026-08-22/) — the full redesign package (study, audit, reviews, implementation)
