# Audit 005 — `test/sqlite_comms_store_test.rb`

Rank 5 · 1342 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major) · Bar fails: TEST

Behavioral coverage of the store's state machines is strong, but the suite routinely drives the
unit through `__send__` on private internals and raw SQL instead of a public seam.

## Findings

- **[major][TEST]** Assertions and fixtures bypass the public API via
  `store.__send__(:read/:transaction/...)` raw SQL (inbound dispositions, request counts, stamps,
  tombstones) and `store.__send__(:cancellation_outcome, ...)` — asserting a unit helper rather
  than the status projection it feeds; `insert_prompt!` (raw-SQL fixture) also duplicates the
  public `insert_prompt`. Owning seam: public row-readers/fixture seam on CommsStore.
  (test/sqlite_comms_store_test.rb:70-122, 153-164, 776-779, 1017-1044)

## Resolution — 2026-09-12

- [major][TEST] PARTIALLY FIXED. `insert_prompt!` now calls the public
  `store.insert_prompt(prompt_wire(...))` and the orphaned `prompt_binds`/`ms` helpers are gone;
  `settle_terminal` calls `cancellation_outcome` publicly (it was already public — the
  `__send__` was gratuitous). The remaining raw reads (`inbound_dispositions`, `inbound_anchor_rows`,
  `request_row_count`, `cancellation_stamps`, the `created_at_ms` read, `tombstone_thread!`) are
  STOPPED at a gem seam: `read`/`transaction` are private on BOTH CommsStore and Adapter
  (gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:1289-1295, adapter.rb:222-230), so a public
  row-reader on CommsStore is the owning seam and gems are frozen this round. Swapping those
  assertions to the `request_status`/`conversation_status` projections was rejected because the
  tests deliberately pin DURABLE ROWS (stamps, inbound anchors), which the projections render
  lossily — that would weaken the contract. Suite green: 45 runs, 246 assertions.
