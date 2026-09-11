# Audit 064 — `test/progress_projection_test.rb`

Rank 64 · 554 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: TEST

Genuine milestone-projection coverage, but the worker tests install a recording sink by writing
the runtime's private ivar when the public injection seam already exists.

## Findings

- **[major][TEST]** `runtime.instance_variable_set(:@delivery_sink, ...)` probes WorkerRuntime
  private state — twice, including in the recovery flow — even though
  `WorkerRuntime.open(delivery_sink:)` is the public seam (worker_runtime.rb:42). Owning seam: the
  delivery_sink kwarg of WorkerRuntime.open. (test/progress_projection_test.rb:442-446, 501-505)
- **[minor][NAME]** Block params `_checkpoints` (bound at 33, used at 145 and every case) and
  `_worker` (448, used at 467/492) are underscore-marked as unused while load-bearing.
  (test/progress_projection_test.rb:33-145, 448-492)
- **[minor][DUP]** `drain_row` and `drain_row_without_receipt` copy the same three-step
  claim/mark-send/mark sequence, differing only in status and receipt. Owning seam: one
  status/receipt-parameterized helper. (test/progress_projection_test.rb:117-136)

## Resolution — 2026-09-11

- **[major][TEST] fixed.** Both `runtime.instance_variable_set(:@delivery_sink, ...)` sites
  (including the recovery flow) now call the new public
  `WorkerRuntime#install_delivery_sink(...)`.
- **[minor][NAME] fixed.** The load-bearing block params `_checkpoints` (10 sites) and
  `_worker` are no longer underscore-marked (`checkpoints`, `worker`).
- **[minor][DUP] fixed.** `drain_row_without_receipt` folded into
  `drain_row(store, id, status:, receipt:)` (defaults are the success case); the failed-drain
  caller passes `status: 'failed', receipt: nil`.
