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

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Relevance-first retrieval, then model-side filtering | The unauthorized record has already crossed the boundary |
| Consolidate by majority or averaging *(retrospective, 2026-10-01)* | Destroys the disagreement a later decision needs |

## Reopen when

A recall path is found that bypasses `Memory::Access`, or deletion receipts are needed for artifacts
memory does not own.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Access sees only this owner and workspace | `Memory::Access` | `test/memory_access_test.rb` — `test_find_sees_only_this_owner_and_workspace_while_eligible` | — |
| No gem reaches past the facade | boundary test | `test/memory_boundary_test.rb` — `test_no_gem_outside_memory_reaches_into_its_storage_or_scopes` | Source scan |
| Sensitive records are never indexed; other scopes are never returned | retrieval | `test/memory_spec_test.rb` — `test_b4_sensitive_never_indexed_and_other_scopes_never_returned` | Surface-level filtering has no dedicated test |
| Sensitive records are never injected or decrypted | repository adapter | `test/memory_repository_adapter_test.rb` — `test_sensitive_records_are_matched_never_injected_never_decrypted` | — |
| Correction and deletion leave recall and index | lifecycle | `test/memory_engine_test.rb` — `test_correction_removes_bad_record_from_active_recall_and_index`, `test_deletion_emits_receipt_and_propagates_to_index` | Derived artifacts outside memory are not covered |
