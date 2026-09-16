# F25 `tamoz-agent` — IMPROVE: the worker/runtime seams are sound, but four budgets are pinned-not-enforced and a cancelled turn is recorded to the operator as completed

Row / queue / baseline (commit, date) / analyst / budget
- Row: **F25** (`tamoz-agent`), queue **W2A** (CLI / runtime), per `COVERAGE.md:93,53`.
- Baseline: branch `audit-15-09`, commit **`582ae55`**, 2026-09-15.
- Analyst: independent read-only functionality auditor (analyst lane; no scanner lane was supplied for this row).
- Budget: ~50 minutes used of a 60-minute ceiling. Read-only: no production code, test, config, gemspec, fixture, or third-party doc was edited.

## Scope and source map

All 16 assigned files were read end to end (5,003 lines), in this order:

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-agent/lib/tamoz/agent.rb` | 92 | `Agent.build`, the bundled `implement` approval engine, `SessionApprovalWiring` override |
| `gems/tamoz-agent/lib/tamoz/agent/runtime.rb` | 796 | ephemeral one-shot `Runtime` (routing, plan/repair loop, model effect dispatch) |
| `gems/tamoz-agent/lib/tamoz/agent/worker.rb` | 1377 | foreground `Worker` (poll, inbox advance, park/resume, budget stop, milestones) |
| `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` | 1249 | `WorkerRuntime` (adapter, sessions, profiles, child tasks, occurrences, budgets, leases) |
| `.../agent/runtime/step_execution.rb` | 295 | ephemeral step gate + tool execution |
| `.../agent/runtime/plan_review.rb` | 144 | ephemeral two-layer plan review |
| `.../agent/runtime/effects_journal.rb` | 249 | in-memory effect journal for the ephemeral runtime |
| `.../agent/episode_graph.rb` | 133 | fixed production episode graph (v4) |
| `.../agent/worker_runtime/deferred_model.rb` | 59 | lazy model construction for status/queue paths |
| `.../agent/runtime_directory.rb` | 342 | operator runtime directory, config schema 2, private-permission gates |
| `.../agent/terminal_progress.rb` | 72 | committed-evidence progress projection |
| `.../agent/durable_recorder.rb` | 34 | flush-boundary recorder wrapper |
| `.../agent/lane_config.rb` | 67 | declared lane → model tier map |
| `.../agent/child_environments.rb` | 59 | per-command child env allowlists |
| `.../agent/version.rb` | 7 | `0.1.0.alpha.1` |
| `gems/tamoz-agent/tamoz-agent.gemspec` | 28 | 15 pinned inter-gem dependencies |

**Entry seam.** `RuntimeDirectory` (operator authority, inert) → `WorkerRuntime.open` (`worker_runtime.rb:42-51`, the only place the worker path opens a database) → `Worker` (`worker.rb:36`) driven by `tamoz-agent-cli`'s `cmd_worker` (`cli_worker_commands.rb:270-290`) with `session_builder: ->(thread_id) { runtime.session_for(thread_id) }`. The library also exposes the one-shot `Tamoz::Agent.build` (`agent.rb:45-66`) used by the interactive CLI.

**Adjacent seams read because F25's behavior is decided there** (cited inline, not re-audited as their own rows): `gems/tamoz-sqlite/lib/tamoz/sqlite/lease_operations.rb` and `lease.rb`, `effect_preparation.rb`, `effect_reconciler.rb`, `effect_record_reader.rb`; `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb` and `executor.rb`; `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb`; `gems/tamoz-agent-session/lib/tamoz/agent/{session,session_bindings,session_effects,session_steps,session_options}.rb`; `gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb`; `gems/tamoz-approval/policy/base.yaml` and `policy/profiles/*.yaml`.

## Behavior path

**Unattended turn (the row's core path).** `Worker#run` (`worker.rb:84-117`) loops `poll_once` (`122-130`), which each pass syncs the approval policy, drains mode switches, enforces ask deadlines, reconciles child requests, materializes due schedules and advances pending threads. `work_list` (`241-256`) merges durable open occurrences with the inbox's `pending_threads`. `advance_thread` (`261-276`) builds the session through the builder, which routes to `WorkerRuntime#session_for` (`worker_runtime.rb:701-706`) → `session_for_profile` (`750-754`) → `build_session` (`1030-1057`).

`claim_and_run` (`worker.rb:509-520`) emits `request.claimed`, starts the child task, opens the occurrence **durably before execution** (`WorkerRuntime#open_occurrence`, `331-336`), then `session.app.durable_runner.run_next(thread:, owner_id:)` (`gems/tamoz-graph/.../durable_runner.rb:56-102`), which opens a fenced writer (`checkpoint_store.rb:85-117` → `LeaseOperations#acquire_lease`), claims the oldest queued request, and executes it. Settlement (`settle`, `worker.rb:635-659`) checks the budget **before** interpreting the outcome, emits the durable model-call projection, then routes to `settle_completed_view` / `settle_failed_view` / `settle_blocked_view` / `settle_paused_view` (`677-778`). Terminal delivery writes the outbox row *before* closing the occurrence (`698-702`).

**Crash takeover.** A request left `claimed`/`running` is re-entered by `recover` (`533-542`) → `DurableRunner#recover` (`durable_runner.rb:104-153`) → `writer.recover_request`, which re-validates the lease and re-enters the same execution.

**Ephemeral turn.** `Runtime#run` (`runtime.rb:142-147`) → `start_turn` (`185-195`) → routing (`280-305`) → plan/review (`plan_review.rb`) → step execution (`step_execution.rb`) → `verify` (`603-624`) → `finish` (`243-247`). Every model call crosses `EffectDispatcher.run` (`664-692`) over the in-memory `EffectsJournal` (`effects_journal.rb`).

## Lens: correctness

- The routing matrix is closed and validated at construction: `Runtime#initialize` refuses an unknown `routing` and an out-of-range `max_plan_attempts` (`runtime.rb:122-127`); `WorkerRuntime#normalize_routing` does the same for the durable path (`worker_runtime.rb:1059-1064`).
- The repair loop is bounded and deduplicated by signature: `ActionLoopState#repeated_action?` / `repeated_failure?` / `attempts_exhausted?` (`runtime.rb:68-86`), with one shared counter for tool rejections and failed checks (`resolve_action_outcome`, `547-569`).
- `enforce_configured_check` (`626-640`) refuses to report `satisfied` when an action-capable toolbox declares checks and none passed — a real anti-overclaiming guard.
- **Defect (F25-COR-01):** a turn the operator cancelled settles as `request.completed` and `task_state: "completed"` while its durable terminal reason is `cancelled_by_user`. Proven by probe (below) and traced to `Worker#settle_view` (`worker.rb:677-688`) keying only on `view.status`, which is the *graph checkpoint* status (`session.rb:490-492`), not the terminal reason.
- **Carried-forward defect (CF04-REL-01) still reproduces in principle at the dispatcher seam, but I could not reach it from F25's own paths.** See Findings.

## Lens: security and authority

- **Profile ids are filenames and are validated as such**: `PROFILE_ID_PATTERN` plus a `File.expand_path` containment check (`worker_runtime.rb:809-860`) refuses traversal, and an unknown profile raises rather than silently downgrading (`826-830`).
- **Work cannot name its own authority**: the thread→profile binding lives in the operator's runtime store, not the request payload (`worker_runtime.rb:107-140`), and the payload is graph state that rejects undeclared keys (`worker.rb:161-163` in the worker's own comment set; enforced by the session codec).
- **Skills and memory never come from the workspace**: `skills_root` refuses a root inside the workspace (`runtime_directory.rb:151-163`); `skills_snapshot` only compiles the operator directory (`worker_runtime.rb:872-885`).
- **Child authority is bound and digest-pinned**: `persist_child_authority_binding` records `profile_digest` (`worker_runtime.rb:1087-1105`) and `child_profile_for` refuses a changed profile (`1116-1123`); `enforce_narrowed_tools` refuses a child whose capabilities exceed the profile (`1211-1218`).
- **Fail-closed storage**: every read/write in `worker_runtime.rb` goes through `durable` (`579-585`), which converts a storage failure into `StoreUnavailableError` instead of the permissive `nil`/`0`. That is the correct direction for both the budget gate and the "has a human answered?" gate.
- **Carried-forward F25-SEC-01 still reproduces.** `session_for` → `thread_profile` → `profile` re-loads `profiles/<id>.yaml` by id with no read of the session's recorded `profile_digest` (`worker_runtime.rb:694-706, 820-824, 1030-1057`). The worker path is exactly where it lives. Full analysis already recorded; not re-litigated.
- **Carried-forward CF05-SEC-01 is real and my row is where the unrestricted default is created.** `Runtime#initialize` calls `CapabilityBinding.build(toolbox:)` with no profile and no mcp (`runtime.rb:139`). I confirmed the *governance* fallback is honest — `closed_effect_class` fails an unclassified MCP descriptor closed to `:bounded` (`capability_binding.rb:206-209`, `MCP_EFFECT_CLASSES` at `44`) and `PolicyDocument#tier_for`/`verb_for` send an unclassified tool to `fallback_tier` (`policy_document.rb:57-75`; `base.yaml:34-36`, default `ask`) — so an unknown-effect MCP tool still pauses for a human even under the bundled `implement` profile. But the *admission* question (may a restrictive profile see the tool at all) is untouched by that fallback, and the runtime's default binding is unconditional.

## Lens: reliability and durability

- **Leases are genuinely fenced.** `acquire_lease` refuses when an unexpired lease exists (`lease_operations.rb:49-52`), sets `fence = row + 1` (`54`), and `validate_lease_in_transaction!` requires matching owner **and** fence **and** an unexpired lease (`164-189`). `LeaseGuard` renews at `ttl/3` (`lease.rb:73-91`) and raises `LeaseLostError` when renewal loses ownership (`lease_operations.rb:127`). **Two workers cannot concurrently run one thread on the same database**: the second `open_writer` loses the acquisition race and raises `CheckpointConflictError`. The residual risk is a partitioned second worker with an independent copy of the database, which is the documented fault model (`documentation/limitations.md`, "Tamoz does not survive loss of the SQLite file") and is owned by F07/tamoz-sqlite, not by this row.
- **Crash recovery re-enters rather than restarts**: `DurableRunner#recover` re-runs the *same* request/execution (`durable_runner.rb:104-153`), and a claimed row is failed closed through a fenced transition when it is stale (`160-175`).
- **Durable identity before execution**: `open_occurrence` is written before `run_next` (`worker.rb:512-516`), and the terminal outbox row before the occurrence closes (`698-702`).
- **Second-writer hazard inside one worker process (F25-REL-01).** `WorkerRuntime#build_child_session` passes `mcp: nil` (`worker_runtime.rb:721-728`), while the child's turn is executed by the *worker's* `advance_thread` → `advance_open_occurrence` → `claim_and_run` (`worker.rb:261-340, 509-520`) using the `session_for`-built child session. Child delegation therefore looks like it is supposed to run over the same durable runner while the parent runtime's normal path builds sessions with the MCP source; if any caller instead routes child work through `session_for`, the child cannot dispatch MCP capabilities at all. I could not complete a runtime proof inside budget, so this is recorded as `unconfirmed` with the exact source evidence rather than asserted.
- **Repair budget is not durable for the durable path at all.** `Worker#exhausted_budget` (`worker.rb:383-398`) enumerates a hardcoded two-name list, and `max_repair_attempts` is enforced only inside the ephemeral `Runtime` and inside session nodes (`session_options.rb:91-100` validates the *shape*, not a profile budget).

## Lens: observability and evidence

- Worker events are structured, flushed per line, and correlated: `emit` (`worker.rb:1223-1230`) plus `observability_correlation` (`1251-1257`), with a closed signal catalog and low-cardinality hashing (`1259-1272`). Projection failures are dropped, never fatal (`1247-1249`).
- `TerminalProgress` derives progress **only** from committed effect receipts (`terminal_progress.rb:25-57`); model answers and planned steps cannot inflate it. That is the right evidence discipline.
- Durable model-call telemetry is projected from the effect journal with a de-duplicating key set seeded from the journal itself (`worker.rb:1274-1347`), so a restart does not double-emit.
- **F25-COR-01 is also an observability defect**: the operator-facing terminal card says `completed`, which materially misleads a supervisor watching the outbox.
- **F25-OBS-01:** the `headless_auto_approvals` safety counter is structurally constant `0` — it is a literal, with no evidence expression behind it (`cli_worker_commands.rb:619`), unlike its three sibling counters which are counts over the effect census (`604-615`). A safety counter that cannot move cannot fail.

## Lens: scalability and resource bounds

- Bounds are explicit and clamped: `@concurrency` clamps to 1..32 (`worker.rb:65`), the pool is `max_tasks: @batch` (`213-221`), inbox/occurrence/child scans take a limit (`241-256`, `1106-1112`, `238-240`), and the observation byte budget is enforced per step and in total (`step_execution.rb:42-44, 81-83`).
- `sleep_until_due` sleeps on the cancellation token so an idle worker costs nothing and SIGTERM is not held hostage (`worker.rb:1209-1215`).
- **Unbounded per-turn work (F25-SCL-01).** The `steps` budget is *not* consulted anywhere on the durable path, so a profile that declares `budgets.steps` gets no step ceiling other than the global `Tamoz.configuration.recursion_limit` (default 200, `gems/tamoz-core/lib/tamoz/configuration.rb:15`) — a process-wide constant the profile cannot express. Probe: `budgets: {"steps" => 1}` produced six model calls in one turn and no stop.
- **Cost of the budget scan (F25-SCL-02).** `budget_usage` calls `checkpoints.effect_census` **once per settle** (`worker_runtime.rb:398-405`) and `exhausted_budget` is invoked on every `settle` (`worker.rb:639`), so each settled thread pays a growing full-table scan of the effect journal twice per poll pass (once here, once again in `emit_durable_model_calls`, `worker.rb:1278`). At the operator ceiling of 32 workers × 50-batch this is the row's clearest resource-bound gap.

## Lens: maintenance and architecture

- Ownership direction is honest: `tamoz-agent` sits above kernel/capabilities/session/profile/tools and defers `tamoz/sqlite` and `tamoz/comms` to `WorkerRuntime.open` (`worker_runtime.rb:42-51`) so the gem never loads storage at require time. The gemspec pins all 15 dependencies to the same version (`tamoz-agent.gemspec:11-27`).
- The worker is a composition, not a second engine: every durable decision delegates to an existing seam (`worker.rb:14-35`). Vocabulary is consistent and the "no headless auto-approval path" invariant is visibly upheld (`worker.rb:22-27`; `worker_runtime.rb:500-509`; `settle_paused_view` at `754-778` never invents an answer).
- `platform`/`require`s are narrow; `Runtime` is `private_constant`-guarded for its mixins (`step_execution.rb:292`, `plan_review.rb:141`).
- `DeferredModel#respond_to_missing?` (`deferred_model.rb:47-49`) calls `model`, which **builds** the model — a `respond_to?` probe eagerly constructs the provider client the class exists to defer. Minor but a real inversion of the class's stated purpose.
- `lane_config.rb` is defined and required but has no consumer in this gem (`grep` over `gems/*/lib` finds no `LaneConfig.build` caller); it is dead surface in this row's inventory.

## Tests and contracts

Every file was run one-file-per-command with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`.

| Command | runs | assertions | F |
|---|---:|---:|---:|
| `ruby -Itest test/agent_runtime_test.rb` | 11 | 54 | 0 |
| `ruby -Itest test/agent_runtime_effects_test.rb` | 10 | 44 | 0 |
| `ruby -Itest test/agent_budget_test.rb` | 7 | 20 | 0 |
| `ruby -Itest test/agent_request_routing_test.rb` | 18 | 232 | 0 |
| `ruby -Itest test/agent_terminal_progress_test.rb` | 4 | 19 | 0 |
| `ruby -Itest test/runtime_directory_config_test.rb` | 6 | 43 | 0 |
| `ruby -Itest test/agent_worker_test.rb` | 25 | 122 | 0 |
| `ruby -Itest test/agent_worker_fail_closed_test.rb` | 5 | 10 | 0 |
| `ruby -Itest test/agent_worker_failure_reason_test.rb` | 6 | 14 | 0 |
| `ruby -Itest test/agent_worker_mcp_test.rb` | 11 | 35 | 0 |
| `ruby -Itest test/agent_mode_switch_test.rb` | 4 | 45 | 0 |
| `ruby -Itest test/agent_durable_routing_test.rb` | 4 | 33 | 0 |
| `ruby -Itest test/agent_unattended_policy_test.rb` | 6 | 26 | 0 |

Total: **117 runs / 697 assertions / 0 failures / 0 errors / 0 skips** across the 13 contract files. `rake ci` / `rake ci_full` were **not run** (out of budget, and forbidden by the brief).

`test/agent_budget_test.rb` **not found** for the budgets this row matters most: it exercises `model_calls` only. There is no test for `steps`, `cost_usd`, `input_tokens`, or `output_tokens` enforcement anywhere in `test/`.

**Independent probes** (temporary files under `/tmp`, all deleted; no repo scratch):
1. `RuntimeDirectory` + `WorkerRuntime` over a real runtime dir: `thread_budgets("t1")` returned `{"model_calls"=>2,"steps"=>1,"cost_usd"=>0.01}` while `budget_usage("t1")` returned only `{"model_calls"=>0,"wall_clock_seconds"=>0.06}` — the usage ledger has no key for the other four.
2. `budgets: {"steps" => 1}` + a looping task: **no** `request.stopped`, **no** budget exhaustion, and the effect journal held 3 plan + 3 review `model.generate.*` successes.
3. `budgets: {"model_calls" => 2}` under an identical workload: one `request.stopped` with `budget: "model_calls"` and a durable exhaustion row.
4. `budgets: {"cost_usd" => 0.000001, "input_tokens" => 1, "output_tokens" => 1}`: no stop.
5. `budgets: {"wall_clock_seconds" => 0.05}` after a 0.2 s delay: `request.stopped` with `budget: "wall_clock_seconds"`. **The `documentation/limitations.md:219` claim that exactly `model_calls` and `wall_clock_seconds` are enforced is confirmed true against the code.**
6. A real `:redirect` cancel request submitted through `WorkerRuntime`'s own session, then the worker: the request settled `completed`, `status_projection.task_state == "completed"`, and the view showed `status: "completed"` with `terminal: {reason: "cancelled_by_user", satisfied: false}`.
7. An unknown tool (`mcp:fake:write_thing`) under the bundled `implement` fallback: projects no argv, lands in `local_execute`/`verb: unknown` (default `ask`) — the governance fallback is fail-closed as claimed.

## Findings

### F25-COR-01 — a cancelled turn is delivered to the operator as a completed request

| Field | Content |
|---|---|
| Severity | **major** |
| Confidence | **high** — source trace plus a runtime probe through the row's own `WorkerRuntime`/`Worker` path |
| Status | **open** |
| Source evidence | `worker.rb:677-688` (`settle_view` dispatches on `view.status` alone); `worker.rb:607-622` (`scheduled_terminal_status` maps `view.status == :completed` + `terminal.satisfied == false` → `:failed` for schedules, proving the worker elsewhere *does* read the reason); `worker.rb:717-727` (`settle_completed_view` → `notify_sink(..., "request.completed", ...)`); `session.rb:490-492` (`lifecycle_status` returns the checkpoint status, not the terminal reason); `session_bindings.rb:82-84` (the cancel directive writes `terminal_reason: 'cancelled_by_user'` with the graph's normal terminal status) |
| Test/contract evidence | No test asserts the worker's event or status projection for a cancelled turn. `test/agent_cli_test.rb:555-586` proves only the *interactive* path records `cancelled_by_user` in the view. `test/cancellation_visibility_test.rb` drives the Comms store directly and never runs a worker. **not found** for the worker path. |
| Scanner signal | none — found by tracing `settle_view` against the terminal reason set in `terminal_progress.rb:16` |
| Independent judgment | **Confirmed by probe.** After the cancel redirect was consumed by the worker, `rt.events` contained `request.completed` (not `request.stopped`), its `status_projection.task_state` was `"completed"`, and `session.view` returned `status: "completed"` with `terminal: {reason: "cancelled_by_user"}`. A supervisor reading the outbox sees a successful turn. |
| Root cause | `Worker#settle_view` was written against the four graph lifecycle statuses and never learned the terminal *reason* vocabulary that carries cancellation. |
| Recommendation | At `Worker#settle_view` (`worker.rb:677-688`), branch on `view.terminal&.fetch("reason", nil)` **before** the `:completed` case and route `cancelled_by_user` to (a) `request.stopped` with `reason: "cancelled_by_user"` and a `task_state` that is not `completed`. Reuse `scheduled_terminal_status`'s existing reason-awareness rather than inventing a second mapping; `TerminalProgress::STOP_ACTIONS` already carries the `cancelled_by_user` phrasing (`terminal_progress.rb:16`), so no new vocabulary is needed. |

Five whys:
1. Why does the operator see "completed" for a cancelled turn? `settle_view` routes on `view.status`, which is `completed`.
2. Why is the status `completed`? Cancellation is implemented as a graph *terminal reason*, and the terminal node commits the graph's normal terminal status.
3. Why is the reason not consulted? The settle layer was built against the four lifecycle statuses and the reason vocabulary arrived later, used only in `scheduled_terminal_status` and `TerminalProgress`.
4. Why did the two layers diverge? Cancellation's durable contract was specified on the Comms/CLI timeline (`tamoz_comms_requests.cancellation_*`) while the worker's terminal contract stayed status-only; no single "terminal disposition" projection owns both.
5. Why was this not caught? The tests that exercise cancellation never run a worker, and the tests that run a worker never cancel — the boundary the defect lives on is exactly the untested intersection. The contract that prevents recurrence is a stated invariant: **the worker's terminal event and status projection must be a function of the terminal reason, not of the checkpoint status alone**, with one test per reason.

### F25-SEC-02 — four of the six pinned budgets are recorded but never enforced

| Field | Content |
|---|---|
| Severity | **major** |
| Confidence | **high** — code trace plus five runtime probes |
| Status | **open** |
| Source evidence | `worker.rb:383-398` (the enforced list is the hardcoded literal `%w[model_calls wall_clock_seconds]`); `worker_runtime.rb:398-405` (`budget_usage` returns a two-key hash); `worker_runtime.rb:391-396` (the profile's full budget hash *is* resolved and handed to the worker); `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:81-83` (six valid `BUDGET_KEYS`, including `cost_usd`, `input_tokens`, `output_tokens`, `steps`); `gems/tamoz-core/lib/tamoz/configuration.rb:15` (`steps` has no per-profile path; the only ceiling is the process-wide `recursion_limit`) |
| Test/contract evidence | `ruby -Itest test/agent_budget_test.rb` → 7 runs / 20 assertions / 0F, but every case sets only `model_calls`. **not found**: no test anywhere in `test/` asserts enforcement of `steps`, `cost_usd`, `input_tokens`, or `output_tokens`. |
| Scanner signal | The brief's own priority question; `documentation/limitations.md:219` names exactly two enforced budgets, which prompted the check. |
| Independent judgment | **Confirmed by probe.** `thread_budgets` returned `{"model_calls"=>2, "steps"=>1, "cost_usd"=>0.01}` while `budget_usage` returned `{"model_calls"=>0, "wall_clock_seconds"=>0.06}`. With `budgets: {"steps" => 1}` a looping turn made six model calls and ended `request.failed reason=no_check` with **no** `request.stopped` and no exhaustion row. `cost_usd`/`input_tokens`/`output_tokens` behaved identically; `wall_clock_seconds` and `model_calls` stopped correctly. |
| Root cause | The profile schema and its documentation were written as a forward-looking six-key vocabulary while the enforcement ledger implements two; the gap is disclosed in a limitations page but is invisible at the moment an operator writes `budgets.steps: 3`. |
| Recommendation | Smallest credible action at the existing seam: in `Worker#exhausted_budget` (`worker.rb:383-398`), iterate the **profile's** budget keys with a per-key evidence source, adding `steps` (from the committed checkpoint `logical_step`, the value `enforce_task_limits!` already guards) and leaving the three accounting keys on a documented `unenforced` path; **or**, if that is not wanted, refuse the four unenforceable keys at `DocumentValidator#budgets!` so an operator cannot pin a ceiling that does nothing. Do not build a token/cost ledger — nothing in the model path reports usage to this runtime yet (`documentation/limitations.md:219-224`). |

Five whys:
1. Why does `budgets.steps` not stop the run? `exhausted_budget` never looks at it.
2. Why not? It iterates a hardcoded two-name array rather than the profile's declared keys.
3. Why is that array hardcoded? The two enforced budgets were implemented against the ledgers that already existed (effect journal + occurrence record); the other four had no ledger.
4. Why do the other four remain accepted in a profile? The key list and its validation (`BUDGET_KEYS`, `validate_budget!`) were built for the pinned-and-recorded contract, and the only place that distinguishes enforced from recorded is prose in a limitations page.
5. Why does the prose not protect anyone? Nothing in the write path consults it — `tamoz profile preview` accepts `steps: 1` silently. The contract that prevents recurrence is a machine-checked distinction: every accepted budget key must either name its enforcement ledger or be refused at validation.

### F25-REL-01 — the child-session builder drops the MCP source from the worker's own child path

| Field | Content |
|---|---|
| Severity | **minor** (severity would rise if a caller is shown to route child work through `session_for`) |
| Confidence | **low** — source evidence is real, runtime consequence unproven within budget |
| Status | **unconfirmed** |
| Source evidence | `worker_runtime.rb:721-728` (`build_child_session` → `build_session(..., mcp: nil, ...)`); `worker_runtime.rb:1030-1057` (`build_session`'s `mcp:` default is the runtime's `mcp_source`, but the child call overrides it); `worker_runtime.rb:708-719` (`session_for_child` memoizes the nil-MCP session under `['child', child_id]`); `worker.rb:261-340` (a child thread reaches `claim_and_run` → `settle` → `settle_child_task` through the *same* worker entry point) |
| Test/contract evidence | `ruby -Itest test/agent_worker_mcp_test.rb` → 11 runs / 35 assertions / 0F; `test/agent_child_task_runtime_test.rb` exists but was **not run** (out of budget). Neither is cited here as covering this path. |
| Scanner signal | none |
| Independent judgment | **Could not establish.** I did not complete a runtime probe that drives a child task end to end with MCP configured. Recorded as a lead with exact citations rather than asserted as a defect. |
| Recommendation | One line: pass `mcp: mcp_source` in `build_child_session` (`worker_runtime.rb:721-728`) **if** child tasks are meant to reach MCP, or state in the comment why a child is deliberately local-only. Decide before writing a test; the current code is ambiguous about which it is. |

### F25-OBS-01 — `headless_auto_approvals` is a hardcoded zero, not an evidence count

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **high** |
| Status | **open** |
| Source evidence | `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:619` (`"headless_auto_approvals" => 0`) beside three sibling counters that are real counts over the effect census (`604-615`); asserted by `test/support/autonomy_case.rb:474-489` |
| Test/contract evidence | `assert_hard_counters_zero` (`autonomy_case.rb:482-489`) passes because the value is a literal. |
| Scanner signal | none |
| Independent judgment | **Confirmed**: the counter has no evidence expression. The *invariant* it stands for is separately and genuinely upheld — `settle_paused_view` records the question durably and never invents an answer (`worker.rb:754-778`), and `WorkerRuntime` has no path that writes a decision (`worker_runtime.rb:500-509`) — so this is an observability defect, not a safety hole. |
| Recommendation | Either derive it (count approvals whose `actor_id` is a worker identity) or rename the field so the status page does not present an asserted constant as a measured counter. |

### F25-SCL-02 — the budget gate rescans the whole effect journal twice per settled thread

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **medium** — source trace is direct; no load measurement was taken |
| Status | **open** |
| Source evidence | `worker_runtime.rb:398-405` (`effect_census` inside `budget_usage`); `worker.rb:639` (`exhausted_budget` runs on **every** `settle`); `worker.rb:1274-1294` (a **second** `effect_census(limit: 10_000)` in the same `settle`); `worker.rb:65,213-221` (the same code runs at up to 32-way concurrency) |
| Test/contract evidence | **not run** — no load or soak test was executed (out of budget). |
| Scanner signal | none |
| Independent judgment | The census is bounded (`limit: 10_000`) and the pool is clamped, so this is a cost question, not an unbounded one. It is worth recording because the ceiling is operator-visible and the scan is per-settle, not per-poll. |
| Recommendation | Compute the throttle and the telemetry from one census read per settle, and skip the budget gate entirely when `thread_budgets` is `nil` (the common unbudgeted case) — both are local edits inside `settle` and `exhausted_budget`. |

### Carried-forward findings — current-source status in this row

| ID | Severity / status | Does it still reproduce? | Is F25 the owning seam? |
|---|---|---|---|
| **F25-SEC-01** | critical / open | **Yes.** `WorkerRuntime#session_for` (`worker_runtime.rb:701-706`) → `thread_profile` (`694-698`) → `profile` (`820-824`) → `load_profile` (`826-842`) re-reads `profiles/<id>.yaml` by id; nothing in this path reads a session's recorded `profile_digest` (contrast the *child* path, which does read it at `1116-1123`). | **Yes — this row owns it.** The defect lives entirely in `gems/tamoz-agent`. |
| **CF04-REL-01** | major / open | **Source still reproduces.** `EffectDispatcher#terminal_attempt` still prefers any succeeded attempt and is still used by the `:failed` branch (`effect_dispatcher.rb:97-101, 280-283`). **Reachability from F25 could not be established**: every `:idempotent` effect on the durable session path is `Prepared` with an execution-scoped key (`session_effects.rb:19-46, 67-85`; `effect_preparation.rb:52-62`) that carries the execution id, so a *dynamic* logical key differs per execution and a session replay re-prepares without ever reaching the `'failed'` head branch. I probed a failed `read_file` turn: it re-planned and produced a *new* plan-stage key, and a `:failed` head alone (attempt 1, `repairable` true, `requires_reconciliation` false) returns action `execute`, not `:failed` — the dispatcher's replay branch is not on this path. | **No — the owning seam is `tamoz-agent-kernel` (`EffectDispatcher`) as recorded in `FINDINGS.md:13`.** F25 does not change its disposition, and the recorded recommendation stands unchanged. |
| **CF05-SEC-01** | major/contract / open | **Yes, and this row creates the unrestricted default.** `Runtime#initialize` builds `CapabilityBinding` with neither profile nor MCP (`runtime.rb:139`); the MCP admission set is `toolbox.allowed_tools + child + @mcp.names` (`capability_binding.rb:165-169`), so a `CapabilityBinding` given an MCP source admits all of its names. The governance fallback for *unknown* descriptors is genuinely fail-closed (`capability_binding.rb:206-209`; `policy_document.rb:57-75`), which narrows but does not answer the admission contract question. | **Partly — F25 owns the default-binding call site; the contract decision belongs to CF05.** |

## Blind spots

- `gems/tamoz-agent-cli` was read only where it wires this row (`cli_worker_commands.rb:268-290, 600-620, 670-713`; `cli.rb:783-851`). The interactive `Runtime`/`ask` path's CLI surface is F24's row.
- `tamoz-sqlite`, `tamoz-graph`, `tamoz-agent-session`, `tamoz-agent-kernel`, `tamoz-agent-capabilities`, and `tamoz-approval` were read **only at the seams this row crosses** (listed in Scope). A defect wholly inside one of them, not reachable from an F25 call, is out of scope here.
- **No load, soak, or crash-kill test was run.** Lease takeover, kid-session MCP behavior, and the two-workers-one-thread question are settled by source reasoning plus the SQLite fencing code, not by a race experiment. `documentation/limitations.md` additionally records that the single-writer takeover evidence currently fails in this environment ("Single-writer recovery evidence remains partial (invariant 20)"), so that property is *not* fully evidenced anywhere — I record it as a limitation of this audit, not as an F25 finding.
- `test/agent_child_task_runtime_test.rb` and `test/agent_worker_mcp_test.rb`'s MCP child coverage were not run; `test/sqlite_effect_journal_test.rb` was not run (it belongs to F07).
- The `EpisodeGraph` (v4) is declared in this row but is driven by `tamoz-stream`; I traced its node/edge topology and its "only `reason` and `execute_tool` are model/tool-calling nodes" claim against the node list (`episode_graph.rb:66-129`), but did not execute an episode.
- I did not read `documentation/limitations.md` in full (only the sections relevant to budgets, MCP, and durability evidence).

## Verdict

**IMPROVE.** Counts: **critical 0, major 2, minor 3, info 1** (F25-COR-01, F25-SEC-02 major; F25-REL-01, F25-OBS-01, F25-SCL-02 minor; the carried-forward reconciliation table is `info`). Two carried-forward findings are **confirmed still reproducing on current source** (F25-SEC-01, CF05-SEC-01); CF04-REL-01 reproduces at its own seam but I could not reach it from this row and do not change its disposition.

All six lenses were reviewed with source evidence. The verdict is `IMPROVE` on the BAR.md threshold (at least one accepted critical/major finding); it is not `INCOMPLETE` because both the full source trace and all six lenses are present, with the blind spots above stated rather than implied away. The row's strongest properties — fenced leases, durable-before-execute ordering, the fail-closed `durable` wrapper, the composition-not-engine worker, and the "no headless auto-approval" invariant — are real and I confirmed them; the two majors are both places where a durable *reason* exists but a *decision* reads something else.
