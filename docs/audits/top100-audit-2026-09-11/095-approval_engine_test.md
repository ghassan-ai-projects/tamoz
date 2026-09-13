# Audit 095 — `test/approval_engine_test.rb`

Rank 95 · 442 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major) · Bar fails: TEST

Thorough decision-matrix coverage with one private-state probe that the store's own public API
already covers.

## Findings

- **[major][TEST]** `test_workspace_write_session_grant_remembers_the_root` reads MemoryGrantStore's
  private `@grants` via `instance_variable_get` although the public surface used in this same file
  (`grant_store.size`, resolve's returned grant + lookup) expresses both assertions. Owning seam:
  GrantStore public query (lookup/size). (test/approval_engine_test.rb:438-440)

## Resolution — 2026-09-11

- **[major][TEST] fixed.** `test_workspace_write_session_grant_remembers_the_root` no longer
  reads `grant_store`'s private `@grants` via `instance_variable_get`. It captures the grant
  returned by `resolve` (asserting `grant.scope == :session`) and uses the public
  `grant_store.size` for the count — both already part of this file's public-surface usage.
