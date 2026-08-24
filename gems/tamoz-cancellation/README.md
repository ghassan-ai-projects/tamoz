# tamoz-cancellation

How work is told to stop. Depends on `tamoz-core` only (Clock, SafeText, the
error hierarchy); it spawns no pools and joins no threads of its own.

## Public surface

- `Tamoz::CancellationToken` — cancel!/cancelled?/reason/wait(timeout:)/on_cancel
  with its Subscription/ClosedSubscription handles.
- `Tamoz::Cancellation::Trap` — `Trap.install(int:, term:) { body }` installs
  INT/TERM handlers that always defer to a fresh thread (`Mutex#synchronize`
  raises ThreadError in trap context) and restores the prior handlers on exit;
  `EXIT_CODES` maps `"sigint"` → 130, `"sigterm"` → 143.
- `Tamoz::Cancellation.interruptible_sleep(seconds, token:)` — sleep to a
  deadline, wake instantly on cancel; true when cancelled.
- `Tamoz::Cancellation::ProcessGroup` — `.alive?(pid)`, `.signal(pid, name)`,
  and `.terminate(pid, grace:, poll_interval:)` for TERM → wait → KILL → wait
  teardown against `-pid`.
- `Tamoz::Cancellation::VERSION`
