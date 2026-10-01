# ADR-036 — Cognition sees only a sealed Situation snapshot, never raw evidence

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete — Tamoz side only; admission and Situation reduction live in `agentic-stream` and are not verified here
**Supersedes:** [ADR-035](./adr-035-streaming-input-is-a-distinct-first-class-runtime.md)
**Relates to:** [ADR-055](./adr-055-two-repo-authority-split.md) (who builds the snapshot), [ADR-038](./adr-038-physical-action-is-typed-intent-plus-current-state-policy-never-model-effect.md) (what an episode may propose)

Unbounded evidence never enters a Tamoz graph or a model. A deterministic plane reduces it into an
immutable, versioned Situation; a Tamoz episode runs once against one sealed, digest-checked
snapshot of it.

## Context

Invoking the agent per event, or draining raw windows into a prompt, maximizes cost and staleness
and moves deterministic stream semantics (ordering, windows, deduplication) into probabilistic
cognition. An unbounded source has no temporal truth, bounded state, or recovery model of its own.

## Decision

- Raw events are admitted and reduced by deterministic operators outside Tamoz (`agentic-stream`)
  into immutable, versioned Situations. Every admission and non-admission is durable and
  explainable there.
- `agentic-stream` runs at most one episode per admitted Situation snapshot; newer evidence may
  supersede it.
- A Tamoz episode receives `snapshot_json` and its SHA-256, recomputes the digest, and terminates
  before any model call when they disagree or identity fields are missing.
- The episode's accepted decision binds that snapshot digest.

## Consequences

Cognition cost is per decision-worthy change, not per event, and every decision names the exact
evidence it saw. **Cost:** each source needs a defined Situation model and admission policy, built
in the other runtime.

## Invariants

- 44 — input streams are not execution streams or user channels.
- 49 — cognition is admitted against one immutable Situation snapshot.

## Threat model

**Asset:** the evidence a decision rests on. **Adversary:** corruption or drift between plane and
worker.

| Threat | Mitigation |
|---|---|
| A tampered or drifted snapshot drives a decision | Digest recomputed; mismatch ends the episode before any model call |
| A snapshot missing identity is accepted | Refused |
| Raw evidence floods the prompt | Only the bounded snapshot crosses |

**Residual risk:** the digest travels with the payload, so it proves consistency, not who sent it;
sender authenticity comes from the transport (ADR-055).

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Invoke the agent per event, or put raw windows in the prompt | Maximizes cost and staleness; moves deterministic semantics into probabilistic cognition |
| Rename token streaming as "bidirectional streaming" and attach sensor callbacks to a chat | No temporal truth, bounded state, or recovery |

## Reopen when

A use case needs cognition latency below what admission plus one episode allows.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A tampered snapshot fails before any model call | `gems/tamoz-stream/lib/tamoz/stream/situation_snapshot.rb` | `test/stream_situation_snapshot_test.rb` — `test_a_tampered_snapshot_fails_before_any_model_call` | — |
| Snapshot mismatch terminates the episode | episode worker | `test/stream_invariants_test.rb` — `test_invariant_2_snapshot_mismatch_terminates_before_any_model_call` | — |
| The episode path computes no stream-plane concept | `tamoz-stream` | `test/stream_invariants_test.rb` — `test_invariant_1_the_episode_path_computes_no_stream_plane_concepts` | Admission/reduction is in the Go repository, not checked here |
