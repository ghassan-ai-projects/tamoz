# Audit 007 — `test/sqlite_stale_request_test.rb`

Rank 7 · 1238 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: TEST

Thorough DR-4 acceptance coverage whose scenarios, CLI cases, and fixtures are actuated through
`__send__` on private app/adapter/CLI seams.

## Findings

- **[minor][TEST]** Routine setup and seam-pinning drive the app through `__send__` on private
  writer/context methods (resume_with_writer, invoke_with_writer, build_context,
  transition_request_without_checkpoint!, acquire_lease). Owning seam: a public owner-B/writer-mode
  advance primitive on DurableRunner. (test/sqlite_stale_request_test.rb:312-364, 472-492, 958-971,
  1088-1142)
- **[minor][TEST]** CLI drain behavior is pinned by `cli.send(:drain_to_terminal, ...)` against a
  FakeSession instead of the CLI's public run surface.
  (test/sqlite_stale_request_test.rb:871-877, 914-933)
- **[minor][TEST]** `wire` fetches the private `Tamoz::SQLite::Wire` constant via `const_get` to
  dodge its visibility. (test/sqlite_stale_request_test.rb:1178-1180)

## Resolution — 2026-09-12

- [minor][TEST] `resume_with_writer`/`continue_with_writer`/`retry_failed_with_writer`/
  `invoke_with_writer`/`build_context`/`compatible_latest!` (312-364, 958-971, 1088-1142) and
  `acquire_lease`/`transition_request_without_checkpoint!` (472-492): STOPPED at the named seam —
  a public owner-B/writer-mode advance primitive. `resume_with_writer` is private on
  `Tamoz::Graph::Compiled` (gems/tamoz-graph/lib/tamoz/graph/compiled.rb:205), `acquire_lease` on
  the Adapter; the public `resume`/LifecycleExecutor does not expose the owner-B shape these tests
  pin (fresh lease, `durable_request_id: nil`, `mark_request_running: false`), so no test-side
  rewrite preserves the contract. Gems frozen this round; no change made.
- [minor][TEST] `cli.send(:drain_to_terminal, ...)`: STOPPED — the CLI's public `run(argv)` builds
  its own session internally (`CLI#initialize` takes only out/err/input/env and model/comms
  factories), so a FakeSession cannot reach the public surface without a session-injection seam in
  gems/tamoz-agent-cli. Gems frozen this round; no change made.
- [minor][TEST] `const_get(:Wire, false)`: STOPPED as entangled — `Wire` is `private_constant`
  (gems/tamoz-sqlite/lib/tamoz/sqlite/wire.rb:101) and its single use (`wire.namespace([])` at
  :475) exists only to feed the private `acquire_lease` probe from finding 1; it disappears with
  that seam.
