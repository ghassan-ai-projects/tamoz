# Audit 010 — `test/agent_cli_test.rb`

Rank 10 · 1155 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: TEST

Genuine end-to-end CLI coverage, but three clusters assert contracts through private ivars and
`send` on private methods.

## Findings

- **[minor][TEST]** Signal exit-code tests install `@cancellation` via `instance_variable_set` and
  call private `exit_for_cancellation`. Owning seam: a public cancellation-injection point on
  CLI.run. (test/agent_cli_test.rb:612-638)
- **[minor][TEST]** The operator answer vocabulary (`map_answer`) is pinned only through
  `cli.send(:map_answer, ...)` on the private seam — the documented fixture-cost tradeoff still
  leaves the user-facing contract with no public assertion.
  (test/agent_cli_test.rb:929-953)
- **[minor][TEST]** `latest_request_record` drives `adapter.__send__(:read)` raw SQL and fabricates
  a placeholder RequestRecord (empty digests, zero sequences) to read two fields. Owning seam: the
  checkpointer's public `request_history` already yields these.
  (test/agent_cli_test.rb:1036-1076)

## Resolution — 2026-09-11

- **[minor][TEST] fixed — the audit's claim was verified and held.** `request_history` is
  genuinely public and genuinely sufficient: `SQLite::RequestInboxRows#request_history(thread_id:,
  namespace:)` selects the full `REQUEST_SELECT` column set and maps every row through
  `materialize_request`, returning fully-populated `Graph::RequestRecord`s; it is exposed publicly
  as `CheckpointStore#request_history` and `Graph::DurableRunner#history(thread:, namespace:)`.
  The only fields the three callers use are `.request_id` and `.status`, both real columns — so
  the fabricated placeholder record (empty digests, zeroed sequences/timestamps) was pure
  scaffolding. `latest_request_record` now reads
  `session.app.durable_runner.history(thread:).last` (history is ASC, so `.last` is the same row
  the old `ORDER BY enqueue_sequence DESC LIMIT 1` picked); the raw SQL and the placeholder are
  deleted. No `__send__(:read` remains in the file.
- **[minor][TEST] ×2 deferred.** The signal exit-code tests
  (`instance_variable_set(:@cancellation, …)` + private `exit_for_cancellation`) and the
  `cli.send(:map_answer, …)` vocabulary pinning are unchanged: both need new public seams on
  `CLI.run` (a cancellation-injection point; an answer-vocabulary surface), which is a production
  API decision rather than a test fix.

Verified: 34 runs / 764 assertions / 0 failures before AND after; assertion-bearing line count
unchanged at 129; RuboCop unchanged at 6 offenses (all pre-existing).
