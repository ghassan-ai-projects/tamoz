# Audit 008 — `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb`

Rank 8 · 1232 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: SIZE, ERR, STATE

A clearly narrated composition root that has also absorbed the child-task subdomain and the
scheduled-work projection, with two writers bypassing its own `durable` error boundary.

## Findings

- **[major][SIZE]** The opened-runtime composition root also owns the child-task subdomain
  (create/enqueue/adopt, budget slot reserve/release with retry, transitions) and the scheduled-work
  read-model. Owning seam: a composed ChildTaskRuntime store and scheduled-work projection beside
  the existing bound stores. (worker_runtime.rb:190-655, 440-473, 919-994)
- **[minor][ERR]** `open_occurrence` and `record_budget_exhaustion` call `upsert` directly,
  bypassing the `durable` boundary every sibling read/write uses, so their failures skip the
  StoreUnavailableError contract callers are told to handle.
  (worker_runtime.rb:319-322, 421-426, 563-569)
- **[minor][STATE]** `Thread.current[:tamoz_agent_child_delegation_context]` is ambient
  thread-global input to session building. Owning seam: an explicit delegation-context parameter
  threaded through build_session. (worker_runtime.rb:717-732)

## Resolution — 2026-09-12 (round 5)

- **[minor][ERR] FIXED** — `open_occurrence` and `record_budget_exhaustion` now route their
  writes through the `durable` boundary, so their failures surface as `StoreUnavailableError`
  with the store contract callers already handle. Two further writers with the same bypass class,
  `bind_thread_profile` and `store_schedule_payload`, were wrapped too so the boundary is uniform
  (the typed `StoreConflictError` path passes through `durable`'s Tamoz::Error re-raise
  unchanged).
- **[minor][STATE] REJECTED** — the delegation context's consumer is
  `ChildTaskDispatcher#child_context` (frozen `tamoz-agent-capabilities`), which duck-calls
  `runtime.child_delegation_context` from deep inside session/toolbox construction. Threading the
  context explicitly through `build_session` means changing that cross-gem duck-type contract —
  reported as the seam instead of changed unilaterally.
- **[major][SIZE] REJECTED this round** — extracting a composed `ChildTaskRuntime` store and the
  scheduled-work projection is a new-file refactor in `gems/tamoz-agent`, which round 5 freezes
  to other agents' work; only `worker_runtime.rb` itself is in this round's set. Seam: the two
  stores land beside the existing bound stores (`@adapter`, `checkpoints`) with the child-task
  methods (`create/enqueue/adopt`, budget slot reserve/release, transitions) and the
  scheduled-work read model moving whole.
