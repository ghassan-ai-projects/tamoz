# Audit 089 — `gems/tamoz-agent-memory/lib/tamoz/agent/memory/admission.rb`

Rank 89 · 460 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: ERR

The deterministic gate is well-factored, but rejected-record storage failures are silently
swallowed under a comment claiming operator visibility that no code implements.

## Findings

- **[major][ERR]** `store_rejected` rescues StandardError to nil with no log, raise, or result
  field. The comment claims "the operator sees the storage failure", but the store
  (tamoz-sqlite memory_store#append) logs nothing and `AdmissionResult` carries no failure — the
  admit path propagates while the rejected path vanishes silently, and the doc is contradicted by
  the code. Owning seam: surface the failure on AdmissionResult or at the admission boundary.
  (admission.rb:437-444)
- **[minor][SIZE]** `admit_owner_request` takes 10 keyword params and `build_owner_request_record`
  9, both over the ≤5 ceiling. Owning seam: an `OwnerRequest` Data value threaded from the gate to
  the record builder. (admission.rb:89-92, 171-197)

## Resolution — 2026-09-11

- **[major][ERR] fixed.** `store_rejected` no longer swallows to nil with a false
  "operator sees the storage failure" comment. It returns whether the durable write
  succeeded; the rejection paths thread that into `AdmissionResult#stored?` (new field,
  defaults true so acceptances and every existing `.new` are unchanged). A rejection whose
  audit write fails is now reported, not silent. Regression test added
  (`test_rejected_storage_failure_is_reported_through_stored_flag`, drives a real append
  failure by closing the adapter).
- **[minor][SIZE] fixed (private helpers).** Introduced an `OwnerRequest` value built once
  in `admit_owner_request` and threaded to `owner_request_negatives` (5→1 params) and
  `build_owner_request_record` (9→1), ending the parallel keyword lists the two helpers
  duplicated. The public `admit_owner_request` keeps its self-documenting kwargs — bundling
  the API surface into a value object would churn 11 call sites for no readability gain and
  was not the named seam.

Note: this file's suite carries 1 pre-existing failure + 2 errors
(`consolidation failed: Tamoz::Core::ProtocolError`) that are independent of this change —
tracked for the memory_engine_test audit (015).
