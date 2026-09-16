# F24 `tamoz-agent-cli` — IMPROVE: dispatch and authority are real, but the terminal-facing rendering and the subcommand-help contract are not

Row / queue: F24 (`tamoz-agent-cli`), W2A
Baseline: commit `582ae55`, branch `audit-15-09`, checkpoint date 2026-09-15
Analyst: independent read-only functionality auditor (F24 lane)
Budget: ~45 minutes; six lenses reviewed, two focused suites plus five probes

## Scope and source map

Read end to end (all 16 files, 4,449 lines):

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-agent-cli/lib/tamoz/agent_cli.rb` | 23 | require graph / entry |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` | 919 | dispatch, one-shot, durable driving, error policy, envelope |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_argument_parser.rb` | 126 | global OptionParser grammar + defaults |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_authority.rb` | 211 | profile load / pinned replay / transition consumption |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_option_policy.rb` | 45 | `--profile` / `--check` usage rules |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_prompt_adapter.rb` | 92 | interactive prompt loops |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb` | 259 | human/JSON rendering + exit codes |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb` | 749 | `init`/`queue`/`worker`/`status`/`approve`/`observe`/`trace` |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_schedule_commands.rb` | 343 | `schedule` |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb` | 360 | `ask`/`resume`/`continue`/`list`/`show`/`follow-up`/`redirect`/`cancel`/`resolve`/controls |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_profile_commands.rb` | 348 | `profile preview\|list\|show\|import\|activate` |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_commands.rb` | 263 | `comms serve\|list` + gateway loop supervision |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_shared.rb` | 162 | runtime open, descriptor build, lazy adapter |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_ops.rb` | 356 | `comms pair\|delivery\|request`, `config migrate`, comms status |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_doctor.rb` | 156 | `comms doctor` |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli/version.rb` | 9 | version |
| `gems/tamoz-agent-cli/exe/tamoz` | 6 | executable (E01-owned; read for CLI's own contract only, E01 coverage NOT claimed here) |
| `gems/tamoz-agent-cli/tamoz-agent-cli.gemspec` | 22 | dependency surface |

Supporting seams read because a claim depends on them (not F24-owned): `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb` (342), `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:990–1249`, `gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb` (299), `gems/tamoz-cancellation/lib/tamoz/cancellation/trap.rb` (38), `gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:148–161`, `gems/tamoz-tools/lib/tamoz/tools/creation_operations.rb:24–33`, `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:344–360`.

**Entry seam:** `exe/tamoz:6` → `Tamoz::Agent::CLI.run` (`cli.rb:78`) → `ArgumentParser#parse` (`cli_argument_parser.rb:25`) → `dispatch_subcommand` (`cli.rb:144`) → `SUBCOMMAND_HANDLERS` (`cli.rb:34–63`) → one `cmd_*` per group, each group re-parsing its own argv with a second `OptionParser`.

## Behavior path

1. `ArgumentParser#parse` (`cli_argument_parser.rb:26–31`) builds `default_options` (with `root: Dir.pwd`) and runs `grammar(options).order!(argv)`. `order!` stops at the first non-option token, so the subcommand is `argv.first` iff it is in `SUBCOMMANDS` (`cli_argument_parser.rb:29`).
2. `run` (`cli.rb:99–106`): terminal flag → `0`; subcommand present → `dispatch_subcommand`; otherwise → `run_one_shot`, where `argv.join(" ")` becomes the TASK (`cli.rb:169`).
3. `dispatch_subcommand` (`cli.rb:144–156`) applies `OptionPolicy#validate_check_config` and `#validate_profile_usage`, fetches the handler, and — only for the 10 names in `NEEDS_HELP_CATCH` (`cli.rb:72–74`) — wraps the call in `catch(:tamoz_subcommand_help)`.
4. Each `cmd_*` re-parses its own argv. Two spellings are in use: `accept_json`-based `.parse!` (`cli_worker_commands.rb:652–658`, which installs its own `-h` that `throw`s), and bare `OptionParser.new { ... }.parse!` (`cli.rb:744`, `cli_session_commands.rb:199`), which does not.
5. Durable commands call `run_durable` (`cli.rb:579–606`): private session dir → `build_model` → `build_toolbox` → adapter → `build_mcp_source` → approval engine → session → `install_signal_handlers` (`cli.rb:688–694`) → block.
6. Effects are real: `ask` submits through `session.start` (`cli.rb:211`) and drains to a terminal view (`cli.rb:261–301`); `resolve` writes to the effect journal via `session.resolve_effect` (`cli_session_commands.rb:245–252`); `approve` writes a `DecisionRecord` (`cli_worker_commands.rb:456–474`) and does *not* execute; `schedule add` writes a `Tamoz::Scheduler::Schedule` (`cli_schedule_commands.rb:85–101`); `comms pair approve` verifies the code against the stored digest and consumes it (`cli_comms_ops.rb:106–136`).

## Lens: correctness

Routing is real, not decorative: every name in `SUBCOMMAND_HANDLERS` (`cli.rb:34–63`) resolves to a `cmd_*` that performs an effect, and I found no accept-and-ignore option in the group parsers — `--bogus` on `schedule list`, `queue list`, `comms list` and `observe metrics` all return `64` (probe, `/tmp` harness).

Three correctness defects are proven:

- **`resume --help` and `cancel --help` exit the process from inside `CLI.run`.** `parse_resume_options` (`cli.rb:738–746`) and `parse_cancel_force` (`cli_session_commands.rb:195–201`) end in `.parse!(argv)` on an `OptionParser` with no `-h` handler of its own, so OptionParser's built-in help handler runs and calls `exit(0)` mid-dispatch. Probed: 12 non-catch subcommands were tested; only these two terminate the process, and the remainder return normally. The printed banner is `Usage: -e [options]`, i.e. derived from `$0`, not from the CLI's own banner.
- **`--help` is broken for five command *groups*.** `NEEDS_HELP_CATCH` (`cli.rb:72–74`) lists the group names, but the group dispatchers (`cmd_comms`, `cmd_queue`, `cmd_schedule`, `cmd_observe`) treat `--help` as the *action* argument and raise `InvalidArgument`. Probed: `comms --help`, `queue --help`, `schedule --help`, `observe --help`, `trace --help` all return `64`, while `schedule list --help` and `comms list --help` correctly return `0`. `documentation/reference/cli.md:47` promises `tamoz <subcommand> --help` works.
- **A stray positional after `list` is silently discarded and the command still reports success.** `SINGLE_ARG_SUBCOMMANDS = %w[list]` (`cli.rb:67`) makes `arguments = [options]` and drops `argv` (`cli.rb:151`). Probed: `list garbage` prints `No sessions found.` and returns `0`. By contrast `status extra` (`cli.rb:151`, not in the list) pushes the token into `argv`, `cmd_status` parses no positionals, and the token is dropped there instead — the probe shows it falling through to the one-shot path and demanding `--model`.

## Lens: security and authority

The authority seam is genuinely outside the CLI, and this is the strongest part of the row.

- The CLI does **not** construct approval verdicts. `resolve_interrupt_decision` (`cli.rb:510–526`) only calls `@approval_engine.resolve` with `:approve`/`:deny` derived from the operator's answer, and only after `@approval_engine.decision_log.lookup(decision_id)` confirms *this* process's engine holds the decision (`cli.rb:517`). The verdict itself comes from `Tamoz::Agent.build_approval_engine` (`cli.rb:596`) reading policy data.
- Profile authority is read, never computed: `resolve_session_authority` (`cli_authority.rb:94–146`) replays the pinned snapshot through `Profile.from_authority` and re-checks `pinned.canonical_digest == stored_digest` (`cli_authority.rb:172–177`), and a profile edit only reaches an in-flight thread through an operator-recorded transition consumed at a turn boundary (`cli_authority.rb:117–129`). This is the *counterpart* of **F21-SEC-01** (replay accepts a widened snapshot with the old digest) and **F25-SEC-01** (worker restart reloads the current profile): the CLI's own binding logic is sound; those findings live in `tamoz-agent-profile` and `tamoz-agent` respectively, and F24 does not re-litigate them.
- **CF05-SEC-01 is directly reachable from this row.** `build_mcp_source` (`cli.rb:650–663`) is called on the interactive `ask` path **with the loaded profile in hand**, but passes only the `RuntimeDirectory` to `McpSourceBuilder.new(directory).build` (`cli.rb:662`). `McpSourceBuilder` derives its server list solely from `@directory.enabled_sources` / `source_settings` (`mcp_source_builder.rb:265–287`) and never consults `profile.tools_allowed`. So configured MCP names reach the model beside a restrictive local profile — exactly the CF05-SEC-01 boundary. The CLI validates only that the runtime workspace root matches the CLI root (`cli.rb:655–660`), not that MCP is inside the profile's capability ceiling. Recorded as **duplicate of CF05-SEC-01**, not a new defect.
- Unattended commands correctly take authority from the runtime directory, not from CLI flags: `with_worker_runtime` (`cli_worker_commands.rb:670–690`) opens `WorkerRuntime`, and the session toolbox is built from the *resolved profile* (`worker_runtime.rb:1195–1209`), with `--allow-changes`/`--checks` reaching nothing on that path. `--profile` is additionally refused for every unattended subcommand (`cli_option_policy.rb:27–29`). This is a real invariant, honoured.
- `THREAD_ID_PATTERN` (`cli.rb:76`) is anchored and length-bounded and is applied before any path join in `extract_thread!`/`resolve_thread_id` (`cli.rb:696–720`), so a thread id cannot escape the session directory — no path-escape found on that axis.
- `SINGLE_ARG_SUBCOMMANDS`/`--root`: `--root` defaults to `Dir.pwd` (`cli_argument_parser.rb:37`) and is *not* defaulted from anything the workspace can influence. `provision_private_session_dir!` (`cli.rb:608–615`) creates the session dir `0700` and refuses if `(stat.mode & 0o077)` is non-zero, so a pre-existing world-readable session dir is a hard failure, not a silent widening. The runtime path is separately guarded by `RuntimeDirectory#assert_private!` (`runtime_directory.rb:333–339`). No escape found.
- One authorization-shaped observation, judged **not** a defect: `record_approval` sets `evidence: AuthorityEvidence.filesystem_operator` from code, never from argv (`cli_worker_commands.rb:466–470`). That is the ADR-049 INV-B contract and is correct.

## Lens: reliability and durability

- Effect ambiguity is handled honestly: `Tamoz::Mcp::AmbiguousOutcomeError` maps to `EffectUnknownError` (`mcp_source_builder.rb:160–162`), which is what routes an effect to terminal `:unknown` rather than a repairable retry — and `test/agent_cli_mcp_test.rb` pins it (6 runs, 0F).
- Stale-request terminal failures are rendered once per request id and never re-resumed (`cli.rb:351–387`), with `@rendered_stale_request_ids` as the dedup set.
- `@stream_error` is deliberately not reset across the post-failure poll (`cli.rb:403–405`), so the operator keeps the reason. This kind of reasoning is unusually careful.
- **Signal handling is installed but its result is never converted to an exit code on the interactive path.** `install_signal_handlers` (`cli.rb:688–694`) yields the block and its `ensure` nils `@cancellation`. `exit_for_cancellation` (`cli_rendering.rb:132–138`) reads `@cancellation&.reason` — but by the time `drive_turn`→`exit_for_view` runs, `@cancellation` is whatever it was *during* the block. The only consumer is `cancel_exit` (`cli_session_commands.rb:234–239`), which is reached only from `cmd_cancel`. So `cli.md:166`'s promise of `130`/`143` is honoured for `cancel` and for the worker/gateway traps (which carry their own codes via `Cancellation::Trap::EXIT_CODES`, `trap.rb:12`), but `ask`/`resume`/`continue`/`follow-up`/`redirect` return `exit_for_view` (`cli_rendering.rb:124–130`) and can only ever produce `0/1/2/3`. The existing tests (`test/agent_cli_test.rb:612–638`) do **not** catch this: they set `@cancellation` by hand and call `exit_for_cancellation` directly, never exercising the end-to-end path. This is a contract/evidence gap rather than a proven wrong code, so it is recorded as `info` — I could not construct a deterministic SIGINT through `CLI.run` inside the budget.
- Long-running commands are interruptible: `worker` traps INT/TERM into `worker.stop!(reason)` (`cli_worker_commands.rb:289–294`) and returns `EXIT_WORKER_STOPPED`; `comms serve` traps into `stop_loops` (`cli_comms_commands.rb:135–136`) and restores previous handlers via `Trap.install`'s `ensure` (`trap.rb:31–33`). The comment at `cli_comms_commands.rb:131–134` explains why the stop is thread-deferred (a DB write in trap context raises `ThreadError`) — correct reasoning.
- **`observe tail --follow` (`cli_worker_commands.rb:107–117`) installs no signal handler at all.** It is an unbounded `loop { ...; sleep 0.2 }` with no cancellation token and no trap, so SIGINT kills it with Ruby's default handler (a backtrace-ish exit) rather than a clean stop, and it cannot be asked to drain. Every other long-running command in this CLI is interruptible; this one is not.

## Lens: observability and evidence

- `--json` is a real machine contract: one envelope schema (`ENVELOPE_SCHEMA = 1`, `cli.rb:15`), `emit_event_envelope` (`cli.rb:901–916`), stream-backed parts carry `run_id`/`task_id`/`sequence`/`emitted_at` and synthetic events deliberately carry none rather than nulls. `test/agent_cli_test.rb` pins NDJSON shape and identity round-trip.
- Failure identity is preserved on the error taxonomy: `handle_usage_error` → `64` + `Try 'tamoz --help'.`; `handle_fatal_error` → `1` with `tamoz: <message>`; and `run` catches `ToolError`, `ProtocolError`, `CheckpointConflictError` **explicitly** rather than widening to `Tamoz::Error` (`cli.rb:107–125`). The comment names exactly why. Probed: `show` on a missing thread exits `1` with `tamoz: model_call/credential_unavailable`.
- `status` safety counters are derived from the effect journal, not self-reported by the worker, and the comment at `cli_worker_commands.rb:604–605` states the principle. `observability_status` reports `"unavailable"` rather than fabricated zeros when the journal is broken (`cli_worker_commands.rb:723–729`) — correct.
- A view that cannot be computed becomes `approval_state: "unavailable"` rather than being dropped (`cli_worker_commands.rb:508–543`), so `approve` refuses instead of answering "no paused approval".
- **Secret hygiene is tested and holds on the paths I could reach.** `test/agent_cli_test.rb` asserts a `sk-live-…` secret never appears in `ask --json` or `show --json` output. I found no CLI path that prints a token; `comms_doctor` prints the credential *name* only (`cli_comms_doctor.rb:61`, `99–102`), and `render_profile` prints `credential_ref` by env-var name (`cli_profile_commands.rb:340–342`).
- Weakness: `safety_counters` hardcodes `"headless_auto_approvals" => 0` (`cli_worker_commands.rb:619`) with the justification that the worker has no such path. It is a constant, not a derived count, which sits slightly against the method's own "every counter is a COUNT OF EVIDENCE" claim at `:604`. The comment is honest about this, so it is `info`, not a defect.

## Lens: scalability and resource bounds

- `worker --once` is genuinely bounded: `once: true` reaches `Worker`, and `parse_worker_options` (`cli_worker_commands.rb:299–315`) defaults `concurrency`/`poll_interval` to the `Worker` constants. `--concurrency 0` / `-3` are not validated at the CLI, but `Worker#initialize` clamps `Integer(concurrency).clamp(1, 32)` (`worker.rb:65`) — the bound exists at the owning seam, so this is **not** a CLI defect.
- `queue list` caps at `limit: 200`, `status` at `limit: 500` for pending/occurrences, `paused_approvals` at `500`, `comms delivery resolve` at `500` per surface, `schedule occurrences --limit` defaults to `100`. Every list command has an explicit bound.
- `observe tail --follow` is the exception: unbounded retention. `seen` (`cli_worker_commands.rb:106`) is an ever-growing Hash keyed by entry identity and is **never pruned**, so a long-running follow grows memory monotonically. `render_new_observations` also re-reads the full entry set each 0.2 s poll (`cli_worker_commands.rb:108–116`), so cost is O(all entries) per tick. This is a real unbounded-resource finding on the one command with no bound.
- `run_with_stream` (`cli.rb:389–433`) spawns one worker `Thread` per call and joins it in an `ensure`; the drain loop calls it repeatedly, but each is joined before the next, so threads do not accumulate.
- `--json` mode selects `mode: :all` on the stream emitter (`cli.rb:392`) versus five part types in human mode, so JSON mode is the higher-volume surface by design and has no byte ceiling at the CLI.

## Lens: maintenance and architecture

- The gem boundary is honest: `tamoz-agent-cli.gemspec:13–20` depends on `tamoz-agent` and the capability/session/comms gems, and `tamoz/agent_cli.rb:6–7` requires the runtime plus the comms gateway. `tamoz/sqlite` is deliberately deferred to call time (`cli.rb:580–582`) so `tamoz-agent` never loads the adapter package at require time — a real dependency-isolation decision, not an accident.
- Module splits are by responsibility and each module's methods were private on `CLI` before extraction and stay private (`cli_authority.rb:22–23`, `cli_rendering.rb:27–28`, `cli_profile_commands.rb:45–48`), so `include` does not widen `CLI`'s public surface. `CLI`'s own constants are referenced qualified (`CLI::EXIT_PAUSED`) with the reason recorded at `cli_rendering.rb:30–33`.
- Duplication is bounded and explained: `one_shot_routing` (`cli.rb:199–207`) and `durable_routing` (`cli.rb:640–648`) differ on `--shadow-routing` on purpose, with matching comments at both sites noting unification is an owner decision. Honest.
- `SUBCOMMAND_HANDLERS` is a single frozen dispatch table (`cli.rb:34–63`) — narrow and readable. `NEEDS_HELP_CATCH` (`cli.rb:72–74`) is a *second* list that must be kept in sync with it, and the group-name entries in it are already inconsistent with what the group dispatchers accept (see F24-ERR-03). Two lists describing one thing is the maintenance root of that defect.
- The one-shot path (`run_one_shot`, `cli.rb:158–184`) and the durable path (`run_durable`, `cli.rb:579–606`) build toolboxes and models through separate code with different routing semantics; `build_toolbox` vs `build_profile_toolbox` (`cli.rb:665–685`) is a justified split (profile is capability authority), but `run_one_shot` can never see a profile at all (`cli_option_policy.rb:27–28` refuses `--profile` for `one-shot`).

## Tests and contracts

Run (one file per command, `ruby -Itest test/<file>.rb`, shell prefix as briefed):

| Command | Result |
|---|---|
| `ruby -Itest test/agent_cli_test.rb` | **34 runs / 764 assertions / 0 failures / 0 errors / 0 skips** |
| `ruby -Itest test/agent_cli_profile_test.rb` | **10 runs / 84 assertions / 0 failures / 0 errors / 0 skips** |
| `ruby -Itest test/agent_cli_mcp_test.rb` | **6 runs / 28 assertions / 0 failures / 0 errors / 0 skips** |
| `ruby -Itest test/comms_cli_test.rb` | **12 runs / 60 assertions / 0 failures / 0 errors / 0 skips** |
| `ruby -Itest test/comms_cli_ops_test.rb` | **7 runs / 52 assertions / 0 failures / 0 errors / 0 skips** |
| `ruby -Itest test/observability_cli_test.rb` | **2 runs / 11 assertions / 0 failures / 0 errors / 0 skips** |
| `ruby -Itest test/runtime_directory_config_test.rb` | **6 runs / 43 assertions / 0 failures / 0 errors / 0 skips** |

Not run: `test/agent_session_operations_test.rb` — referenced by `cli_rendering.rb:35` as pinning the rendering contract, but the file does not exist at that path (`LoadError`); the reference is stale. `rake ci` / `rake ci_full` deliberately not run per the brief.

Contract evidence: `documentation/reference/cli.md` (173 lines) is the operator contract; `cli.md:47` is contradicted by F24-ERR-03 and `cli.md:166` is only partly honoured (see the `info` item). `documentation/reference/config.md` (163 lines) documents the runtime directory that F24's unattended commands open.

Test gap evidence: there is **no** test that drives `CLI.run` with `--help` for any subcommand (only `test_help_output_is_stable`, `test/agent_cli_test.rb:34`, which covers global `--help`), no test that runs `show` read-only without a model, and no test that runs `observe tail --follow`. Those three absences are exactly where F24-ERR-01, F24-ERR-02 and F24-REL-01 live.

## Findings

### F24-ERR-01 — `show` is documented and coded as read-only but requires a model credential

- **Severity:** major
- **Confidence:** high
- **Status:** open
- **Source evidence:** `cli_session_commands.rb:115` calls `run_durable(options, thread_id, read_only: true)`; `cli.rb:585` unconditionally calls `model = build_model(options, profile:)` *before* the `read_only` flag is consulted anywhere (its only use is `adapter.close unless read_only`, `cli.rb:604`); `build_model` raises `OptionParser::MissingArgument` when no model is resolvable (`cli.rb:833`).
- **Test/contract evidence:** `ruby -Itest test/agent_cli_test.rb` → 34 runs/0F. `show` at `:187` and `:703` succeeds **only** because the test always passes a `factory:` (`model_factory`), which short-circuits `build_model` at `cli.rb:823` before the raise. No test exercises `show` without a factory. `not found`: any test asserting read-only commands need no credential. `documentation/reference/cli.md:59` lists `show` as "Render one thread's state, plan digest, receipts and outcome" with no model requirement.
- **Scanner signal:** `none` — found by probing `show` on a fresh session dir.
- **Probe:** `ruby -e` harness invoking `CLI.run(['--session-dir',<tmp>,'show','nosuchthread'], env: {})` → `[64, "", "tamoz: missing argument: --model or TAMOZ_MODEL\nTry 'tamoz --help'.\n"]`. With `--model gpt-4o-mini` → `[1, "", "tamoz: model_call/credential_unavailable\n"]`. The same result for `--json show`.
- **Independent judgment:** confirmed. The defect is real and reproduces deterministically. I verified the `model_factory` short-circuit is the only reason CI is green, and that `read_only` genuinely never gates model construction — it gates exactly one line (`adapter.close`). Impact: `tamoz show` is the documented read-only inspection command (and the one `cli_authority.rb:110` and `:145` tell the operator to use to inspect a foreign or mismatched session), yet it cannot run on a machine with no provider configured, and it demands a credential to read a local SQLite checkpoint. I also confirmed `build_mcp_source` (`cli.rb:593`) is inside the same unconditional region, so a read-only `show` additionally spawns configured MCP server subprocesses.
- **Root cause (five whys):**
  1. Why does `show` fail without a model? Because `run_durable` calls `build_model` before the block runs.
  2. Why does it call `build_model` there? Because `run_durable` was written as one constructor sequence for *all* durable commands, and `read_only:` was added to it only to control adapter closing.
  3. Why is `read_only` only about the adapter? Because the flag was introduced for the `show`/`usage`/`context` "peek" family, where the observable difference was believed to be the writer handle.
  4. Why was the model not treated as part of that difference? Because the durable `Session` constructor requires a `model:` keyword unconditionally (`cli.rb:622–635`), so building *a* session — even a read-only one — appears to require one.
  5. Root cause: the constructor sequence in `run_durable` conflates **"open the durable store"** with **"construct a runnable session"**. The contract that would prevent recurrence is an explicit read-only construction path that builds the session with a non-generating model (as `build_list_session` at `cli.rb:568–577` and `peek_session_record` at `cli_authority.rb:194–197` already do with a `dummy_model`) and skips `build_model` and `build_mcp_source` entirely.
- **Recommendation:** the smallest credible action at the existing seam — in `run_durable`, when `read_only` is true, skip `build_model`/`build_toolbox` and pass the same inert model the file's own read-only helpers already use (`build_list_session`, `cli.rb:568–577`; `peek_session_record`, `cli_authority.rb:194–197`), and skip `build_mcp_source`. No new class; the pattern is already in this file twice.
- **Disposition:** accept as `open`. Independent challenge wanted on one point: whether a read-only session genuinely never calls `model.generate`, since if it can, the fix must supply a model that fails closed rather than a permissive dummy.

### F24-ERR-02 — `resume --help` and `cancel --help` call `exit` from inside `CLI.run`

- **Severity:** major
- **Confidence:** high
- **Status:** open
- **Source evidence:** `cli.rb:738–746` (`parse_resume_options`) and `cli_session_commands.rb:195–201` (`parse_cancel_force`) both end in `.parse!(argv)` on an `OptionParser` with only the custom `--answer`/`--recover`/`--approval-profile` (resp. `--force`) options registered — no `-h` handler. `dispatch_subcommand` wraps only `NEEDS_HELP_CATCH` names (`cli.rb:153`), and neither `resume` nor `cancel` is in that list (`cli.rb:72–74`). Contrast `accept_json` (`cli_worker_commands.rb:654–657`), which installs its own `-h` that `throw`s `:tamoz_subcommand_help`.
- **Test/contract evidence:** `ruby -Itest test/agent_cli_test.rb` → 34 runs/0F, `agent_cli_profile_test.rb` → 10 runs/0F. `not found`: any test invoking `--help` on a subcommand. `documentation/reference/cli.md:47` states "Run `tamoz <subcommand> --help` for a subcommand's own options."
- **Scanner signal:** `none` — found by probing every subcommand's `--help`.
- **Probe:** a harness that calls `CLI.run([sc,'--help'], …)` and then writes a sentinel file. For `resume` and `cancel` the sentinel is never written and the process exits `0`, printing `Usage: -e [options]` followed by the three resume options. For the other 12 subcommands tested (`continue`, `resolve`, `think`, `verbose`, `usage`, `context`, `reset`, `compact`, `redirect`, `follow-up`) `CLI.run` returns normally.
- **Independent judgment:** confirmed, and the mechanism is precise. `OptionParser#parse!` (unlike `order!`) leaves the auto-generated `-h/--help` handler in place; that handler prints and calls `exit`. Two consequences beyond the missing help text: (a) the contract in `exe/tamoz:6` (`exit Tamoz::Agent::CLI.run`) and in `cli.rb:78–81` — that `run` **returns** a status — is violated, so any embedding process is terminated outright; (b) the printed banner is `Usage: -e [options]`, taken from `$0`, so even the text is not the CLI's. Existing `--help` coverage (`test/agent_cli_test.rb:34`) only exercises *global* `--help`, which is why this survived. Note the narrower probe result: `resume --bogus-flag` returns normally (that is a `ParseError`, correctly caught at `cli.rb:107`); only the auto-help path exits.
- **Root cause (five whys):**
  1. Why does `resume --help` exit the process? Because the `OptionParser` inside `parse_resume_options` has no `-h` handler, so OptionParser's built-in one runs and calls `exit`.
  2. Why does it have no `-h` handler? Because it was written as a bare `OptionParser.new { … }.parse!` rather than through the file's `accept_json` helper, which is where the `-h`-throws convention lives (`cli_worker_commands.rb:652–658`).
  3. Why does that convention not apply here? Because `accept_json` is a private method of `CLIWorkerCommands`, and `CLI` includes it — so it *is* reachable, but the session/`cli.rb` parsers predate or bypass the convention.
  4. Why was the gap not caught? Because `dispatch_subcommand` gates help-catching on a second hand-maintained list (`NEEDS_HELP_CATCH`, `cli.rb:72–74`) instead of deriving it from the handlers, so a subcommand that is not in the list gets no protection and nothing fails when the list drifts.
  5. Root cause: there is **no single owner of "how a subcommand parses argv and answers `--help`."** Two spellings coexist (`accept_json`-based and bare `parse!`), and correctness depends on a synchronised duplicate list. The contract that would prevent recurrence is one parse helper, used by every `cmd_*`, that always registers `-h` as a throw.
- **Recommendation:** smallest credible action at the existing seam — change the two bare `.parse!` calls (`cli.rb:744`, `cli_session_commands.rb:199`) to use the existing `accept_json`-style helper (or `order!` plus an explicit `-h` that throws), and add `resume`/`cancel` to `NEEDS_HELP_CATCH` so the throw is caught. No new machinery; both pieces already exist in the file set.
- **Disposition:** accept as `open`. Related to F24-ERR-03 — both are the same duplicate-list root cause, and a coordinator may prefer to record them as one finding with two symptoms.

### F24-ERR-03 — `--help` on the `comms`/`queue`/`schedule`/`observe` command groups is a usage error, contradicting `cli.md`

- **Severity:** minor
- **Confidence:** high
- **Status:** open
- **Source evidence:** `cli.rb:72–74` lists `comms`, `queue`, `schedule`, `observe` (and `trace`) in `NEEDS_HELP_CATCH`, but each group dispatcher reads `argv.shift` as the action *before* any parse: `cli_worker_commands.rb:49–55` (`cmd_queue`), `:58–67` (`cmd_observe`), `cli_schedule_commands.rb:15–30` (`cmd_schedule`), `cli_comms_commands.rb:23–35` (`cmd_comms`). With `argv == ['--help']`, `action` becomes `"--help"` and the `else` branch raises `InvalidArgument`.
- **Test/contract evidence:** `ruby -Itest test/comms_cli_test.rb` → 12 runs/0F; `comms_cli_ops_test.rb` → 7 runs/0F. `not found`: any test of a group-level `--help`. Contract: `documentation/reference/cli.md:47`.
- **Scanner signal:** `none` — probe.
- **Probe:** `comms --help`, `queue --help`, `schedule --help`, `observe --help`, `trace --help` all return `64` with `tamoz: invalid argument: usage: tamoz <group> …`. The verb-level forms work correctly: `schedule list --help` and `comms list --help` both return `0` with the parser's own banner.
- **Independent judgment:** confirmed. Severity is minor rather than major because the verb-level help — which is what an operator usually types — works, so the operational cost is bounded to "the obvious first thing you type fails." The `NEEDS_HELP_CATCH` entry for these names is therefore inert: the `catch` exists but nothing ever throws, while the group's own `else` branch fires first.
- **Root cause:** entries were added to `NEEDS_HELP_CATCH` by subcommand *name*, but the help need for these five is at the *verb* level inside a group dispatcher that consumes `--help` as its action. The list encodes an assumption ("this name's parser can throw") that the group dispatchers do not satisfy.
- **Recommendation:** at the existing seam, in each group dispatcher's `else` branch (e.g. `cli_schedule_commands.rb:26–28`), treat `--help` as a help request — print the group's usage and return `0` — instead of raising; or drop these five names from `NEEDS_HELP_CATCH` and let `cli.md:47` say the verb form is the supported one. The first is smaller and matches the sibling commands.
- **Disposition:** accept as `open`, minor.

### F24-SEC-01 — untrusted content reaches the operator terminal unescaped

- **Severity:** minor
- **Confidence:** medium
- **Status:** open
- **Source evidence:** no escaping or sanitization exists anywhere in the gem — a search for `escape`/`sanitize`/ANSI/control handling across `gems/tamoz-agent-cli/lib/` returns only `control_value!` (a positional-argument reader, `cli_session_commands.rb:316`) and prose comments. Untrusted content is written raw: model answer at `cli_rendering.rb:99` (`@out.puts answer`), approval **preview** at `cli.rb:481` (`@err.puts descriptor["preview"]`), clarify question at `cli.rb:483`, tool/route names at `cli.rb:872–881`, and JSON envelopes at `cli.rb:915`. The previews themselves are built raw from file content and diffs: `toolbox.rb:148–161` → `creation_operations.rb:24–33` (`"#{header}#{content}"`), i.e. arbitrary bytes from a workspace file.
- **Test/contract evidence:** `ruby -Itest test/agent_cli_test.rb` → 34 runs/0F. `not found`: any test asserting control-sequence neutrality of rendered output. Secret-redaction tests exist (`test/agent_cli_test.rb`, the `sk-live-…` case) but they assert *absence of a secret*, not absence of control bytes.
- **Scanner signal:** grep over the gem for escaping primitives → none found.
- **Independent judgment:** the code path is confirmed — a `create_file`/`apply_patch` preview containing `\e]0;…\a` or `\e[…m` is transmitted through `@err.puts` with no filtering, and a model answer is transmitted through `@out.puts` likewise. I did **not** construct an end-to-end proof that workspace content reaches a live terminal, because that requires driving a full `ask` with a tool preview through a real tty, which the budget did not allow. Medium confidence for that reason. The mitigating fact I verified: `session_effects.rb:344–348` has a `prompt_safe` that strips control characters — but it is applied to *model prompt* material, not to the CLI's rendering path, so it does not cover this. Impact is bounded to a local single-operator terminal (the attacker must get content into a file the agent is about to show, or into the model's answer), which is why this is minor and not major.
- **Root cause:** the CLI has no output-encoding step at its rendering boundary; every renderer writes domain strings straight to `@out`/`@err`, and the trust boundary between "content the agent read" and "bytes an operator's terminal interprets" was never drawn.
- **Recommendation:** smallest credible action at the existing seam — one private helper on `CLIRendering` that strips C0/C1 control bytes (the same character class `session_effects.rb:347` already uses) and route the model-answer and preview `puts` calls through it. No new class, and the repository already ships the exact predicate.
- **Disposition:** accept as `open`, minor/medium. Needs independent challenge before promotion — the missing piece is a reproducible end-to-end terminal injection.

### F24-REL-01 — `observe tail --follow` is unbounded in both memory and interruptibility

- **Severity:** minor
- **Confidence:** high
- **Status:** open
- **Source evidence:** `cli_worker_commands.rb:107–117` — `loop do … render_new_observations(entries, seen, options); @out.flush; break unless follow; sleep 0.2 end`. `seen` is created at `:106` and only ever written (`:129`, `seen[identity] = true`); it is never pruned. `Journal.read_entries` is called *inside* the loop over the whole journal (`:108–110`), so each tick re-reads and re-filters everything. No `Cancellation::Trap.install` appears in `observe_tail` — compare `cmd_worker` (`:289–294`) and `run_gateway_loops` (`cli_comms_commands.rb:135–136`), which both install traps.
- **Test/contract evidence:** `ruby -Itest test/observability_cli_test.rb` → 2 runs/11 assertions/0F; those cover the observability library, not `observe tail`. `not found`: any test of `observe tail`, `--follow` or `--since`.
- **Scanner signal:** `none` — read of the loop.
- **Independent judgment:** confirmed by reading; the unbounded-memory and O(journal) per-tick costs are structural, not incidental. The interruptibility gap is the sharper half: every other long-running command in this CLI is explicitly designed to be stopped cleanly (with the reasoning recorded at `cli_worker_commands.rb:285–289` and `cli_comms_commands.rb:131–134`), so `observe tail --follow` is an inconsistency in an otherwise-consistent design, and a supervisor's SIGTERM gets Ruby's default handler rather than a clean stop.
- **Root cause (causal, minor):** `observe_tail` was written as a self-contained read loop and never adopted the CLI's shared supervision convention (`Cancellation::Trap.install` + a bound), which the two genuinely long-running commands both use. The dedup set was written for correctness (print each entry once) and its unbounded growth was not considered because the function has no test and no documented runtime expectation.
- **Recommendation:** at the existing seam, bound the dedup set (drop entries older than the newest `--since`/a fixed identity window, or key on a monotonic offset instead of every identity) and install the same `Trap`-based stop the sibling commands use. `cli.md:130` documents `--follow`; the fix keeps that contract.
- **Disposition:** accept as `open`, minor.

### F24-INFO-01 — the pause path can return a status the operator did not give

- **Severity:** info
- **Confidence:** high
- **Status:** open
- **Source evidence:** `drive_resume` (`cli.rb:220–238`) returns `EXIT_PAUSED` (`3`) when `collect_answers_from_view` yields `nil` (`:223`) and when the view is `:blocked` (`:233–234`). `collect_answers_from_view` returns `nil` when `answer_for` returns `nil` (`cli.rb:496`), and `answer_for` returns `nil` whenever `options[:non_interactive]` is set and no `--answer` was given (`cli.rb:531`).
- **Test/contract evidence:** `ruby -Itest test/agent_cli_test.rb` → 34 runs/0F covers the paused/`EXIT_PAUSED` cases; `cli.md:164` defines `3` as "Paused — waiting on an approval, a question, or a blocked effect."
- **Independent judgment:** this is a **verified design fact, not a defect**. In non-interactive mode the CLI declines to invent an answer, and `3` correctly tells the calling script "a human is required." I record it only because the same numeric code serves "the operator answered nothing" and "the agent is blocked," and a caller cannot distinguish the two from the exit code alone — the distinction is available in JSON mode via `cli.paused`'s `reason` (`cli.rb:246`, `:339`). Not a finding; no recommendation.
- **Disposition:** accept as `info`.

### F24-INFO-02 — `headless_auto_approvals` is a hardcoded zero

- **Severity:** info
- **Confidence:** high
- **Status:** open
- **Source evidence:** `cli_worker_commands.rb:619` — `"headless_auto_approvals" => 0`, inside `safety_counters`, whose own introductory comment at `:604–605` states "Every counter is a COUNT OF EVIDENCE, so 'zero' means 'the journal contains no instance of this', not 'nothing incremented a variable'." The neighbouring three counters are all derived from `effects` (`:608–616`).
- **Test/contract evidence:** `not found`: a test asserting the counter is derived.
- **Independent judgment:** verified fact. The inline comment at `:617–619` is honest about the reason (the worker has no code path that answers an approval), and `cmd_approve` confirms the design — it records a decision and does not execute (`cli_worker_commands.rb:338–349`). So the value is *correct*; it is simply not evidence-derived, which is a documentation/consistency nit against the method's own stated principle. No operational impact today; it would silently stay `0` if such a path were ever added.
- **Recommendation:** none needed now. If the counter is meant to be evidence-derived, it belongs with the other three; otherwise its comment should say plainly that it is an invariant assertion rather than a count.
- **Disposition:** accept as `info`.

## Blind spots

- **No end-to-end SIGINT/SIGTERM through `CLI.run`.** I established that `install_signal_handlers` (`cli.rb:688–694`) nils `@cancellation` in its `ensure` and that only `cancel_exit` (`cli_session_commands.rb:234–239`) consumes `exit_for_cancellation`, so the interactive `ask`/`resume`/`continue` family appears unable to return `130`/`143` despite `cli.md:166`. I could not raise a real signal against an in-process run deterministically inside the budget, so this stays an `info`-level contract/evidence gap rather than a recorded finding. **Proving it is the single highest-value follow-up for this row** and the code path to instrument is `cli.rb:688–694` plus `cli_rendering.rb:124–138`.
- **No live terminal injection.** F24-SEC-01's reachability through a real tty was not reproduced (see that finding's confidence note).
- **Required-major finding avoidance:** no `major`-severity issue was confirmed in the `comms serve` gateway supervision, the scheduler command group, or the profile command group beyond what is listed; those were read end to end but not exercised against real Telegram/Telegram-adjacent transports, so a defect there would have appeared as calm reading rather than a failed probe.
- **`tamoz-telegram` not read.** `build_transport` (`cli_comms_shared.rb:120–129`) loads it lazily; its wire behaviour is outside F24's surface and outside what I read.
- **`test/agent_session_operations_test.rb` does not exist** although `cli_rendering.rb:35` cites it as pinning the rendering contract — a stale reference I could not resolve, so the rendering contract's test coverage may be thinner than that comment implies.
- **E01 (`exe/tamoz`) is another analyst's row.** I read it only to establish the `exit … .run` contract that F24-ERR-02 violates; I claim no E01 coverage.
- Not run: `rake ci`, `rake ci_full` (excluded by the brief), and any suite over ~2 minutes. Not attempted: real model or real Telegram calls (no credentials, and out of scope for a read-only audit).

## Verdict

**IMPROVE** — counts: `critical 0`, `major 2`, `minor 3`, `info 2`.

Per `BAR.md`: a `major` finding is present (`F24-ERR-01`), so the row is `IMPROVE` regardless of the minors. `F24-ERR-02` is recorded `major` because it violates the `CLI.run`-returns-a-status contract that `exe/tamoz:6` and every test depend on, and terminates an embedding process outright; it is a contract violation with a real operational cost, but not an authority bypass or unsafe action, so it is deliberately **not** `critical`.

Two independent challenge requests are outstanding and named in the JSON: F24-ERR-01's read-only-model assumption, and F24-SEC-01's terminal-injection reachability. Three lens verdicts are `reviewed`; `scalability` is `reviewed` with a bound-by-bound inventory; no lens is `not evidenced`, but `security` carries the CF05-SEC-01 duplicate rather than a fresh F24 defect, and that is stated plainly rather than counted as F24 coverage.
