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

- **[major][TEST] FIXED** — `test_a_restart_reparks_a_clarification_with_its_typed_reason` is now black-box through `rt.cli(["worker", "--once"])`: a `needs_input` review pauses with reason `clarification_required` (asserted on the event, first park only — a repark emits no event, so the restart pass is judged by `worker.stopped`'s parked count); the `Struct.new(:path)` fake runtime and `worker.send(:resume_paused_entry, ...)` are gone. `test_the_idle_sleep_never_goes_negative...` now drives the public `worker.run` loop over a real `WorkerRuntime` with a crossing-aware scripted clock: every read `poll_once` makes gets a constant pre-deadline time, and the crossing pair is served only to reads made inside `CancellationToken#wait` (caller-frame matched), after which any further read raises `ClockExhausted`. The test asserts both that the run ends in `ClockExhausted` (the loop survived the crossing) and `clock.crossed_in_wait?` (the crossing was consumed by the sleep path, not by poll's store reads — the earlier three-reading script was vacuous, since `poll_once`'s store operations alone exhausted it with the sleep path never reached). Mutation-proven: with `Cancellation.interruptible_sleep` returning immediately, the test FAILS ("ClockExhausted expected but nothing was raised" — the watchdog `stop!` ends the token-less spin); restored, it passes.
- **[minor][DEAD] FIXED** — the `ENV['TAMOZ_DEBUG']` diagnostic block removed.
