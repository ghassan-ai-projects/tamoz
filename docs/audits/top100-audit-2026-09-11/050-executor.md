# Audit 050 — `gems/tamoz-graph/lib/tamoz/graph/executor.rb`

Rank 50 · 616 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major) · Bar fails: SIZE

The super-step executor is correct and typed, but `run` is a 156-line orchestration monolith and
the checkpoint-append family carries 9-10 parameters each.

## Findings

- **[major][SIZE]** `run` spans ~156 lines mixing frontier scheduling, result classification,
  failure/pause persistence, completion commit, and emission. Owning seam: phase-private step
  methods (schedule/classify/commit) within Executor. (executor.rb:13-168)
- **[major][SIZE]** The checkpoint-transition family exceeds the ≤5-param ceiling:
  `append_noncommitting` (10), `append_failed_checkpoint` (10), `non_interactive_interrupt` (10),
  `append_paused_checkpoint` (9), `run`/`execute_task`/`execute_tasks` (6). Owning seam: a
  checkpoint-transition Data value threaded through the append paths.
  (executor.rb:172-202, 326-357, 382-416, 418-450, 490-501)
