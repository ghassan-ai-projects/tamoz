# Two gems: `tamoz-concurrency` and `tamoz-signals`

Findings and design from a deep scan of the current tree (no guessing — every
claim below cites `file:line`). The brief: **abstract only what we already have**,
not a production-grade concurrency framework. So the target API surface is sized
to today's call sites, and anything speculative (fiber pools, distributed
coordination, new backpressure policies) is explicitly out of scope.

Scan coverage: 92 concurrency-primitive hits and 37 signal hits across
`gems/` (excluding tests and worktrees). The primitives cluster into a small
number of repeated skeletons, which is exactly what makes two gems worth cutting.

---

## 1. What "signals" means here — three distinct things

The word is overloaded in this codebase. Being precise about it is the first
design decision, because two of the three are control-plane and one is data-plane.

| Meaning | Where | In scope for a "signals" gem? |
|---|---|---|
| **Cancellation signal** — cancel!/cancelled?/wait/on_cancel | `tamoz-core/.../cancellation_token.rb`; consumed in **14 files, 148 refs** | **Yes — this is the core of it** |
| **OS signals** — `Signal.trap("INT"/"TERM")`, `Process.kill(TERM/KILL)` | CLI (3 files) + supervisor/check_runner teardown | **Yes** |
| **Telemetry "Signal"** — an observability value object recorders ingest | `tamoz-observability/.../signal.rb`, `signal_catalog.rb` | **No — data-plane, leave in observability** |

There is a genuine naming collision: `Tamoz::Observability::Signal` already
exists and means "a telemetry record," not "a control signal." A gem literally
named `tamoz-signals` would sit next to it and mean the opposite thing. See
§6 (Naming) — this is the one decision I'd want your call on.

---

## 2. The concurrency skeletons that actually repeat

Four skeletons carry essentially all the weight. Each is re-implemented by hand
today; each is a clean extraction target.

### 2.1 Bounded-buffer background drain worker  ← **the biggest win**

A mutex + `ConditionVariable`, a bounded in-memory buffer, a `record`/`emit`
under the lock that signals the condition, a background thread running a
`drain`/`run` loop that waits on the condition, a `flush(deadline_ms:)`, and a
`close` that broadcasts and joins the thread with a deadline.

Re-implemented, nearly identically, in **five** places:

- `tamoz-otel/.../async_exporter.rb:8` — queue + condition + `run`/`deliver`, `flush(deadline_ms:)` at :64, `close(deadline_ms:)` at :76
- `tamoz-observability/.../recorders.rb:124` (`Journal`) — reserved+bulk queues + condition + `drain` at :299, `flush(deadline_ms:)` at :261, `close` at :274
- `tamoz-sqlite/.../connection_pool.rb:5` — condition-var checkout with a deadline (:94), broadcast on close (:62)
- `tamoz-sqlite/.../lease.rb:21` — mutex + condition + `wait(interval)` (:77) + broadcast (:59)
- `tamoz-core/.../stream_sink.rb:40` — `SizedQueue` + state mutex + emit under lock + cancellation-driven close

`flush(deadline_ms:)` alone is hand-written **7 times** (grep: `def flush(deadline_ms`).
The exponential-backoff-on-failure variant (`async_exporter.rb:124`) and the
disk-rotation variant (`recorders.rb:351`) are policy on top of the same
skeleton — the skeleton is what should be shared, the policy stays local.

### 2.2 Bounded parallel map (thread pool)

`tamoz-core/.../pool.rb` — `Pool.for(:inline|:threads)`, bounded work via
`SizedQueue`, a stuck-worker circuit breaker (`:191`–`:369`), join-with-grace,
and first-class cancellation. Already a good abstraction; it's just living in
`core` next to unrelated things. Consumers: `worker.rb:207`, `graph/compiled.rb:40-41`.
The `:fibers` branch is an intentional stub that raises (`pool.rb:36`) — keep it
a stub; do not build it out (out of scope).

### 2.3 Producer-in-thread → single-consumer stream, join-with-grace

`tamoz-graph/.../event_stream.rb:5` — runs a producer in a `Thread`, consumes
via a sink, `join!`s with a grace deadline (:88), exactly one consumer enforced
under a mutex. Pairs with `StreamSink` (`stream_sink.rb`), which enforces
one-consumer (:182) and closes on cancellation (:47). These two are one pattern
split across two gems.

### 2.4 Interruptible sleep / wait-until-deadline

"Sleep until a deadline, but wake the instant we're told to stop." Written by
hand in ~10 files (grep: `deadline = .*monotonic`), canonical version at
`worker.rb:1074` (`sleep_until_due`), plus the subprocess teardown waits in
`supervisor.rb:402` (`wait_for_group_exit`) and `check_runner.rb`. All of them
re-derive the same "monotonic deadline, poll a stop condition, min-sleep" loop.
`CancellationToken#wait(timeout:)` (`cancellation_token.rb:84`) is already the
condition-variable version of this and should be the primitive the others call.

---

## 3. The signal skeletons that repeat

### 3.1 OS trap → cancellation, trap-safe, save/restore

The same block, three times:

- `cli.rb:638` — `install_signal_handlers`: trap INT/TERM → `@cancellation.cancel!`, restore old handlers in `ensure`
- `cli_worker_commands.rb:297` — trap INT/TERM → `Thread.new { worker.stop!(...) }`, restore in `ensure`
- `cli_comms_commands.rb:126` — trap INT/TERM → `Thread.new { stop_loops(...) }`, restore in `ensure`

Two non-obvious invariants are duplicated by hand and are exactly what an
abstraction should carry so they can't be forgotten:

1. **Trap-safety**: the handler must not take a `Mutex` directly —
   `Mutex#synchronize` raises `ThreadError` in trap context, so the work is
   deferred to a `Thread.new`. This is documented in-line at
   `cli_worker_commands.rb:293-296` and is the kind of rule that gets lost on
   the fourth copy.
2. **Save/restore**: handlers are restored on the way out so the code is safe to
   call in-process (tests, embedding). Done in every `ensure` above.

Exit-code mapping lives separately (`cli.rb:13-14` `EXIT_SIGINT=130 / EXIT_SIGTERM=143`,
consumed by reason string in `cli_rendering.rb:123`). It belongs with the trap.

### 3.2 Process-group teardown ladder (SIGTERM → grace → SIGKILL)

- `mcp/supervisor.rb:276` (`close`) — close pipes, `wait_for_group_exit`, then
  TERM → grace → KILL against the **process group** (`-pid`), via
  `signal_process_group` (:396) and `process_group_alive?` (:385, `kill(0, -pid)`)
- `tools/check_runner.rb:97` (`terminate_group`) — TERM → `join(1)` → KILL, with
  a fallback to a direct-pid kill when the group kill is denied (:107-116)

Same escalation ladder, same `Errno::ESRCH/EPERM/ECHILD` handling, twice.

---

## 4. Proposed split

Two gems, with a **one-way dependency**: concurrency depends on signals, never
the reverse. Signals is the lower layer (coordination primitives + OS glue, spawns
no pools of its own); concurrency is the upper layer (spawns and joins threads,
and *consumes* cancellation signals).

```
  tamoz-concurrency  ──depends-on──▶  tamoz-signals  ──depends-on──▶  tamoz-core
   (pools, drains,                     (cancellation token,            (Clock, errors,
    streams, joins)                     OS traps, process kill)         SafeText)
```

### `tamoz-signals` — "how work is told to stop, and how stopping is observed"

Move + lightly generalize what exists. No new behavior.

- **`CancellationToken`** — moved verbatim from `tamoz-core`. It already is the
  cancellation *signal*: `cancel!`, `cancelled?`, `reason`, `wait(timeout:)`,
  `on_cancel { }` + `Subscription`/`ClosedSubscription`. 14 files depend on it,
  so relocation needs a compat shim (§5).
- **`Signals::Trap`** — one object that wraps §3.1: `Trap.install(int:, term:) { block }`,
  trap-safe by construction (defers to a thread), restores prior handlers on
  exit, and exposes the 130/143 exit-code mapping. Collapses the three CLI copies.
- **`Signals.interruptible_sleep(interval, token:)`** — the §2.4 primitive,
  backed by `CancellationToken#wait`. Replaces `sleep_until_due` and friends.
- **`Signals::ProcessGroup.terminate(pid, grace:)`** — the §3.2 TERM→grace→KILL
  ladder with the shared `Errno` handling and process-group liveness check.
  (It's literally about *sending signals*, hence here; it needs a monotonic
  deadline, which comes from `tamoz-core`'s `Clock`.)

### `tamoz-concurrency` — "thread execution machinery"

- **`Pool`** — moved from `tamoz-core/pool.rb` unchanged (`:inline`/`:threads`,
  stuck-worker circuit, cancellation). Keep the `:fibers` stub as-is.
- **`Concurrency::Drain`** (working name) — the §2.1 skeleton extracted: a
  bounded buffer, a background thread, `record`/`push`, `flush(deadline_ms:)`,
  `close(deadline_ms:)`, with a pluggable `#deliver(batch)` and an optional
  wait-interval. `AsyncExporter`, `Journal`, and the connection-pool/lease waits
  become thin policy layers over it. **This is the extraction that removes the
  most duplicated, most bug-prone code.**
- **`StreamSink` + `EventStream`** — moved together (they're one pattern, §2.3):
  bounded stream, single-consumer enforcement, producer thread, join-with-grace.
- **Join helpers** — `join_all(threads, deadline:)` extracted from the copies in
  `pool.rb:354` (`join_workers`) and `event_stream.rb:88` (`join!`).

Error classes already live centrally in `tamoz-core/error.rb`
(`PoolCircuitOpenError:196`, `PoolWorkerError:201`, `StreamClosedError:191`,
`StateLimitError:254`, `FatalRuntimeFailure:7`) — leave them in core so both
gems and their consumers keep sharing one hierarchy.

---

## 5. Blast radius & migration

The one structural risk is relocating `Tamoz::CancellationToken` out of `core`:
**14 files, 148 references** (`grep -rE 'CancellationToken|on_cancel|cancellation:'`).
Consumers span `core`, `agent`, `agent-cli`, and all of `graph`
(`durable_request_executor`, `executor`, `fork_executor`, `lifecycle_executor`,
`run_coordinator`, `writer_run_executor`).

Migration that keeps every caller compiling:

1. Create `tamoz-signals`, move the class, and re-expose it from `tamoz-core` as
   `Tamoz::CancellationToken = Tamoz::Signals::CancellationToken` (a constant
   alias, `tamoz-core` gains a dep on `tamoz-signals`). No call site changes.
2. Create `tamoz-concurrency`, move `Pool`/`StreamSink`/`EventStream`, alias the
   old constants from `core` the same way. Update the two `Pool.for` call sites'
   require lines only.
3. Extract `Concurrency::Drain` and refactor `AsyncExporter`/`Journal` onto it
   **last** — it's the only step that changes behavior-bearing code, so it lands
   on its own with its own tests.

Per the repo's `enola.md` rule, this is a "blast radius is not obvious" change:
run `impact_analysis` on `CancellationToken` and `Pool` and `set_baseline`
**before** step 1, then `diff_snapshot` after each step. A new dependency cycle
(e.g. if `core` aliasing signals accidentally makes signals need core need
signals) is the specific thing to watch — the `Clock` dependency from signals →
core is the edge to keep one-way.

---

## 6. Naming (needs your call)

`tamoz-signals` collides conceptually with `Tamoz::Observability::Signal`
(telemetry records). Options, in my order of preference:

1. **`tamoz-cancellation`** + **`tamoz-concurrency`** — most honest; the gem is
   ~90% the cancellation token by usage. "Signals" (OS + process kill) ride along
   as `Cancellation::Trap` / `Cancellation::ProcessGroup`. Zero collision.
2. **`tamoz-signals`** as you proposed — fine if we accept that "signal" means
   control-plane here and telemetry's `Signal` is a different word in a different
   namespace. Cheapest to explain to a newcomer only if we document the split.
3. **`tamoz-lifecycle`** — captures cancel + traps + teardown together, but is
   vaguer than either.

I'd go with **(1)**. Everything else in this doc is independent of the name.

---

## 7. Explicitly out of scope (honoring "not a production package")

- The `:fibers` pool branch stays a raising stub (`pool.rb:36`).
- No new backpressure/eviction policies — extract the buffer skeleton, keep each
  caller's existing drop policy local (queue-full drops in `async_exporter.rb:42`,
  reserved-vs-bulk lanes in `recorders.rb:222`).
- No distributed/cross-process coordination. `ProcessGroup.terminate` wraps the
  two `Process.kill` ladders we already have and nothing more.
- Telemetry `Signal`/`Catalog`/recorders stay in `tamoz-observability`.
- Domain logic (child-task budgets, approval sessions, schedule claims in
  `worker_runtime.rb`) is not concurrency machinery and does not move.

---

## Appendix — primary evidence index

| Concern | File:line |
|---|---|
| Cancellation token (the signal) | `gems/tamoz-core/lib/tamoz/cancellation_token.rb:1` |
| Thread pool + stuck-worker circuit | `gems/tamoz-core/lib/tamoz/pool.rb:122` |
| Bounded stream, single consumer | `gems/tamoz-core/lib/tamoz/stream_sink.rb:40` |
| Producer thread + join-with-grace | `gems/tamoz-graph/lib/tamoz/graph/event_stream.rb:70` |
| Drain skeleton (exporter) | `gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb:94` |
| Drain skeleton (journal) | `gems/tamoz-observability/lib/tamoz/observability/recorders.rb:299` |
| Condition-var checkout + deadline | `gems/tamoz-sqlite/lib/tamoz/sqlite/connection_pool.rb:94` |
| OS trap → cancel (CLI) | `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:638` |
| OS trap → stop, trap-safe | `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:297` |
| TERM→grace→KILL (supervisor) | `gems/tamoz-mcp/lib/tamoz/mcp/supervisor.rb:276` |
| TERM→KILL (check runner) | `gems/tamoz-tools/lib/tamoz/tools/check_runner.rb:97` |
| Interruptible sleep-to-deadline | `gems/tamoz-agent/lib/tamoz/agent/worker.rb:1074` |
| Telemetry Signal (do NOT move) | `gems/tamoz-observability/lib/tamoz/observability/signal.rb:1` |
