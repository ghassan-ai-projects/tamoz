# ADR-053 — Approval policy is data, decided by one gem, `tamoz-approval`

**Status:** Accepted 2026-08-22
**Date:** 2026-08-22
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-049](./adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md) (the evidence a decision requires), [ADR-022](./adr-022-reviewed-plan-gate.md) (approval follows a reviewed plan), [ADR-030](./adr-030-one-local-capability-catalog-governs-all-sources.md) (the effect class the policy reads)

Whether an action is allowed, denied, or asked — and with what grant scope and evidence — is decided
by `tamoz-approval` from digest-pinned YAML policy. The gem returns verdicts and never executes.
Callers describe a call; the engine decides.

## Context

On 2026-08-22 "approval" was three mechanisms sharing one word, and the rule "does this action need
approval?" lived in six sites across four gems. The evidence rule of ADR-049 was a hard-coded Ruby
constant. There were no scoped grants (the only escape from per-call prompts was a blanket `--all`
flag), an unanswered approval parked a turn forever, a denial killed the turn silently, and the
classifier was the same object that executed the call.

## Decision

- `Tamoz::Approval::Engine` (`build_request`, `decide`, `resolve`, `simulate`, `reload`, session
  binding) is the only place approval is decided. It depends on `tamoz-core` only.
- All policy is data: `policy/base.yaml` (tool tiers, fallback tier, tier defaults, grant scopes and
  keys, deny/ask rules, ask timeout, evidence, simulations) plus named profiles under
  `policy/profiles/` (`plan`, `review`, `implement`, `auto`, `unattended`). A profile may change only
  tier defaults, the timeout outcome, and simulations. Every document is digest-addressed and must pass its simulations to load; a profile's simulations replace base's (so
  `auto` drops base's probe and websearch checks).
- Dispatchers describe a call (tool, argv, realpath-canonical targets, descriptor effect class); the
  engine returns a verdict. An unclassified tool falls to the fallback tier regardless of what its
  descriptor claims. A *classified* tool whose descriptor is `read_only` lands in tier `read`; for MCP
  tools that flag comes from the operator's runtime `read_only_tools` configuration, not from policy
  data.
- A session binds the policy revision it started with; a mode switch or reload is a logged rebind
  that never re-decides a recorded decision. Grants are keyed by revision: a switch hides them, and
  switching back to the same profile restores them.
- `resolve` validates evidence vocabulary but does not compare strength; the gateway, which sees the
  real channel identity, enforces ADR-049.
- A denial is a structured tool result the model can react to. An unanswered ask resolves by the
  profile's timeout outcome (`park` in base, `deny` in `unattended`).

## Consequences

A policy change, including tightening a tool, is a YAML edit with no Ruby change, and a policy can
be simulated offline. Session grants end repeated prompts without a blanket flag. **Cost:** the
policy is only as safe as its data — the engine faithfully applies a permissive policy.

## Invariants

- ADR-049 INV-A, INV-B, INV-C, INV-E.
- 40 — scheduled authority cannot widen (approval profiles pin per schedule).

## Threat model

**Asset:** the verdict that releases a withheld effect. **Adversary:** a mistaken or injected plan, a
symlink trick, or an over-broad grant.

| Threat | Mitigation |
|---|---|
| The classifier executes what it classifies | The engine returns verdicts only |
| A plan or descriptor downgrades its own tier | Tier comes from policy; unclassified tools take the fallback tier. Exception: operator runtime config can mark a classified MCP tool read-only |
| A symlink dodges a deny glob | Targets are realpath-canonicalized before matching |
| A session grant covers more than intended | Argv-aware grant keys; network, publish, and destructive tiers allow only `once` |
| A reload silently changes a running session | Sessions keep their bound revision; switches are logged |

**Residual risk:** operator runtime configuration (`read_only_tools`) can move a classified tool to
`read`, outside policy data. Under the `auto` profile, `workspace_write` and `local_execute` — and therefore
every unclassified tool, including an unclassified MCP tool — run without asking. Base policy allows
workspace writes without asking.

## History

- 2026-08-22 — Accepted; adopted the approval-policy redesign (now in
  `docs/approval-policy-redesign-2026-08-22/`).
