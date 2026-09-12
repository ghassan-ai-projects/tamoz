# Audit 047 — `test/agent_worker_test.rb`

Rank 47 · 633 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: TEST, DEAD

Edge coverage around the unattended surface is real, but two cases bypass the public poll loop to
poke private Worker methods with hand-rolled Struct fakes.

## Findings

- **[major][TEST]** `worker.send(:resume_paused_entry, ...)` against a `Struct.new(:path)` fake
  runtime (modeling Worker's private interface inside the test) and
  `worker.send(:sleep_until_due)` with a swapped singleton clock probe private implementation.
  Owning seam: Worker's public run/poll surface the rest of the file exercises.
  (test/agent_worker_test.rb:252-272, 346-361)
- **[minor][DEAD]** `if ENV['TAMOZ_DEBUG'] warn(...)` diagnostic scaffold left committed in a test.
  Owning seam: remove, or fold into the AutonomyCase helper.
  (test/agent_worker_test.rb:548-550)

## Resolution — 2026-09-12

- **[major][TEST] FIXED** — `test_a_restart_reparks_a_clarification_with_its_typed_reason` is now black-box through `rt.cli(["worker", "--once"])`: a `needs_input` review pauses with reason `clarification_required` (asserted on the event), and the restart pass re-parks without claiming or failing (`worker.stopped` reports `parked: 1`); the `Struct.new(:path)` fake runtime and `worker.send(:resume_paused_entry, ...)` are gone. `test_the_idle_sleep_never_goes_negative...` now drives the public `worker.run` loop over a real `WorkerRuntime` with the scripted clock: the deadline crosses exactly once, the pass survives, and the next clock read (`ClockExhausted`) bounds the run — no `send(:sleep_until_due)`.
- **[minor][DEAD] FIXED** — the `ENV['TAMOZ_DEBUG']` diagnostic block removed.
