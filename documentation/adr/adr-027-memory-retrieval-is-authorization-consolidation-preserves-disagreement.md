# ADR-027 — Memory retrieval is authorization; consolidation preserves disagreement

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-026](./adr-026-three-durable-memory-layers-experience-knowledge-wisdom.md) (the layers being retrieved)

A memory record a caller may not see never reaches ranking, counts, or context. Contradictions are
kept and surfaced, not averaged away, and a correction or deletion leaves every recall path with a
receipt.

## Context

Relevance-first retrieval with model-side filtering has already shown the model an unauthorized or
stale record by the time it "filters" it. Consolidation that merges disagreeing records hides the
disagreement the next decision needed. Deletion that removes the row but not the index or derived
records is not deletion.

## Decision

- All memory access goes through `Memory::Access` for one owner in one workspace. Owner, workspace,
  surface, sensitivity, layer, state, validity, and compatibility filter candidates **before**
  search or ranking.
- Experience is never auto-injected. Knowledge auto-recall is narrow. Wisdom is pinned by behavior
  version. Sensitive records are matched but never injected or indexed.
- Consolidation keeps source links, contradiction sets, exceptions, and preimages.
- Correction, supersession, quarantine, and deletion remove the record from active recall and the
  index, and deletion emits a receipt. Memory never grants a permission.

## Consequences

An unauthorized record cannot leak through a similarity score. **Cost:** every retrieval pays an
authorization pass; no gem may read memory storage directly.

## Invariants

- 30 — memory retrieval authorizes before ranking.
- 31 — memory correction and deletion propagate with proof.

## Threat model

**Asset:** memory records of other owners, workspaces, or sensitivity classes. **Adversary:**
injected content that tries to recall or plant records, and code that bypasses the facade.

| Threat | Mitigation |
|---|---|
| Cross-owner or cross-workspace leak via ranking | Scope filters run before ranking |
| Another gem reads memory storage directly | Facade-only access, guarded by a boundary test |
| A sensitive record reaches the prompt | Sensitive records are never injected or indexed |
| A deleted record keeps being recalled | Deletion propagates to the index and emits a receipt |

**Residual risk:** derived artifacts outside memory's store (exports, transcripts) are not reached
by deletion.
