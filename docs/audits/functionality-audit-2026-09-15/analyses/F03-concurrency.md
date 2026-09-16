# F03 `tamoz-concurrency` — IMPROVE: the bounds are real, but two of the three loss paths are silent and `close` does not mean "accepted work completed"

Row / queue / baseline: F03 / W2B (cancellation / concurrency / scheduler) / branch `audit-15-09`, commit `582ae55`, 2026-09-15 / analyst: F03 independent read-only analyst / budget: ~40 min

## Scope and source map

Source surface read in full (6 files + gemspec, 995 lines):

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-concurrency/lib/tamoz/concurrency.rb` | 35 | entry seam; requires; `Concurrency.join_all` shared-budget join |
| `gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb` | 224 | the shared-budget bounded-lane drain base class (core claim) |
| `gems/tamoz-concurrency/lib/tamoz/concurrency/event_stream.rb` | 103 | single-consumer graph event stream over a sink |
| `gems/tamoz-concurrency/lib/tamoz/pool.rb` | 378 | inline/threads bounded pool + stuck-worker circuit |
| `gems/tamoz-concurrency/lib/tamoz/stream_sink.rb` | 231 | single-consumer bounded `SizedQueue` stream sink |
| `gems/tamoz-concurrency/lib/tamoz/concurrency/version.rb` | 7 | version |
| `gems/tamoz-concurrency/tamoz-concurrency.gemspec` | 17 | deps: `tamoz-cancellation`, `tamoz-core` only |

**Entry seam.** `gems/tamoz-concurrency/lib/tamoz/concurrency.rb:8-15` requires `tamoz/core` and
`tamoz/cancellation` and then defines four public surfaces. The gem has exactly two runtime
dependencies and no dependency on observability, graph, otel, or comms — the error hierarchy
(`PoolCircuitOpenError`, `PoolWorkerError`, `StreamClosedError`, `StateLimitError`) deliberately
stays in `tamoz-core` (`concurrency.rb:5-7`). Read the caller trace as: this gem is a *library of
bounds* that four other gems build policy on.

Caller trace (every real consumer, read end to end):

| Consumer | Path | What it uses |
|---|---|---|
| `tamoz-observability` | `recorders/../recorder_journal.rb:13` | `Journal < Concurrency::Drain` — the reserved/bulk drop ledger |
| `tamoz-otel` | `otlp/../otel/async_exporter.rb:9` | `AsyncExporter < Concurrency::Drain` — bounded export + backoff |
| `tamoz-graph` | `graph/lifecycle_executor.rb:66` | `Concurrency::EventStream.new(sink:, join_grace:)` |
| `tamoz-graph` | `graph/lifecycle_executor.rb:116` | `StreamSink.new(capacity:, cancellation:, run_id:)` |
| `tamoz-agent-cli` | `agent/cli.rb:391` | `Tamoz::StreamSink.new(cancellation:, run_id:)` + `Graph::StreamEmitter` |
| `tamoz-agent` | `agent/worker.rb:214` | `Tamoz::Pool.for(:threads,:inline, size:, max_tasks:, cancellation:)` |
| `tamoz-graph` | `graph/compiled.rb:194-195` | `Pool.for(:inline/:threads, max_tasks: limits.max_tasks_per_step)` |
| `tamoz-comms-gateway` | `comms/delivery_drainer.rb` | **does NOT use `Drain`** — hand-rolled loop (see F03-MNT-01) |

`DeliveryDrainer` (`gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:12`) is a
"drainer" by name only: it is a synchronous `serve_loop`/`drain_once` over SQLite claims
(`:28-57`) with no bounded queue, no background thread, and no `Concurrency::Drain` at all.

## Behavior path

**A. Pool (`worker.rb:214` → `pool.rb`).**
`Pool.for(mode, ...)` (`pool.rb:13-40`) dispatches. `:inline` → `Inline#map` (`111-120`);
`:threads` → `Threads#map` (`148-159`); `:fibers` raises `ConfigurationError` (`36`).
`Threads#execute_threads` (`197-243`) builds `SizedQueue.new(queue_capacity)` (`198`), spawns
`min(size, values.length)` workers (`202-210`), registers `token.on_cancel { work.close }` (`211`),
submits (`212`), closes, then `collect`s (`215-223`) and joins (`224-228`).

**B. StreamSink (`cli.rb:391`, `lifecycle_executor.rb:116`).**
`emit` (`stream_sink.rb:42-63`) takes `@emit_mutex`, builds the `StreamPart`, reserves a sequence
under `@state_mutex` (`169-182`), then `@queue.push(part)` on a `SizedQueue.new(capacity)` (`30`, `58`).
`each` (`65-85`) calls `begin_consumer!` (`200-206`, one-consumer guard) and pops until `nil`.
`finish` (`87-100`) closes the queue. `close` (`102-121`) closes the queue and cancels the token.

**C. EventStream (`lifecycle_executor.rb:66`).**
`EventStream#each` (`event_stream.rb:31-50`) marks the consumer, `start!`s a coordinator thread
(`70-86`) that runs the block and `sink.finish`es in its `ensure` (`82`), then consumes the sink.
`join!` (`88-98`) joins the coordinator within `@join_grace` and synthesises a `PoolWorkerError`
if it is still alive (`95-97`).

**D. Drain (`recorder_journal.rb:13`, `async_exporter.rb:9`).**
`Drain#initialize` (`drain.rb:13-27`) validates lanes, builds per-lane arrays, and starts the
drain thread. `push` (`31-33`) → `accept` (`101-112`) enforces the per-lane bound. The drain
thread loops `take_batch` → `deliver_batch` → `delivery_result` (`166-187`).

**E. The shared budget (`concurrency.rb:24-33`).**
`join_all(threads, deadline:)` computes one `finish` monotonic instant and joins each thread with
the *remaining* budget; once spent it `break`s, leaving threads unjoined but visible via `alive?`.

## Lens: correctness

**Verified (proven).**
- Per-lane bounds are enforced on the producer side and refuse with `false`, never grow:
  `accept` returns `false` when `queue.length >= @lanes.fetch(lane)` (`drain.rb:107`) and the
  lane limit is validated as a positive Integer at construction (`82-87`).
- Unknown lanes are rejected *after* the closed/disabled checks but before any mutation, so a bad
  lane raises `ConfigurationError` without corrupting queues (`drain.rb:104-106`; test
  `test/concurrency_drain_test.rb:159-166` asserts depths stay `{a: 0}`).
- `pool.rb` refunds every task index: `collect` backfills `Stuck`, `Cancelled(worker_unavailable)`
  and `Cancelled(not_scheduled)` (`pool.rb:319-332`) so `map` always returns `values.length`
  results. Probe 16: 100 tasks through a `size: 2` pool returned 100/100 successes.
- Out-of-order delivery is preserved by index (`pool.rb:231-238`, `collected.fetch(index)`).
- `StreamSink` is lossless for a *slow but live* consumer: `SizedQueue#push` blocks the producer
  (`stream_sink.rb:58`). Probe 18: producer emitted 50, slow consumer saw 50, sequences
  contiguous `0..49`.

**Broken (proven, see findings).**
- `Drain#close` returns `nil` regardless of how much accepted work it abandoned
  (`drain.rb:67-76`). Probe 9: `close(deadline_ms: 50)` returned in 0.055 s with
  `depths + in_flight == 10` and `delivered == 0/10` — the caller cannot distinguish a clean
  close from an abandoned one.
- `StreamSink#finish` closes the queue while a producer is blocked inside `push`, converting a
  normal backpressure wait into a `StreamClosedError` on the producer
  (`stream_sink.rb:58` + `87-100`). Probe 15: producer `status == "sleep"` before `finish`,
  `captured == Tamoz::StreamClosedError` after, with 4 queued events discarded.

**Not evidenced.** No test asserts `Drain#close`'s leftover count, because the method returns
`nil`; `test/concurrency_drain_test.rb:143-157` only asserts `close` *returns within the grace*
(elapsed `< 5.0`), which is compatible with dropping everything.

## Lens: security and authority

**Reviewed — no authority path.** This gem grants no capability, reads no credential, and touches
no policy data. The gemspec declares only `tamoz-cancellation` and `tamoz-core`
(`tamoz-concurrency.gemspec:13-16`), so there is no egress or filesystem authority here. The only
file I/O reachable through this gem is its consumers' (`recorder_journal.rb:203` opens the journal
`File.open(path, 'ab', 0o600)` and chmods `0o600`), which is outside F03's surface.

**Verified.** Refusal is by return value, not by widening: `push` returns `false` and the caller
owns the accounting (`drain.rb:29-33`). No raise is swallowed into a silent success.

**Not evidenced / not applicable.** No negative-authority test exists and none is warranted — the
gem has no trust boundary of its own.

## Lens: reliability and durability

**Verified.**
- A raising delivery disables the drain and ends the thread rather than spinning:
  `drain_loop` rescues `StandardError`, calls `handle_loop_error`, and `break`s
  (`drain.rb:171-187`); `Journal#handle_loop_error` disables (`recorder_journal.rb:132-134`),
  and `AsyncExporter#handle_loop_error` calls `disable_drain!` (`async_exporter.rb:98-100`).
  `test/concurrency_drain_test.rb:130-141` proves `disabled?` is set and the thread is dead.
- `@in_flight` is decremented in an `ensure` (`drain.rb:176-180`), so a raise inside
  `deliver_batch` cannot leak in-flight count and wedge `flush`.
- `AsyncExporter` resets `@failures` to 0 on success and caps backoff at 30 s
  (`async_exporter.rb:80-96`).

**Broken (see findings).**
- Shutdown is not a barrier: `close` can return with accepted work still in flight (probe 9).
- `AsyncExporter#on_thread_exit` calls `@exporter.close(deadline_ms: 0)`
  (`async_exporter.rb:102-104`) — a zero-millisecond grace for the downstream exporter, so the
  export client is asked to close without being given any time.
- `Drain#close` swallows *every* `StandardError` from `@thread.join` via a bare
  `rescue StandardError; nil` (`drain.rb:74-75`), so a failure while joining is indistinguishable
  from success.

**Not evidenced.** No crash-recovery test exists for `Drain`: nothing proves what happens to the
in-memory lanes when the process dies mid-batch. This is inherent (the queues are not durable —
`drain.rb:20` allocates plain arrays) and is the consumers' durability responsibility, but F03
does not state that contract.

## Lens: observability and evidence

**Verified.**
- The bounded-recorder drop ledger is real and counted, per reason:
  `Journal#accept_or_drop` (`recorder_journal.rb:90-97`) distinguishes `closed`, `disabled`,
  `queue_full`, and reserved-lane local-write fallback; `drop_signal` increments a
  reason-keyed counter (`111-115`) and `persist_health` writes the sidecar (`220-224`).
  `Files.inventory` sums the sidecar (`325-333`), so drops survive process death.
- `AsyncExporter#record` counts `closed`/`disabled`/`queue_full` separately
  (`async_exporter.rb:34-47`) and `health` exposes `queue_depth`, `drops`, `failures`, `disabled`
  (`49-58`).
- `Journal#health` exposes reserved/bulk depth, drops, `journal_disabled`, path and policy digest
  (`recorder_journal.rb:59-71`), so a full bulk lane is visible as depth, not as silence.

**Broken (see findings).**
- The *stream* path has no drop accounting at all: `StreamSink` silently discards the queue
  backlog when `finish`/`close` closes the queue (`stream_sink.rb:90-121`) and exposes only
  `size` (`135-137`). Probe 15 measured 4 events dropped with no counter.
- `Drain#close` returns `nil`, so the drain's own abandonment count is not observable
  (`drain.rb:67-76`), even though `flush` *does* return the leftover count (`53-64`).

**Not evidenced.** No test asserts that a stream's dropped-event count is zero or otherwise
accounted; `test/concurrency_drain_test.rb` covers only the Drain-side ledger.

## Lens: scalability and resource bounds

**Verified — every queue in the gem is bounded.**
- Drain lanes: per-lane positive-Integer limit, enforced at `accept` (`drain.rb:107`).
- `StreamSink`: `SizedQueue.new(capacity)` with `validate_capacity!` bounding `1..MAX_STREAM_BUFFER`
  (65 536, `stream_sink.rb:5`, `141-145`); default 32 via `Tamoz.configuration.stream_buffer`
  (`stream_sink.rb:12`, `gems/tamoz-core/lib/tamoz/configuration.rb:16`).
- `StreamSink` namespaces: `max_namespaces` bounded to `65 536`, enforced on first-touch with a
  typed `StateLimitError` (`stream_sink.rb:7`, `161-167`, `176-178`).
- Pool: `max_tasks` capped at `MAX_TASKS` 1 000 000 (`pool.rb:6`, `46-48`), `bounded_items`
  raises when input exceeds it (`64-77`), `queue_capacity` capped at 65 536 (`7`, `178-183`),
  pool size capped at `Configuration::MAX_POOL_SIZE` 256 (`172-176`).
- `EventStream` joins within `join_grace` ≤ 60 s (`event_stream.rb:14-18`, `88-98`).
- `Drain` interval validated finite and positive (`drain.rb:91-93`).

**Correct producer-side enforcement.** A full pool queue blocks the submitter rather than
growing (`pool.rb:277`, `SizedQueue#push`), and `ClosedQueueError` breaks the submit loop (`279-280`).
Probe 16 confirmed 100 tasks through a capacity-4 queue completed with 100 results.

**Not evidenced.** No load/soak test exists that drives any of these bounds to saturation and
records the steady-state memory; the bounds are proven by construction and by unit tests only.

## Lens: maintenance and architecture

**Verified.**
- `Drain` is a genuine shared base: the two real consumers each keep only their own policy in
  template methods — `Journal` overrides `compose_batch`/`deliver_batch`/`handle_loop_error`/
  `on_thread_exit` (`recorder_journal.rb:124-138`) and `AsyncExporter` overrides
  `due?`/`wait_timeout`/`compose_batch`/`deliver_batch`/`delivery_result`/`handle_loop_error`/
  `on_thread_exit` (`async_exporter.rb:62-104`). The class comment's claim that drop accounting and
  backoff stay in subclasses (`drain.rb:9-11`) is accurate.
- Dependency direction is honest: concurrency depends only on core + cancellation.
- `public_api_test.rb:154-157` pins `Tamoz::Concurrency::Drain` and `join_all` as public surface.

**Weakness (see F03-MNT-01).** `DeliveryDrainer` re-implements a drain without the base class.

## Tests and contracts

Run (one file per command, `ruby -Itest test/<file>.rb`):

| Command | Result |
|---|---|
| `ruby -Itest test/concurrency_drain_test.rb` | 7 runs, 36 assertions, **0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/core_pool_test.rb` | 11 runs, 137 assertions, **0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/delivery_drainer_test.rb` | 10 runs, 50 assertions, **0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/observability_runtime_test.rb` | 13 runs, 53 assertions, **0 failures, 0 errors, 0 skips** |

Not run: `test/observability_cli_test.rb`, `test/observability_catalog_test.rb`,
`test/observability_correlation_test.rb`, `test/observability_signal_test.rb`,
`test/agent_outbox_delivery_sink_test.rb` — time budget; they exercise the observability gem's own
surface (F-row), not F03's bounds. `rake ci` / `rake ci_full` deliberately not run per brief.

Not found: there is **no** test named `*_stream_sink_test.rb` and no `*_event_stream_test.rb`.
`test/concurrency_drain_test.rb` is the only dedicated F03 test file; StreamSink/EventStream are
covered only indirectly through graph and CLI tests. This absence is the reason F03-REL-01 and
F03-OBS-01 went unnoticed.

Reproducible probes (all in `/tmp/f03/`, none in the repo):
`probe9_grace_drop.rb`, `probe14_emit_block.rb`, `probe15_final.rb`, `probe16_pool.rb`,
`probe18_lossless.rb`, plus rejected-hypothesis probes `probe10_doublelock.rb`,
`probe12.rb`, `probe11.rb`.

## Findings

### F03-REL-01 — `StreamSink#finish` kills a producer blocked in `emit` and drops the backlog

- **Severity**: major
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-concurrency/lib/tamoz/stream_sink.rb:58` (`@queue.push(part)`
  blocks on a full `SizedQueue`), `stream_sink.rb:87-100` (`finish` closes the queue),
  `stream_sink.rb:61-62` (`rescue ClosedQueueError → raise StreamClosedError`),
  `stream_sink.rb:30` (the `SizedQueue` bound, default 32).
  Consumer path: `gems/tamoz-graph/lib/tamoz/graph/lifecycle_executor.rb:82` and `:90`
  (`sink&.finish`), `gems/tamoz-graph/lib/tamoz/graph/stream_emitter.rb:32-35` (swallows
  `StreamClosedError` **only** when `@sink.cancellation.cancelled?`).
- **Test/contract evidence**: `not found` — no `*_stream_sink_test.rb` exists. Reproduced by
  `/tmp/f03/probe15_final.rb`: with `capacity: 4`, the producer thread's `status` was `"sleep"`
  (blocked in `push`); after `sink.finish` the thread was dead with
  `captured == Tamoz::StreamClosedError` and `sink.size == 4` events discarded.
  `/tmp/f03/probe18_lossless.rb` shows the intended behavior (slow-but-live consumer is lossless),
  isolating `finish` as the trigger.
- **Scanner signal**: caller trace of `StreamSink.new` found exactly two construction sites
  (`lifecycle_executor.rb:116`, `agent/cli.rb:391`).
- **Independent judgment**: **confirmed**. This is not the ordinary "slow consumer" case — the
  slow-consumer case is correct and lossless. The defect is that `finish` closes the queue under a
  *blocked* producer, so a normal shutdown converts backpressure into a producer exception plus
  silent event loss. In the graph path the emitter runs on the coordinator thread that calls
  `sink.finish` in its own `ensure`, and `stream_emitter.rb:33` re-raises because the token is not
  cancelled, so the loss is also reported as a run error rather than as a dropped-event count.
  I explicitly rejected the alternative hypothesis that the producer merely stays blocked
  (`probe14` showed the thread dies).
- **Root cause (five whys)**:
  1. A producer blocked in `emit` receives `StreamClosedError` when the stream finishes.
  2. Because `finish` closes the `SizedQueue` (`stream_sink.rb:93`) while `push` is waiting on it.
  3. Because `finish` knows only the queue's open/closed state, not whether a producer is inside
     `push`, and the `@emit_mutex` that would reveal it is never consulted by `finish`.
  4. Because the class treats the queue's closed flag as the single shutdown signal, so "closed for
     new work" and "no producer is mid-emit" are conflated into one operation.
  5. Because there is no test for the finish-while-backpressured interleaving — no
     `*_stream_sink_test.rb` exists — so the contract "finish never loses an accepted event" was
     never stated or enforced at the seam.
  Contract that would prevent recurrence: `finish` must be a drain-then-close — it either waits
  for an in-progress `emit` to land or returns a count of events it abandoned.
- **Recommendation**: smallest credible action at the existing seam — take `@emit_mutex` inside
  `finish` (`stream_sink.rb:87-100`) before closing the queue, so an in-progress `emit` completes
  its `push` first, and return a boolean/count of events discarded instead of the current bare
  `changed`. No new class, no queue type change.
- **Disposition**: `open` — requires independent challenge; the reviewer should confirm whether
  `@emit_mutex` acquisition in `finish` can deadlock against `@state_mutex` (lock order is
  `@emit_mutex` → `@state_mutex` in `emit`, and `finish` currently takes `@state_mutex` only, so
  the ordering must be respected).

### F03-REL-02 — `Drain#close` returns `nil`, so an abandoned drain is indistinguishable from a clean one

- **Severity**: major
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb:67-76` — `close`
  joins `@thread` for `deadline_ms` and returns `nil` unconditionally, with a bare
  `rescue StandardError; nil` at `74-75` swallowing join failures. Contrast `flush`
  (`drain.rb:53-64`), which *does* return `outstanding`. Consumer: `Journal#flush` /
  `DurableRecorder#close` discards the count —
  `gems/tamoz-agent/lib/tamoz/agent/durable_recorder.rb:26` calls
  `@recorder.flush(deadline_ms: FLUSH_DEADLINE_MS)` and ignores the return value.
- **Test/contract evidence**: `test/concurrency_drain_test.rb:143-157` asserts only that `close`
  returns within the grace (`elapsed < 5.0`); it does not assert what was delivered. Reproduced by
  `/tmp/f03/probe9_grace_drop.rb`: `close(deadline_ms: 50)` returned `nil` after 0.055 s with
  `depths + in_flight == 10` and `delivered == 0/10`.
- **Scanner signal**: `grep '< Drain'` found two subclasses; both call `close` without inspecting a
  result (`recorder_journal.rb` via `DurableRecorder`, `async_exporter.rb` via CLI shutdown).
- **Independent judgment**: **confirmed**. The `flush`-then-close contract holds only if the caller
  *checks* `flush`; `DurableRecorder#close` does not. `Journal` never flushes before closing in the
  CLI shutdown path either, so a signal accepted into a lane and not yet delivered at shutdown is
  lost with no counter — the drop ledger records only `closed` refusals *after* the flag flips
  (`recorder_journal.rb:99-102`), never the items already inside the lane.
- **Root cause (five whys)**:
  1. Signals accepted into a drain lane can be lost at shutdown with no record.
  2. Because `close` gives the drain thread a grace period and then returns without reporting what
     it abandoned.
  3. Because `close`'s return value is `nil` by construction (`drain.rb:73`) — information the class
     already holds (`outstanding`, `drain.rb:137-139`) is simply not returned.
  4. Because the skeleton was designed so cancellation of the thread is the shutdown signal, and the
     "how much did I lose" question was deferred to callers, but no caller was given a value to
     check.
  5. Because the only shutdown test asserts a time bound rather than a completeness bound, so the
     contract "close reports abandoned work" was never written down.
  Contract that would prevent recurrence: `close` returns the count of items it could not deliver.
- **Recommendation**: smallest credible action at the existing seam — make `close` return
  `outstanding` (the value `flush` already computes at `drain.rb:62`) after the join, and hoist the
  `rescue` so a join failure is not silently equated with success. Callers that ignore the value
  keep working unchanged; `DurableRecorder#close` can then flush-then-check.
- **Disposition**: `open` — pairs with F03-REL-01 as the same class of defect (shutdown does not
  mean accepted work completed) on the two different seams.

### F03-OBS-01 — a drained stream's backlog is discarded with no counter

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-concurrency/lib/tamoz/stream_sink.rb:107-117` (`close` closes the
  queue under `@state_mutex`) and `87-100` (`finish`), neither of which records how many queued
  parts were discarded; the class exposes only `size` (`135-137`) and `closed_reason` (`131-133`).
  By contrast the Drain-side ledger is explicit (`recorder_journal.rb:111-115`).
- **Test/contract evidence**: `not found` — no test asserts an abandoned-event count for a stream.
  Probe 15 measured `sink.size == 4` discarded at `finish`.
- **Scanner signal**: `grep 'StreamClosedError'` returned only the raise sites in `stream_sink.rb`
  and the single swallow in `stream_emitter.rb:32`.
- **Independent judgment**: **confirmed as a bounded observability gap, not a new defect class** —
  it is the measurement half of F03-REL-01. Graded minor because the *loss* is major (recorded
  there) while the missing counter alone is local observability debt.
- **Root cause**: the sink has no drop ledger because the Drain base class explicitly delegates
  accounting to subclasses (`drain.rb:10-11`) and `StreamSink` is not a `Drain` subclass, so no
  branch of the design owns the counter.
- **Recommendation**: none required beyond F03-REL-01 — if `finish`/`close` return the discarded
  count, the observable property is delivered without new machinery. Say so and recommend nothing
  further.
- **Disposition**: `open`, explicitly subordinate to F03-REL-01; close it if the REL-01 fix returns
  the count.

### F03-MNT-01 — `DeliveryDrainer` is a drain that does not use the shared drain base class

- **Severity**: minor
- **Confidence**: high
- **Status**: open
- **Source evidence**: `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb:12` declares
  `class DeliveryDrainer` with no superclass, and `28-57` hand-rolls `serve_loop`/`drain_once` with
  `@stopping` (`25`, `41-43`) — no bounded queue, no mutex/condition pair, no `flush`, no drop
  ledger. The shared skeleton it does not extend is `drain.rb:12-27`.
- **Test/contract evidence**: `ruby -Itest test/delivery_drainer_test.rb` → 10 runs, 50 assertions,
  0 failures.
- **Scanner signal**: `grep -rn '< Drain'` returned exactly two subclasses; `delivery_drainer.rb`
  matched only the `Drain` substring in its own name.
- **Independent judgment**: **confirmed as an ownership/vocabulary divergence, deliberately graded
  minor.** The two designs are genuinely different: `DeliveryDrainer` drains *durable SQLite rows*
  through claim/fence/receipt semantics (`:61-128`) where the store is the queue, so it cannot use
  an in-memory lane skeleton without inventing a queue it does not need. Per the brief's
  "if the simple path already delivers the property, recommend nothing", I explicitly do **not**
  recommend converting it. The real cost is only that the word "drain" now names two unrelated
  mechanisms, and F03's coverage claim ("the shared-budget drain base class") is narrower than the
  row's responsibility line implies.
- **Root cause**: naming collision between durable-row draining and in-memory-lane draining; no
  shared vocabulary distinguishes them.
- **Recommendation**: none — record the limitation. If anything is done later, it is a doc/vocabulary
  change at the row's coverage description, not code.
- **Disposition**: `open` as `info`-weighted minor; the coordinator should treat this as a coverage
  scoping note rather than a defect to schedule.

### Rejected lead (recorded so it is not re-litigated)

A scanner-shaped lead suggested `Journal#health` (`recorder_journal.rb:59-71`) self-deadlocks by
calling `lane_depths` (documented at `drain.rb:96` as requiring `@mutex`) inside `synchronize`.
**Rejected as false.** `/tmp/f03/probe10_doublelock.rb` and `probe12.rb` show
`synchronize { lane_depths }` returns normally, and `probe12` proves nested `synchronize` *does*
raise `ThreadError` on this `Mutex` — the two facts together establish that `health` wraps only
once, so no double-lock occurs. `probe11` separately shows the same shape works with and without
the lock. Confidence high; no finding recorded.

## Blind spots

- **`tamoz-date`/`Clock` was not read.** `monotonic_now` (`drain.rb:141-143`) delegates to
  `Clock.monotonic.now`; I assumed it is monotonic and non-decreasing. If it is wall-clock-backed,
  every deadline in `flush`/`close`/`join_all` is jump-sensitive. This matters for F03-REL-02.
- **`SafeText.normalize` internals were not read** (`stream_sink.rb:191-196`, `221-226`). I verified
  its observable contract from the raise in `probe13` (`run_id cannot be empty`) but not its byte
  accounting.
- **Graph node emitters were not traced past `StreamEmitter`.** I confirmed the emitter runs on the
  coordinator thread in `lifecycle_executor.rb:66-86`, but did not read every `emitter.emit` call
  site inside graph nodes, so I cannot bound how often a node emits relative to `capacity`.
- **`Observability::Producer` and the fanout recorder** (`recorders.rb`) were only skimmed; the
  `guarded(UNAVAILABLE_HEALTH)` wrapper at `recorders.rb:104` may itself change `health`'s
  blocking behavior. Not load-bearing for my findings.
- **`tamoz-otel`'s real exporter** (the thing `AsyncExporter` wraps) was not read, so
  `deliver_batch`'s `deadline_ms: 2_000` (`async_exporter.rb:75`) is unverified as honored.
- **I did not run `test/concurrency_drain_test.rb` under load or with `--seed` repetition**, so the
  timing-dependent assertions (`wait_until`, `elapsed < 5.0`) are proven to pass once, not to be
  stable. Five observability test files were left unrun for budget reasons.
- **The `chmod 644` and no-scratch-file housekeeping was verified** by `git status --short`; see
  below.

## Verdict

**IMPROVE** — 0 critical, 2 major, 2 minor, 0 info.

Two accepted major findings (F03-REL-01, F03-REL-02) clear the BAR.md threshold
("at least one accepted critical/major finding"). Both are shutdown-semantics defects on
different seams: the stream sink kills a backpressured producer and drops its backlog, and the
drain base class returns `nil` from `close` so abandoned work is unobservable. The gem's
*bounding* claim — the actual point of the gem — holds up: every queue, lane, namespace table,
pool and join in all six files is bounded, validated at construction, and enforced on the producer
side, with `probe16` and `probe18` confirming the bounds block rather than grow. The failures are
at the *exit*, not the entrance.

Lens coverage: correctness reviewed, security reviewed (no authority surface), reliability
reviewed, observability reviewed, scalability reviewed, maintenance reviewed. No lens is
`not evidenced`; the boundedness evidence gap is scoped to load/soak testing and recorded as such.
