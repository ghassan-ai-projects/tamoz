# F02 `tamoz-cancellation` — token and trap primitives are sound; the process-group seam has a self-signal and a negative-pid hazard, and nothing durably records "cancelled"

Row / queue / baseline: F02, W2B, `audit-15-09` HEAD `582ae55`, 2026-09-15 / analyst `analyst_f02` / budget ~40 min (used ~35).

## Scope and source map

Every line of the gem was read (276 lines total, matching the brief's "260-line" estimate within the gemspec):

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-cancellation/lib/tamoz/cancellation.rb` | 18 | require graph; depends on `tamoz-core` only (`cancellation.rb:7`) |
| `gems/tamoz-cancellation/lib/tamoz/cancellation_token.rb` | 152 | the core: state, waiters, callbacks, limits |
| `gems/tamoz-cancellation/lib/tamoz/cancellation/trap.rb` | 38 | INT/TERM installation and restore |
| `gems/tamoz-cancellation/lib/tamoz/cancellation/sleep.rb` | 14 | `interruptible_sleep` |
| `gems/tamoz-cancellation/lib/tamoz/cancellation/process_group.rb` | 31 | `alive?` / `signal` |
| `gems/tamoz-cancellation/lib/tamoz/cancellation/version.rb` | 7 | `0.1.0.alpha.1` |
| `gems/tamoz-cancellation/tamoz-cancellation.gemspec` | 16 | single runtime dep, `tamoz-core`, exact-pinned |

**Entry seam.** `Tamoz::CancellationToken` (`cancellation_token.rb:4`) is the only stateful object. Everything else is a module function or a class method. The public surface is pinned by `test/public_api_test.rb:115-119`: `ProcessGroup`, `Trap`, `VERSION`, `CancellationToken`, `Cancellation.interruptible_sleep` — exactly the five names this repo intends to export, so the surface is deliberate rather than incidental.

**Caller trace (the work).** Real callers read end to end, not just grep hits:

- Construction: `cli.rb:689`, `cli.rb:390`, `worker.rb:68`, `session.rb:396`, `graph/lifecycle_executor.rb:27,114`, `graph/writer_run_executor.rb:178`, `graph/run_coordinator.rb:107`, `graph/fork_executor.rb:163`, `graph/durable_request_executor.rb:164`, `stream/situation_request.rb:490`, `concurrency/pool.rb:61`, `stream_sink.rb:13`.
- Traps: `cli.rb:688-694`, `cli_worker_commands.rb:289-294`, `cli_comms_commands.rb:135-136`.
- Sleep: `worker.rb:1210` (the only `interruptible_sleep` call site in the repo).
- Process groups: `mcp/supervisor.rb:431,437` and `tools/check_runner.rb:98,100`.
- Predicate consumers: `graph/executor.rb:54,183`, `graph/stream_emitter.rb:33`, `core/context.rb:116-127`, `stream_sink.rb:37,72,82,171`, `pool.rb:80,94`.

## Behavior path

1. A process installs one token. In the CLI the token lives on the command object (`cli.rb:689`), and the closure handed to the trap reads that ivar on every signal (`cli.rb:690`) rather than capturing the token.
2. `Trap.install` (`trap.rb:20-34`) sets `Signal.trap("INT")` and `Signal.trap("TERM")`, each to a **fresh thread** that calls the handler with the canonical name `"sigint"`/`"sigterm"` (`trap.rb:26-28`). The `ensure` restores each previous handler (`trap.rb:32`).
3. The handler calls `CancellationToken#cancel!` (`cancellation_token.rb:53-74`): it takes `@mutex`, flips `@cancelled`, freezes the reason, snapshots and clears `@callbacks`, and broadcasts the condition variable inside the lock (`:58-66`); only then, outside the lock, does it fan out callbacks (`:68-72`).
4. Waiters blocked in `wait` (`:84-97`) re-check `@cancelled` on each wake and exit; the predicate and the wait share `@mutex`, so there is no between-check-and-wait window.
5. Consumers observe `cancelled?`/`reason`. `Worker#run` (`worker.rb:84-117`) exits with reason `"signal"`; `Pool` fabricates `TaskResult::Cancelled`; `Graph::Executor#run` returns `RunResult(status: :cancelled)` (`executor.rb:54,547-550`); the CLI maps the reason to an exit code (`cli_rendering.rb:132-138`).
6. Teardown signals process groups through `ProcessGroup.signal` (`mcp/supervisor.rb:437`, `check_runner.rb:98,100`).

## Lens: correctness

**Proven good.** Cancel-once and reason immutability hold: `cancel!` returns `false` for the second call and the reason stays the first value (`cancellation_token.rb:54,59`); probe E returned `first=true second=false reason="one"`. The callback fan-out tolerates `StandardError` per callback so one bad subscriber cannot abort the rest (`:70-71`); probe F showed surviving callbacks ran in registration order. Registering after cancellation invokes the callback immediately with the recorded reason and returns a shared no-op `ClosedSubscription` (`:104-125`, probe G `fired=["x"] unsub=false`). `normalize_reason` rejects an unnormalizable reason *before* the state flips (`:57` runs outside the lock, before `:61`), so a bad reason cannot leave the token half-cancelled — probe 5 confirmed `ArgumentError` with `cancelled=false`.

**Lead tested and disproven.** The stale-trap-closure hypothesis (an `ensure` that nils the ivar at `cli.rb:692-693` leaving a trap pointed at a dead token) is real as a *shape* but harmless in this repo: because the closure resolves `@cancellation` at call time, a signal arriving after the ensure is a silent no-op (probe 7: no exception, no crash). It also cannot survive as a stale trap, because `Trap.install`'s `ensure` restores the previous handler (`trap.rb:32`), verified by probe 1 (`[:installed, :orig_restored]`). The residual cost is that the signal is *swallowed* rather than restoring default disposition to that one process — see F02-COR-01.

**Gap.** The "second SIGINT" path is not a force-quit: a second SIGINT during shutdown is delivered to the same handler, which calls `cancel!` again and returns `false` (`:54`), so the process still waits out the graceful path. A hung turn is therefore not killable by repeated Ctrl-C. Probe D measured exactly this: two real SIGINTs produced `[true, false]`, i.e. the second was a no-op. Whether that is a defect depends on the intended contract, which is nowhere stated — recorded as F02-COR-01/info, not as a bug.

## Lens: security and authority

No authority surface: the gem reads no config, opens no files, parses no untrusted content, and holds no capability. Reason strings are byte-bounded to 256 by `SafeText.normalize` (`cancellation_token.rb:134-141`), so a hostile reason cannot become an unbounded durable field. The callback cap (`:108-110`, 1 024 default / 65 536 hard) bounds memory under a hostile registrar.

The one authority-adjacent concern is **signal targeting** and it belongs to this row, because `ProcessGroup` owns the arithmetic. `ProcessGroup.signal(pid, name)` sends to `-pid` (`process_group.rb:23`) with no guard on the value of `pid`. For `pid == -1` the unary minus yields `+1`, so `signal(-1, "KILL")` is `Process.kill("KILL", 1)` — **pid 1**, not a process group. I could not deliver it as an unprivileged user (`Errno::EPERM`, probe B), so this is not an exploitable escalation here, but the API silently converts a "kill this group" call into "kill init" if a caller ever passes a non-positive pid. `alive?(0)` is worse in kind: `Process.kill(0, -0)` is `Process.kill(0, 0)` — the **caller's own process group** — and it returned `true` (probe C), so `alive?(0)` reports "alive" unconditionally and, on the `signal` path, `signal(0, "TERM")` would deliver SIGTERM to the whole Tamoz process tree. Recorded as F02-SEC-01.

## Lens: reliability and durability

**Waiter mechanics are correct by construction.** `wait` is a `ConditionVariable`, not a poll or sleep loop (`cancellation_token.rb:88-96`). Both the predicate (`@cancelled`) and the wait are under `@mutex`, and `cancel!` sets the flag *and* broadcasts under the same lock (`:61-65`), so the classic lost-wakeup window is closed. I stress-tested it rather than trusting the argument: 1 000 iterations of "spawn waiter, `Thread.pass`, cancel" produced `lost_wakeups=0/1000` (probe C). Timeout handling is monotonic and re-derived per wake (`:86,90-91`), so a spurious wake cannot extend the deadline; probe A returned `false` after 0.255 s for `timeout: 0.25`.

**The return value is a boolean and is not distinguishable.** `wait` returns `@cancelled` (`:95`), so "timed out" and "completed" both return `false` and only "cancelled" returns `true` — the three states in the brief collapse to two. This is only benign because the sole caller is `interruptible_sleep` (`sleep.rb:11`), whose documented contract *is* the two-state one (`sleep.rb:9`), and whose sole consumer maps `true→:cancelled`, `false→:due` (`worker.rb:1210-1214`). Any future caller that needs to distinguish a timeout from completion has no signal. Recorded as F02-REL-02 (info), because no current caller is misled.

**Interruptible sleep is genuinely interruptible and its resolution is bounded** by the caller's own granularity: the sleep wakes the instant the token cancels (probe B: waiter woken by an external thread), a pre-cancelled token returns in 0.0 s (probe 4), and the full duration is honoured otherwise. Negative durations are rejected (`:145`, probe 2) — which matters, because `worker.rb:1204-1208` documents that a negative interval reaching `wait` would raise, and this validation is what makes that a clean `ArgumentError` rather than a process death from a lost race.

**Process groups: the child is reaped, the group is cleaned up on every exit path I traced.** The MCP supervisor spawns with `pgroup: true` (`supervisor.rb:344`), detaches a wait thread (`:365`) so the child is reaped rather than left a zombie, and `terminate_process_group` runs a grace ladder — wait, TERM, wait, KILL, wait (`:379-389`) — with the EPERM policy deliberately left at the call site (`:436-440`). Liveness for an unreaped zombie correctly reports `false` (probe B2), so the ladder cannot hang on a zombie. `check_runner.rb` spawns with `pgroup: true` (`:61`), and its TERM→KILL ladder falls back to a direct-pid kill when the group kill is denied (`:97-119`), which is the correct shape for a check that re-execs under different privileges.

**The one reliability hole is pid reuse.** `ProcessGroup.alive?`/`signal` address a *group id* by number with no check that the group is still the one the caller spawned. Probe A showed the intended behavior (after reaping the child, both `alive?` and `signal` correctly return `false`), but that is because the group was empty, not because the id was validated. If the pid is recycled onto an unrelated process group between reap and probe, the call hits that group. Both call sites are protected by construction — the supervisor only walks the ladder while `@pid` is set and never nils it (`supervisor.rb:227,381,385`) and the check runner holds `wait_thread` — so I record this as F02-REL-01 at **minor**, not major: the mitigation is the callers' bookkeeping, not the primitive's, and the primitive is the thing that claims to answer "is *this* group alive".

## Lens: observability and evidence

**Proven.** The cancellation *reason* survives to the operator: `cancel!` normalizes and stores it (`cancellation_token.rb:57,62`), `Worker#run` derives reason `"signal"` (`worker.rb:93,101`), and the CLI maps `sigint`/`sigterm` to distinct exit codes 130/143 (`cli.rb:13-14`, `cli_rendering.rb:132-138`) — so a supervisor can tell which signal stopped it. `EXIT_CODES` is defined once (`trap.rb:12`) and consumed by reference (`cli.rb:13-14`), so the codes cannot drift.

**Not evidenced — and this is the row's real observability gap.** A cancelled turn is *not durably recorded as cancelled at this seam*. The token itself writes nothing: there is no emitter, no journal, no receipt in `cancellation_token.rb` or `trap.rb`. Where durability happens it happens elsewhere and treats cancellation as a failure shape: `WorkerRuntime#terminal_reason` returns the error's `reason` or the literal `"failed"` (`worker.rb:1180-1183`), `exit_for_view` folds `:cancelled` into `1` (`cli_rendering.rb:126-129`: only `:completed` is special-cased, and the `else` comment names `:failed, and any status this CLI does not model`), and `cancel_exit` only reaches the signal exit code when a `view.state[:terminal_reason]` happens to be `cancelled_by_user` (`cli_session_commands.rb:235-237`). The operator-requested-cancel path (`cancellation_visibility_test.rb:34-49`) proves requested→observed→stopped renders distinctly, but that path is driven by `store.request_cancellation`, a *different* mechanism than this gem's token. So: two independent cancellation models coexist, and the token's own outcome is not durably distinguishable from a failure. Recorded as F02-OBS-01.

## Lens: scalability and resource bounds

Bounded and proven: callbacks are capped at `max_callbacks` (default 1 024, hard ceiling 65 536) with a raised `StateLimitError` rather than silent growth (`cancellation_token.rb:5-6,41-43,108-110`); the callback hash is cleared wholesale on cancel (`:64`), so cancellation releases the retained closures; waiters are O(1) per waiter with no accumulation, and `wait` allocates no timer thread or fiber. The gem maintains exactly one `Mutex` and one `ConditionVariable` per token (`:46-47`) and spawns nothing of its own — the comment at `cancellation.rb:5-6` claims "it spawns no pools and joins no threads of its own", which is true of the gem; the threads appear one layer up in `Trap` (`trap.rb:27`) by design.

The cost that *is* unbounded-per-signal is the trap's one-thread-per-signal policy. A signal storm creates one thread per delivery (see scalability note in F02-COR-01); in a signal storm this is a thread amplifier. No test bounds it; I did not measure a storm rate, so this is stated as a limitation, not a proven defect.

## Lens: maintenance and architecture

Clean. Dependency direction is honest and single: the gemspec declares exactly `tamoz-core` (`gemspec:13-15`) and `cancellation.rb:7` requires exactly that; no gem in the tree requires `tamoz-cancellation` back, so there is no cycle. The public surface is deliberately pinned by a test (`public_api_test.rb:115-119`), and `private_constant` (`:150`) hides `Subscription`, `ClosedSubscription`, and both callback constants. Vocabulary is consistent with the rest of the repo: `validate_*`/`normalize_*` names, the repo error hierarchy (`ConfigurationError` `:42`, `StateLimitError` `:109`), `Clock.monotonic` for time (`:86,90`) instead of `Time.now`. The per-caller policy split between the two `ProcessGroup` consumers is documented at the primitive (`process_group.rb:6-8`) and again at the MCP call site (`supervisor.rb:434-435`), which is the right place for it.

One maintainability defect: `Pool::Base#cancellation_for` silently substitutes a **fresh, never-cancellable token** when the caller passes neither an override nor a default (`pool.rb:61`, `override || @default_cancellation || CancellationToken.new`). That is a silent no-op cancellation path indistinguishable from "not cancelled" — recorded as F02-MNT-01.

## Tests and contracts

All commands run one file per invocation with the prescribed `PATH` prefix. Every suite passed.

| Command | Result |
|---|---|
| `ruby -Itest test/cancellation_visibility_test.rb` | 11 runs, 106 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_worker_test.rb` | 25 runs, 122 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/concurrency_drain_test.rb` | 7 runs, 36 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_session_kill_matrix_test.rb` | 6 runs, 67 assertions, 0 failures, 0 errors, 0 skips (33.4 s, real signals, ran fine) |
| `ruby -Itest test/agent_mode_switch_kill_matrix_test.rb` | 2 runs, 17 assertions, 0 failures, 0 errors, 0 skips |

Both kill-matrix files were **run, not skipped** — they drove real `Process.kill("KILL", …)` and completed well inside budget, so no `not run` entry is needed for them.

The strongest contract evidence is `agent_worker_test.rb:455-497`: it spawns a real child worker, sends a real `SIGTERM`, and asserts both that no `ThreadError`/`"trap context"` reaches stderr (`:483-485`) and that the supervised stop exits **0** (`:486`). That is a direct runtime proof of the `trap.rb:5-8` defer-to-a-thread rationale, and it is the reason I treat the trap design as verified rather than merely plausible. `agent_worker_test.rb:501-531` separately proves the interruptible sleep is not hostage to a 30 s interval (`elapsed < 5.0`, `:525`).

**Not found:** there is no unit test for `ProcessGroup` itself. The MCP and check-runner suites exercise it indirectly (`mcp_supervisor_test.rb:76-77,114`, `mcp_invocation_test.rb:112-113,367-369`, `mcp_catalog_test.rb:108`, `agent_mcp_adversarial_test.rb:173-174,391-396`), each re-implementing `group_alive?` locally rather than calling the primitive — and none passes a non-positive pid. That absence is what lets F02-SEC-01 stand unrefuted.

**Probe evidence** (my own scripts, all written under `/tmp`, none in the repo): `/tmp/probe2.rb` (waiter semantics, 1 000-iteration lost-wakeup stress), `/tmp/probe3.rb`–`/tmp/probe5.rb` (process-group hazards), `/tmp/probe7.rb` (stale trap closure), `/tmp/probe8.rb` (trap restore + re-entrancy), `/tmp/probe9.rb` (callback re-entrancy), `/tmp/probe11.rb` (sleep edges). These are reproductions I ran, not shipped tests.

## Findings

### F02-SEC-01 — `ProcessGroup` accepts a non-positive pid and retargets the signal to pid 1 or to Tamoz's own group

- **Severity:** major. **Confidence:** high. **Status:** open.
- **Observable behavior at risk:** `ProcessGroup.signal(pid, name)` with a caller-supplied `pid` of `0` or `-1` does not signal a process group. `-pid` is computed unconditionally (`process_group.rb:23`), so `signal(-1, "KILL")` issues `Process.kill("KILL", 1)` — pid 1 — and `signal(0, "TERM")` / `alive?(0)` issue `Process.kill(…, 0)`, which is the **caller's own process group**. `alive?(0)` therefore returns `true` unconditionally (probe C) and `alive?(-1)` returns `true` whenever pid 1 exists.
- **Owning seam:** `gems/tamoz-cancellation/lib/tamoz/cancellation/process_group.rb#signal` (and `#alive?`).
- **Source evidence:** `process_group.rb:11-18` (`alive?`), `process_group.rb:22-27` (`signal`); both compute `Process.kill(x, -pid)` with no guard. Call sites pass through unchecked: `supervisor.rb:431,437` (`@pid` set only from `spawn_child_process`, `:227`) and `check_runner.rb:98,100` (`wait_thread.pid`).
- **Test/contract evidence:** no `ProcessGroup` unit test exists (searched `test/`; only indirect group checks at `mcp_supervisor_test.rb:76-77,114`, `mcp_invocation_test.rb:112-113,367-369`, `mcp_catalog_test.rb:108`, `agent_mcp_adversarial_test.rb:173-174,391-396`, all with positive pids). Probe commands: `ruby -Ilib -Igems/tamoz-core/lib -Igems/tamoz-cancellation/lib /tmp/probe4.rb` → `alive?(0)=true`, `alive?(-1)=true`; `/tmp/probe5.rb` → `signal(-1,'CONT')` raises `Errno::EPERM` because its target is `Process.kill(0, 1)`.
- **Scanner signal:** grep of `gems/*/lib` for `ProcessGroup` — two call sites, both positive-pid by construction.
- **Independent judgment:** I confirmed the arithmetic and the runtime targets (`Process.kill(0, 1)` → `EPERM`; `Process.kill(0, 0)` → `ok`). I could **not** demonstrate real damage: `KILL` to pid 1 is `EPERM` for an unprivileged user and `alive?(0)` is not currently reachable because both callers hold a positive pid. So this is a boundary defect in a primitive that advertises "group liveness and group signalling" (`process_group.rb:6-7`) without validating that its argument is a group id — not a live escalation. I kept it at major rather than critical for exactly that reason: BAR.md reserves `critical` for an active invariant/boundary violation with an unsafe action, and here the guard is missing but the reachable path is not yet unsafe.
- **Root cause (five whys):** (1) `signal(0, "TERM")` would TERM the whole Tamoz process tree → (2) the primitive negates whatever it is given → (3) `alive?`/`signal` validate nothing about `pid` → (4) the primitive's contract is stated as "group id" (`process_group.rb:6-7`) but never *enforced*, and the gem has no unit test of the primitive → (5) the gem treats `ProcessGroup` as a two-line convenience wrapper rather than a boundary that owns an argument-validation contract, so no seam exists where a positive-pid precondition would be declared.
- **Recommendation:** the smallest credible action at the existing seam — add one guard at the top of both class methods in `process_group.rb` rejecting a non-positive or non-Integer `pid` via the repo's existing `ConfigurationError` (matching the `validate_*!` idiom used at `cancellation_token.rb:41-43`). No new class, no new file. Optionally pin it with one assertion in an existing MCP test rather than a new suite.
- **Disposition:** *pending coordinator.* My reading: accept as major-open. The contract gap is real and the fix is three lines at the owner seam, but no reachable caller is currently unsafe, so a coordinator could reasonably downgrade to minor-open if it prefers to grade only reachable paths.

### F02-OBS-01 — a token-driven cancellation is not durably recorded as cancelled; it degrades to "failed"

- **Severity:** major. **Confidence:** medium. **Status:** open.
- **Observable behavior at risk:** when a turn is stopped by SIGINT/SIGTERM through this gem, the durable record does not say "cancelled". `Worker#run` (`worker.rb:84-117`) returns the in-memory reason `"signal"` and emits `worker.stopped` with it (`:113-116`), but the request's terminal reason is derived from the *error* by `WorkerRuntime#terminal_reason` (`worker.rb:1180-1183`), which returns `"failed"` whenever the terminal error is not a Hash with a `reason`. At the CLI, `exit_for_view` (`cli_rendering.rb:124-130`) folds every status except `:completed` — including `:cancelled` — into exit `1`, and the signal exit codes 130/143 are reached only through the separate `cancelled_by_user` path in `cancel_exit` (`cli_session_commands.rb:235-237`). A supervisor therefore cannot distinguish "the turn was cancelled" from "the turn failed" except by the exit code of the *process*, and only for the interactive view.
- **Owning seam:** the durable terminal-reason derivation `gems/tamoz-agent/lib/tamoz/agent/worker.rb#terminal_reason` (boundary with `Tamoz::Graph::RunResult(status: :cancelled)` at `gems/tamoz-graph/lib/tamoz/graph/executor.rb:547-550`).
- **Source evidence:** `worker.rb:1180-1183`, `worker.rb:84-117`, `cli_rendering.rb:124-138`, `cli_session_commands.rb:235-237`, `executor.rb:54,547-550`, `cancellation_token.rb:80-82` (the token exposes `reason` but writes nothing).
- **Test/contract evidence:** `ruby -Itest test/cancellation_visibility_test.rb` → 11 runs / 106 assertions / 0F. That suite proves the *other* mechanism end to end — `request_cancellation`→`mark_cancellation_observed`→ terminal wording (`cancellation_visibility_test.rb:34-49`) — and its own comments distinguish "stopped at the cancellation boundary" from "completed before the cancellation took effect" (`:49,71,96`). It never exercises a token-driven `cancel!`. `agent_worker_test.rb:455-497` asserts the *exit code* for a real SIGTERM (`assert_equal 0, status.exitstatus`, `:486`) but makes no assertion about the durable terminal reason. So the durable-record claim is **not found** in any test.
- **Scanner signal:** grep for `cancellation|CancelledError` across `gems/*/lib` — the token's `reason` is read at `pool.rb:106,324,330`, `stream_sink.rb:119`, `cli_rendering.rb:133`, and never written to a store by this gem.
- **Independent judgment:** I verified the code path (`:1180-1183` genuinely returns `"failed"` for a non-Hash terminal error) and that the two cancellation models are separate. I did **not** run a durable worker to observe a token-cancelled request's stored reason, so I cannot state the stored value as measured — hence `medium`, not `high`. The gap is a missing durable distinction, which is exactly what BAR.md's observability lens asks for ("is the outcome, refusal, unknown state, and failure visible and correlated").
- **Root cause (five whys):** (1) an operator sees exit 1 and cannot tell cancellation from failure in the store → (2) `terminal_reason` has no cancellation branch and `exit_for_view` has no `:cancelled` branch → (3) cancellation is expressed as a `RunResult` status in `tamoz-graph` but as an error `reason` string in `tamoz-agent` → (4) two cancellation models (durable `request_cancellation` in the store, in-memory token from this gem) were built at different times and never reconciled at the reason seam → (5) no contract names the canonical durable terminal reason for a token cancellation, so there was nothing for either side to conform to.
- **Recommendation:** the smallest credible action at the existing seam — give `WorkerRuntime#terminal_reason` the same `:cancelled` awareness the CLI already models (`cli_rendering.rb:128` names it explicitly), mapping a cancelled run to a stable `"cancelled"` reason instead of the `"failed"` fallback at `worker.rb:1182`. Do not build new machinery: the `RunResult(status: :cancelled)` value already exists at `executor.rb:547-550` and is already propagated to `executor.rb:54`.
- **Disposition:** *pending coordinator.* My reading: accept as major-open with a confidence qualifier — the source gap is certain; the runtime consequence should be confirmed by whoever owns `tamoz-agent` before it is graded major rather than minor.

### F02-MNT-01 — an omitted pool token is silently replaced by a fresh, never-cancellable token

- **Severity:** minor. **Confidence:** high. **Status:** open.
- **Observable behavior at risk:** `Pool::Base#cancellation_for` returns `override || @default_cancellation || CancellationToken.new` (`pool.rb:61`). A pool constructed with no default token and driven with no per-call override silently acquires a brand-new token that nobody can reach, so `cancel!` can never be called on it and every task reports "not cancelled". The failure mode is indistinguishable from correct operation.
- **Owning seam:** `gems/tamoz-concurrency/lib/tamoz/pool.rb#cancellation_for`.
- **Source evidence:** `pool.rb:60-61`, reached from `pool.rb:115` and `:155`; the token's `cancelled?` is then consulted at `:80,94,156,275,295,305`.
- **Test/contract evidence:** `ruby -Itest test/concurrency_drain_test.rb` → 7 runs / 36 assertions / 0F, but that file tests `Drain` and contains no cancellation case (grep for `cancel` in it: no matches). `test/core_pool_test.rb:85,98,127` passes explicit tokens. So the default-token path is **not covered**.
- **Scanner signal:** grep of `CancellationToken.new` in `gems/*/lib` — `pool.rb:61` is the only construction that is neither a caller argument nor an intentional default parameter.
- **Independent judgment:** confirmed by reading; the semantics of a freshly built token are unambiguous (probe A/H: a token that is never cancelled returns `false` from `wait` and `cancelled?` forever). Impact is bounded because `Pool.for` callers in this repo generally pass a token; the defect is that the *silent* substitution hides a wiring mistake instead of surfacing it.
- **Root cause:** a convenience fallback was written for the "no cancellation requested" case, but a fresh token and an absent token are not the same thing, and nothing in the code distinguishes "the caller asked for no cancellation" from "the caller forgot".
- **Recommendation:** smallest credible action at the existing seam — keep the fallback but make the intent explicit, or raise `ConfigurationError` in `cancellation_for` when neither source is present, mirroring the validation already performed in `Pool::Base#initialize` (`pool.rb:49-52`). One-line change; no new machinery.
- **Disposition:** *pending coordinator.* My reading: accept as minor-open, or fold into the existing `tamoz-concurrency` row (F03) if the coordinator prefers that seam to own it. Possible duplicate of any F03 cancellation finding.

### F02-REL-01 — `ProcessGroup` addresses a group id by number with no proof it still owns that group

- **Severity:** minor. **Confidence:** medium. **Status:** open.
- **Observable behavior at risk:** after a child is reaped, its pgid returns to the kernel's id pool. `alive?`/`signal` (`process_group.rb:12,23`) resolve only the number, so if the pid is recycled onto an unrelated process group between reap and probe, the liveness answer is wrong and the signal lands on a stranger. Probe A confirmed the intended case (reaped, group empty → `alive?=false`, `signal=false`), but that is emptiness, not identity.
- **Owning seam:** `gems/tamoz-cancellation/lib/tamoz/cancellation/process_group.rb#alive?` / `#signal`.
- **Source evidence:** `process_group.rb:11-27`; consumers hold the id as an ivar and never nil it — `supervisor.rb:227` (set), `:381,385` (read), `:158` (nil only at construction) — and `check_runner.rb:70,97-101` holds `wait_thread` across the ladder.
- **Test/contract evidence:** the indirect group tests listed under F02-SEC-01 all assert on a live or freshly-reaped child and none exercises id reuse (no test can force it deterministically), so this is **not proven defective by any test**; my evidence is the source arithmetic plus probe A.
- **Scanner signal:** none — this came from reading the primitive against its two call sites.
- **Independent judgment:** I confirmed the window exists in principle and that it is closed *in practice* by caller bookkeeping (the supervisor's ladder runs only while `@pid` is live, and the check runner still owns `wait_thread`). I could not construct a reproduction without racing the kernel's pid allocator, so I stopped at minor/medium rather than inflating it. Per repo convention ("do not cover rare cases"), the honest disposition may well be to record it and change nothing.
- **Root cause:** the primitive offers a number-keyed liveness check while the ownership fact that makes the number meaningful is held by the callers, so correctness depends on a discipline stated only in a comment (`process_group.rb:6-8`).
- **Recommendation:** smallest credible action at the existing seam — state the precondition in the primitive's existing documentation comment (that `pid` must be an unreaped, still-owned group leader) rather than adding a `kill(0, pgid)` identity re-check. If the coordinator judges the window unreachable by construction, the correct action is to record the finding as `closed` with that reasoning and change no code.
- **Disposition:** *pending coordinator.* My reading: accept as minor-open or close on the "cannot happen by construction" rule; the callers' bookkeeping is the actual guarantee and it is visible at `supervisor.rb:379-389` and `check_runner.rb:97-119`.

### F02-COR-01 — a second SIGINT during shutdown is a no-op, and each signal spawns an unbounded thread

- **Severity:** info. **Confidence:** high. **Status:** open.
- **Observable behavior / design fact:** `Trap.install` spawns a thread per signal delivery (`trap.rb:27`) and never chains the *previous* handler during the guarded body. A second SIGINT therefore reaches the same handler, calls `cancel!` a second time, and returns `false` (`cancellation_token.rb:54`) — the shutdown is not accelerated. Probe D: two real SIGINTs → `[true, false]`; probe 2 (re-entrancy): three SIGINTs all reached the inner handler, and the outer previous handler remained installed throughout.
- **Owning seam:** `gems/tamoz-cancellation/lib/tamoz/cancellation/trap.rb#install`.
- **Source evidence:** `trap.rb:20-34`; consumers rely on the deferral — `cli_worker_commands.rb:285-294`, `cli_comms_commands.rb:131-136`, `cli.rb:688-694`.
- **Test/contract evidence:** `agent_worker_test.rb:455-497` proves one SIGTERM is handled cleanly and exits 0; **no test** sends a second signal or asserts a force-quit path (`not found`).
- **Scanner signal:** none; found by reading `trap.rb` against the re-entrancy question in the brief.
- **Independent judgment:** I verified both halves at runtime (probes D, 1, 2, 7). I classify this `info` and not a defect because the repo never states a force-quit contract — the trap comment (`trap.rb:5-10`) promises only "cannot deadlock or lose a stop request", and that promise holds: no stop request is lost, and `signal(-1)` arithmetic aside, no signal is misrouted. The thread-per-signal cost is a real but unmeasured amplification.
- **Root cause:** the deferral design optimizes for "never run mutex work in trap context" and takes no position on signal escalation or storm bounds.
- **Recommendation:** none required. If the coordinator wants the escalation property, the smallest action at this seam is to let the handler observe that the token is already cancelled (`cancellation_token.rb:76-78` already exposes `cancelled?`) and re-raise the default disposition — but that is a contract decision for the owner, not an audit fix, and the repo's "do not cover rare cases" rule argues for changing nothing.
- **Disposition:** *pending coordinator.* My reading: accept as info, no action.

## Blind spots

- **No durable run was executed.** F02-OBS-01's runtime consequence (the literal value stored for a token-cancelled request) is inferred from `worker.rb:1180-1183`, not observed. Proving it needs a durable worker driven to a token cancellation, not run under this budget.
- **No signal storm was measured.** The thread-per-signal amplification in F02-COR-01 is stated as a shape, not a rate; I did not drive sustained signals.
- **Pid reuse was not reproduced.** F02-REL-01 rests on the arithmetic of `process_group.rb:23` plus the absence of an identity re-check; forcing the allocator race was out of budget.
- **The comms gateway trap site was read but not exercised.** `cli_comms_commands.rb:130-163` installs the same primitives over gateway/drainer loops; I traced the install and the `stop_loops` handoff but did not run a gateway, so its shutdown-completeness belongs to the `tamoz-comms-gateway` row (F12).
- **`tamoz-stream` and `tamoz-agent-session` cancellation wiring was traced at construction only** (`situation_request.rb:490`, `session.rb:396`). Their behavior under cancellation belongs to F06/F22.
- **Enola was not used.** AGENTS.md prefers it over grepping for structure; this row is six files and the caller trace was the required work, so I used `grep` deliberately and did not spend budget generating a snapshot.
- **`Rakefile` and `bin/` were not audited** — out of this row's scope; `bin/` contains no cancellation reference.

## Verdict

**IMPROVE** — 0 critical, 2 major (F02-SEC-01, F02-OBS-01), 2 minor (F02-MNT-01, F02-REL-01), 1 info (F02-COR-01). Two accepted major findings meet the BAR.md threshold.

Lens coverage: correctness reviewed, security and authority reviewed, reliability and durability reviewed, observability and evidence reviewed (with the durable-record claim explicitly `not evidenced` — it is the subject of F02-OBS-01), scalability and resource bounds reviewed, maintenance and architecture reviewed. No lens is `not evidenced` as a whole.

The core is sound and I want that stated plainly rather than buried: the cancellation token's waiter mechanics are correct by construction and survived a 1 000-iteration race stress with zero lost wakeups; the trap's defer-to-a-thread design is a genuine, tested fix for `Mutex` in trap context (`agent_worker_test.rb:455-497` proves it against a real SIGTERM, exiting 0 with no `ThreadError`); the interruptible sleep wakes immediately and rejects the negative interval that `worker.rb:1204-1208` documents as a historical process-killer. The defects are at the boundaries, exactly where the brief predicted: an unguarded `-pid` in a primitive whose two call sites happen to be safe, and a durable record that cannot say "cancelled" because two cancellation models were never reconciled at the reason seam.
