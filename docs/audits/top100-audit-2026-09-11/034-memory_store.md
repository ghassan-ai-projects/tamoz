# Audit 034 — `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb`

Rank 34 · 723 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: DUP

Strong immutable-row and authorization-before-materialization design, undermined by a copy-pasted
authorization WHERE clause whose lockstep is a security property.

## Findings

- **[major][DUP]** The caller-authority filter (namespace/state/tenant/user/project/
  compatibility/validity) is duplicated between `search` and `scan_matched_restricted`, differing
  only in the sensitivity predicate. The class's own invariant-30 comment requires these stay
  identical or the restricted signal becomes an existence oracle. Owning seam: one shared
  authorized-row fragment builder in MemoryStore. (memory_store.rb:244-253, 434-444)
- **[minor][STATE]** `search` degrades `IndexRow` Data values to string-keyed hashes via `to_h`
  with `store_namespace`/`statement_search` nil-ed, and `candidate_ids` fetches by string key; the
  immutable row itself should cross the boundary. (memory_store.rb:261, 85-96, 560-581)

## Resolution — 2026-09-11

- **[major][DUP] fixed.** The caller-authority filter (head eligibility, namespace, eligible
  state, tenant/user/project scope, compatibility, validity, situation boundary, match
  terms) is now single-sourced in `authorized_scan_body(sensitivity_clause, situation_filter,
  matches_sql)`, used by both `search` and `scan_matched_restricted`. They differ ONLY in the
  sensitivity predicate passed in, so the invariant-30 lockstep (the restricted existence
  signal must not become an oracle) is now structural rather than a review-time promise.
  memory_store_test green.
- **[minor][STATE] deferred with reason.** Crossing the immutable `IndexRow` (rather than a
  nil-degraded `.to_h`) ripples through `Retrieval#materialize` and both external search
  consumers (retrieval.rb, situation_recaller.rb), which read `row.fetch("...")`. That is a
  contract change to the core retrieval/materialization path for a minor gain; `index_row_from_row`
  already builds a partial IndexRow (store_namespace/statement_search nil). Left for a focused
  retrieval-contract change rather than risking the core path here.
