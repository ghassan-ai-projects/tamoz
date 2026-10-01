# ADR-026 — Three durable memory layers: Experience, Knowledge, Wisdom

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-027](./adr-027-memory-retrieval-is-authorization-consolidation-preserves-disagreement.md) (how memory is retrieved), [ADR-023](./adr-023-self-improvement-promotion.md) (Wisdom is a behavior change)

Cross-session memory has three authority levels — Experience (what happened), Knowledge (curated
claims), Wisdom (evaluated behavior) — and moving a record up a level is an audited transition,
never a side effect of repetition.

## Context

One store holding chat, facts, procedures, and learned policy erases the difference between "this
was said", "this is believed", and "this changes how the agent acts". Those carry different
authority, lifetimes, and evaluation needs. Repetition is the classic failure: a claim seen three
times is treated as true.

## Decision

- Working context is checkpointed state, not memory.
- Experience records are grounded in episodes; an episode without independent observation is
  admitted only as *reported*.
- Knowledge is curated from Experience by consolidation, which keeps source links, contradictions,
  and preimages.
- Wisdom changes behavior, so it activates only through `Memory::Wisdom`'s gated pipeline —
  development evaluation, protected holdout, authority gate, new behavior version — with the
  evaluations run on the caller's side (`tamoz-evals-runner`), never by the memory engine (ADR-023).
- Admission and promotion are policy decisions; no model call decides admission.

## Consequences

Each record says how much it should be trusted and why. **Cost:** more machinery than one store, and
promotion is a governed transition, not a write.

## Invariants

- 29 — memory promotion is layered and attributable.

## Threat model

**Asset:** what the agent will later believe and do. **Adversary:** poisoned or repeated content
in conversations and tool results.

| Threat | Mitigation |
|---|---|
| Repeated assertion becomes fact | Promotion needs consolidation evidence, not frequency |
| An unobserved claim is stored as observed | Admitted only as *reported* |
| Memory silently changes behavior | Wisdom activates only through the gated pipeline and a new behavior version |

**Residual risk:** a consistently false source can still become curated Knowledge if consolidation
has nothing contradicting it.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| One vector store for everything | Erases authority, lifecycle, and evaluation differences |
| One store where every record carries a confidence score, and recall weights by it *(retrospective, 2026-10-01)* | Credible and simpler; lost because a score cannot say *why* a record is trusted or *who* promoted it, and a high-scoring claim would still be injected as if it were evaluated behavior |

## Reopen when

A real workload shows records that fit none of the three levels, or consolidation never promotes
anything in practice.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Unobserved episodes admit only as reported | `tamoz-agent-memory` admission | `test/memory_engine_test.rb` — `test_episodes_without_independent_observation_admit_only_as_reported` | — |
| No model call decides admission | same | `test/memory_engine_test.rb` — `test_no_model_call_decides_admission` | — |
| Consolidation preserves preimages | consolidation | `test/memory_engine_test.rb` — `test_consolidation_preserves_preimage_and_failure_keeps_prior_knowledge` | — |
| Lifecycle transitions are exact | lifecycle | `test/memory_engine_test.rb` — `test_lifecycle_transitions_and_eligible_state_set_are_exact` | — |
| Wisdom promotion is gated | `gems/tamoz-agent-memory/lib/tamoz/agent/memory/wisdom.rb` | source inspection | Pipeline tests live in the improvement gem (ADR-023) |
