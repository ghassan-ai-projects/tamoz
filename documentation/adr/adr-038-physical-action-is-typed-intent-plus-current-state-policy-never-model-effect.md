# ADR-038 — Physical action is typed intent plus current-state policy, never model effect

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete — Tamoz side only (typed intents); dispatch policy lives in `agentic-stream` and is not verified here
**Relates to:** [ADR-039](./adr-039-tamoz-is-supervisory-certified-safety-and-real-time-control-stay-external.md) (the outer limit), [ADR-055](./adr-055-two-repo-authority-split.md) (who disposes), [ADR-058](./adr-058-domain-knowledge-is-digest-pinned-data-never-code.md) (the intent catalog is data)

A model never actuates. It proposes a typed `ActionIntent` from a digest-pinned intent catalog;
deterministic policy outside the model reloads current state, re-checks everything, and only then
journals a narrow command. Approval never skips that re-check.

## Context

Exposing actuator tools to a model behind a confirmation prompt leaves prompt injection, stale
state, duplicate effects, and approval fatigue uncontrolled. A human approving the tenth similar
prompt is not a safety barrier.

## Decision

- An episode's output is a Decision of typed intents. Each intent type, its parameter schema, and
  its risk class come from a digest-pinned intent catalog; a missing or forged catalog fails closed
  before any model call. The model cannot set a risk class.
- The disposing runtime reloads current Situation and device state and checks freshness, scope,
  bounds, quota, approval, expiry, evidence completeness and quorum, source health, idempotency,
  and external interlocks before journaling a command. R2/R3 intents fail closed on insufficient or
  contradictory evidence. Approval does not bypass revalidation.
- The episode worker holds no effector credential and names no hardware mechanism.

## Consequences

Authority to act comes from deterministic policy over current state, never from model output or a
bare confirmation. **Cost:** a whole intent-plus-policy layer between cognition and any effect.

## Invariants

- 50 — models propose typed intents; current deterministic policy owns physical dispatch.

## Threat model

**Asset:** actuation. **Adversary:** prompt injection, stale state, duplicate dispatch, and
approval fatigue.

| Threat | Mitigation |
|---|---|
| Injected text makes the model actuate | No effector in the worker; output is a typed proposal |
| The model downgrades an intent's risk | Risk comes from the pinned catalog |
| An intent built on stale state is executed | The disposer reloads current state before dispatch |
| An approved but now-unsafe command runs | Approval does not bypass revalidation |

**Residual risk:** everything after the proposal is enforced in the Go runtime, outside this
repository's tests.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Actuator tools with a confirmation prompt | Leaves injection, stale state, duplicates, and approval fatigue uncontrolled |
| Let the model pick a risk class with the intent *(retrospective, 2026-10-01)* | A compromised plan would lower its own gate |

## Reopen when

Never for direct model actuation. Revisit the intent catalog's shape if a domain's actions cannot be
typed ahead of time.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A missing or forged intent catalog fails before any model call | `gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb` | `test/stream_episode_intent_authority_test.rb` — `test_gate1_a_forged_intent_catalog_digest_fails_closed_before_any_model_call` | — |
| The decision carries the catalog-declared risk | same | `test/stream_episode_intent_authority_test.rb` — `test_the_decision_carries_the_catalog_declared_risk` | — |
| The worker names no hardware mechanism | `tamoz-stream` | `test/tamoz_brain_hardware_boundary_test.rb` — `test_the_brain_names_no_hardware_mechanism` | Revalidation and dispatch are in `agentic-stream`, not checked here |
