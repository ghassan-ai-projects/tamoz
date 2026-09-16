# Independent challenge — F24-ERR-01/02, F02-SEC-01, F02-OBS-01, F03-REL-01/02

Challenger: independent adversarial challenger (read-only audit lane)
Date: 2026-09-15
Baseline: branch `audit-15-09`, commit `582ae55` (`git rev-parse --short HEAD`), tree otherwise unmodified
Method: for each of the six assigned findings I re-read the cited source at the exact `file:line`,
re-ran the claim as a real reproduction (real CLI subprocess for F24, real classes loaded read-only
from the repo for F02/F03), searched beyond the cited files for a missed caller or guard, ran the five
named suites one file per command, and then graded severity against `BAR.md`'s `critical`/`major`/
`minor` definitions. No production file, test, config, gemspec, fixture or other doc was edited; all
probe scripts live under `/tmp/tamoz-agents/` and the repo contains zero scratch files
(`git status --short` shows only the untracked audit directory itself).

Environment: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`; probes run with
the 27-gem `-I` load path mirroring `test/test_helper.rb:11–24`. No credential was supplied and no
provider was called — F24-ERR-01's claim is precisely that the command fails *without* one.

---

## F24-ERR-01

`show` is documented read-only but requires a model credential — report says **major / high**.

### Source re-verified

The citations are accurate, with one nuance the report understates.

- `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:108–119` — `cmd_show` builds a
  `--transcript` parser (line 112), calls `extract_thread!` (113), then
  `run_durable(options, thread_id, read_only: true)` (115). Correct as cited.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:578–606` — `run_durable` at line **585** calls
  `model = build_model(options, profile:)` unconditionally, then `build_toolbox` (586),
  constructs the adapter (587–590), calls `build_mcp_source` (593), `build_approval_engine` (597),
  `build_durable_session` (599). The **only** read of `read_only` is `adapter.close unless read_only`
  (604). Correct as cited — `read_only` genuinely never gates model construction.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:822–833` — `build_model` returns early through a
  `model_factory` (823) and otherwise raises `OptionParser::MissingArgument, "--model or TAMOZ_MODEL"`
  (833). Correct as cited.
- **Citation nuance (not an error):** the report cites `cli.rb:585` for the `build_model` call and
  `cli.rb:604` for the `read_only` use; both correct. It also cites `cli_authority.rb:110` and `:145`
  as operator guidance pointing at `tamoz show`. I confirmed both: line 110 reads
  `"…inspect it with 'tamoz show #{thread_id}' instead"` and line 145 reads
  `"…inspect the session read-only with 'tamoz show #{thread_id}'."` The phrase
  **"read-only"** is literal in the shipped error text — this is a documented contract, not an
  inference.
- The report's `build_list_session` / `peek_session_record` recommendation cites `cli.rb:568–577` and
  `cli_authority.rb:194–197`. Both exist and both use the inert `dummy_model`
  (`def dummy_model.generate(**) = "{}"`). **This is stronger than the report claims:** the same
  pattern is already used on a live, model-free read path —
  `cli_rendering.rb:241–246` `read_list_entry` calls `build_list_session(adapter, options)` then
  `session.view(thread: thread_id)`, i.e. the repo already reads a session's view with no credential.
- I also checked the report's open challenge prompt ("whether a read-only session genuinely never
  calls `model.generate`"). `Session#view` (`gems/tamoz-agent-session/lib/tamoz/agent/session.rb:347–370`)
  is a pure store projection: `app.state` → `SessionRecords.load_state!` → `SessionView.new`. There is
  no model call on that path. The report's proposed fix is therefore safe; the "fails closed" worry it
  raised is resolved in favour of the permissive dummy.

### Reachability + consequence

I ran the real entry point, not a harness:

| Command (real exe, `/tmp` session dir) | Observed |
|---|---|
| `tamoz --session-dir $LS show THREAD` | rc **64**, stderr `tamoz: missing argument: --model or TAMOZ_MODEL` + `Try 'tamoz --help'.` |
| `tamoz --session-dir $LS --model gpt-4o-mini show THREAD` | rc **1**, stderr `tamoz: model_call/credential_unavailable` |
| `tamoz --json --session-dir $LS show T1` | rc **64**, same missing-argument message |
| `tamoz --session-dir $LS list` | rc **0**, `No sessions found.` — no model required |
| `tamoz --session-dir $LS list --json` | rc **0**, printed `No sessions found.` (**not** JSON — a separate quirk) |
| `tamoz --version` | rc **0**, `0.1.0.alpha.1` |

The report's probe is confirmed exactly for `show`, including the `--json` variant.

I then attacked the consequence as instructed. The operational question is whether an operator has a
working model-free read path, because if one exists this is usability debt rather than a material
defect.

- **`list` works and is genuinely model-free** — but it renders a five-field summary row
  (`cli_rendering.rb:244–253`: `thread_id`, `status`, `updated_at_ms`, `summary`). It is built through
  the very `dummy_model` session the report says `show` should use. It does **not** render plan digest,
  effect receipts, approvals, interrupts, terminal reason, or the transcript — which is what
  `documentation/reference/cli.md:59` and the `cli_authority.rb` error strings point at `show` for.
- **`status` does not substitute.** With no `--runtime-dir` it returns rc 1
  `tamoz: no runtime directory: pass --runtime-dir or set TAMOZ_RUNTIME_DIR`; it is the unattended
  runtime surface, not a per-thread session inspector.
- **Reading SQLite directly** is possible for a determined operator, but it means hand-decoding the
  checkpoint state document that `SessionRecords.load_state!` exists to decode, and it bypasses the
  graph-binding enforcement at `session.rb:351`. That is not a supported read path.
- **`show --json` does not exist as an escape hatch** (rc 64 above), so there is no machine-readable
  model-free inspection either.

**Net consequence:** the single command the CLI's own error text and doc name as the read-only
inspection route (`cli_authority.rb:110`, `:145`) is unusable on any host without a provider
credential, and it additionally spawns configured MCP server subprocesses via `build_mcp_source`
(`cli.rb:593`) before it can render a local checkpoint. The operator-visible outcome is a
misleading error: `missing argument: --model` is reported for a command whose contract is that it
needs no model. This is a real, deterministic, operator-facing correctness and observability defect
with a real cost (a documented diagnostic workflow is unavailable exactly in the profile-mismatch and
foreign-session situations it was written for).

### Guards searched

Searched beyond the cited files for anything that would short-circuit `build_model` on the read-only
path: `grep -rn "build_model\|model_factory" gems/tamoz-agent-cli/lib/` returns the definition
(`cli.rb:822`), the one call in `run_durable` (`cli.rb:585`), and the factories used by
`run_one_shot`. There is **no** `read_only` guard, no null-model branch, and no separate read-only
constructor. `build_list_session` (`cli.rb:567–577`) and `peek_session_record`
(`cli_authority.rb:190–200`) are the only inert-model constructors, and `cmd_show` reaches neither.
No missed guard. The defect is real.

### Probe

`/tmp/tamoz-agents/f24probe/probe_err01.rb` (harness) and the real exe, both under a fresh `0700`
session dir `/tmp/tamoz-agents/f24show2.*`:

```
ruby -Ilib <27 gem -I args> gems/tamoz-agent-cli/exe/tamoz --session-dir $LS show THREAD
  rc=64   stderr: tamoz: missing argument: --model or TAMOZ_MODEL
                   Try 'tamoz --help'.
ruby -Ilib <27 gem -I args> gems/tamoz-agent-cli/exe/tamoz --session-dir $LS --model gpt-4o-mini show THREAD
  rc=1    stderr: tamoz: model_call/credential_unavailable
```

Control case (same command family, no model): `… exe/tamoz --session-dir $LS list` → `No sessions found.`
rc 0. The contrast is the proof: `list` reads a session store with a `dummy_model`; `show` cannot.

### Verdict + reason

**UPHELD — major.** The source claim, the mechanism, and the observable CLI behavior all reproduce.
The consequence attack did find a partial workaround (`list`), but `list` renders a strict subset of
`show`'s contract and the CLI's own authority errors direct the operator to `show` by name, so a
material operator workflow is broken. Under BAR this is a material correctness + observability gap
with real operational cost — `major`, not `critical` (no unsafe action, no authority bypass, no data
loss) and not `minor` (the failure is on the documented primary read path, and the error text actively
misleads). Confidence: **high**.

One correction to the record, offered as a strengthening and not a downgrade: the report records the
`dummy_model` fix as a proposal; `cli_rendering.rb:241–246` already executes exactly that pattern on
the model-free `list` path, so the fix is an in-repo precedent rather than new design.

---

## F24-ERR-02

`resume --help` / `cancel --help` call `exit()` from inside `CLI.run` — report says **major / high**.

### Source re-verified

Citations accurate; the finding is under-scoped.

- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:738–746` — `parse_resume_options` registers
  `--answer`, `--recover`, `--approval-profile` and ends in `end.parse!(argv)` at **line 744**. No
  `-h` handler. Correct as cited.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:195–201` — `parse_cancel_force`
  registers `--force` and ends in `end.parse!(argv)` at **line 199**. No `-h` handler. Correct as cited.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:144–156` — `dispatch_subcommand` wraps the call in
  `catch(:tamoz_subcommand_help)` **only** when `NEEDS_HELP_CATCH.include?(subcommand)` (153).
  `NEEDS_HELP_CATCH` (`cli.rb:72–74`) is
  `%w[comms config init queue worker status schedule approve observe trace]` — neither `resume` nor
  `cancel` is present. Correct as cited.
- Contrast confirmed: `accept_json` at `cli_worker_commands.rb:652–658` installs its own `-h` that
  `throw`s `:tamoz_subcommand_help`, which is why `schedule list --help` prints a proper banner and
  returns 0.
- `gems/tamoz-agent-cli/exe/tamoz:6` is literally `exit Tamoz::Agent::CLI.run`. Correct as cited.

### Reachability + consequence

Probed with an in-process harness that records whether `CLI.run` **returned** (writes
`returned_<pid>` after the call) versus exiting; `rc` is captured in the parent shell so the earlier
`| head` pipe artifact does not corrupt it.

| `tamoz <sub> --help` | `CLI.run` returned? | printed on **stdout** |
|---|---|---|
| `resume` | **NEVER-EXITED** | `Usage: probe_err02b [options]` + the three resume options |
| `cancel` | **NEVER-EXITED** | `Usage: probe_err02b [options]` + `--force` |
| `show` | **NEVER-EXITED** | `Usage: probe_err02b [options]` + `--transcript N` |
| `ask`, `continue`, `reset`, `compact`, `usage`, `context`, `think`, `verbose`, `redirect`, `follow-up` | returned 64 | `tamoz: missing argument: …` on stderr |
| `resolve` | returned 64 | `tamoz: missing argument: EFFECT_KEY` |
| `list` | returned 0 | the thread table |
| `status` | returned 0 | `Usage: tamoz status [--json]` |

**Challenge finding — the row report is under-scoped.** It names only `resume` and `cancel`
("exactly these two terminate the process"). It explicitly probed a 12-name list and missed
`show`. `cmd_show` (`cli_session_commands.rb:110–112`) contains an *identical* bare
`.parse!(argv)` with no `-h` handler, and it exits the process the same way. The true count is
**three**, not two: `resume`, `cancel`, `show`. This is a factual error in the report's scope
statement (its "Independent judgment" and "Probe" rows both assert two), and it matters because a
fix written from the report would leave `show --help` broken. Confirmed through the real exe:
`exe/tamoz show --help` → `Usage: tamoz [options]` + `--transcript N`, rc 0, never returns.

The full grep of parser spellings (`grep -rn "\.parse!\|\.order!" gems/tamoz-agent-cli/lib/`) shows
many bare `.parse!` sites, but only these three are reached without a `-h`-throwing wrapper and
without a `NEEDS_HELP_CATCH` catch. `status --help` is in `NEEDS_HELP_CATCH` and the group handlers
that consume `--help` as an action are the separate F24-ERR-03 defect.

**Severity attack (the real question).** The report grades this `major` on the ground that it
"violates the `CLI.run`-returns-a-status contract … and terminates an embedding process outright". I
attacked that, and it does **not** hold up:

- The only shipped caller is `exe/tamoz:6`, which immediately does `exit Tamoz::Agent::CLI.run`. A
  process-level `exit(0)` from inside `run` produces the same observable result as returning `0`:
  the shell sees rc 0. `--help` is a success case, and `exit(0)` *is* success. There is no
  embedding process in this repository: `gems/tamoz-agent-cli` exposes no long-lived host, and
  `CLI.run` has no in-repo caller other than the exe and tests.
- The second consequence the report names — banner text derived from `$0` — is cosmetic and, as the
  probe shows, prints correctly when invoked through the real exe (`Usage: tamoz [options]`). The
  `Usage: probe_err02` artifact in my harness is an artifact of *my* `$0`, not a shipped defect.
- What actually remains is: three subcommands interpret `--help` as success but print an
  `OptionParser` banner listing only their own handful of flags, never reaching the CLI's own help
  text, and never letting `run` return. A script that inspects the return value of an in-process
  `CLI.run` would hang/exit instead — but no such script ships.

That is bounded local correctness/consistency debt on a success path, with **no** production caller
that can observe the difference. Under BAR, `major` requires "real operational cost"; an exit 0 that
is byte-identical in effect to return 0 has none. The honest grade is **minor**.

### Guards searched

`grep -rn "def cmd_\|NEEDS_HELP_CATCH\|accept_json" gems/tamoz-agent-cli/lib/` — no guard exists that
would catch the auto-help throw for these three; `dispatch_subcommand` (cli.rb:153) is the only
catch site and the list omits them. No missed guard. The defect (as narrowed) is real.

### Probe

```
/tmp/tamoz-agents/f24probe/probe_err02b.rb  (records whether CLI.run returned after the call)
ruby -Ilib <27 gem -I args> /tmp/.../probe_err02b.rb resume --help
  rc=0 ; returned marker NOT written ; stdout: Usage: probe_err02b [options] / --answer / --recover / --approval-profile
ruby -Ilib <27 gem -I args> /tmp/.../probe_err02b.rb show --help
  rc=0 ; returned marker NOT written ; stdout: Usage: probe_err02b [options] / --transcript N
CONTROL:
ruby -Ilib <27 gem -I args> /tmp/.../probe_err02b.rb list --help
  rc=0 ; returned marker written "0" ; stdout: the thread table
```

Real exe confirmation: `exe/tamoz resume --help` rc 0, `exe/tamoz cancel --help` rc 0,
`exe/tamoz show --help` rc 0, `exe/tamoz ask --help` rc 64, `exe/tamoz schedule list --help` rc 0
with a proper `-h, --help  Show this subcommand's options` line.

### Verdict + reason

**DEMOTED to minor.** The mechanism is real and even broader than reported (`show` is a third
victim — a source-scope error in the report), but the consequence attack shows there is no caller in
the repository that can distinguish `exit(0)` from `return 0`: the sole entry point is
`exit Tamoz::Agent::CLI.run`, and `--help` is a success path. Under BAR, `major` requires real
operational cost; here the operational cost is a cosmetic banner plus an in-process-only contract
violation with no in-process consumer. That is bounded local correctness/consistency debt —
**minor**. Confidence: **high**. The trio (`resume`, `cancel`, `show`) should be recorded together.

---

## F02-SEC-01

`ProcessGroup` accepts a non-positive pid, retargeting the signal — report says **major / high**.

### Source re-verified

Citations accurate.

- `gems/tamoz-cancellation/lib/tamoz/cancellation/process_group.rb:11–18` — `alive?(pid)` calls
  `Process.kill(0, -pid)` (12) with no guard on `pid`. Correct as cited.
- `process_group.rb:22–27` — `signal(pid, name)` calls `Process.kill(name, -pid)` (23), rescuing only
  `Errno::ESRCH, Errno::ECHILD` (25). No `pid` validation. Correct as cited.
- The class comment at `:5–8` states the contract as "group liveness and group signalling" and
  explicitly pushes per-caller policy to the call sites. It never states a positivity precondition.
  So the primitive advertises a group-id contract that it does not enforce.
- Call sites re-verified: `gems/tamoz-mcp/lib/tamoz/mcp/supervisor.rb:431` (`alive?(@pid)`) and `:437`
  (`signal(@pid, signal)`); `gems/tamoz-tools/lib/tamoz/tools/check_runner.rb:98` and `:100`
  (`signal(pid, 'TERM' | 'KILL')`). Correct as cited.

### Reachability + consequence

Probe (`/tmp/tamoz-agents/f02/probe_sec01.rb`, classes loaded read-only from the repo):

```
my pgid=85113 pid=85114
alive?(0)        => true          # Process.kill(0, -0) == kill(0, 0) == the CALLER'S OWN process group
alive?(-1)       => true          # Process.kill(0, 1) == pid 1
alive?(own pgid) => true          # the legitimate case, indistinguishable from the above
signal(-1,'CONT') => raised Errno::EPERM: Operation not permitted
signal(0,'CONT')  => true         # <-- delivered to Tamoz's OWN process group
alive?('abc') => TypeError ; alive?(nil) => NoMethodError
```

The arithmetic is confirmed and `signal(0, …)` genuinely reaches the caller's own group — as an
unprivileged user, `CONT` is permitted and was delivered. `signal(-1, "KILL")` hits pid 1 and is
`EPERM` for an unprivileged user, matching the report.

**Reachability attack — I searched hard for a caller the report missed and found none.**

```
grep -rn "ProcessGroup" --include=*.rb . | grep -v '^./docs'
  ./test/public_api_test.rb:115                    (the pinned public-surface assertion)
  ./gems/tamoz-tools/lib/tamoz/tools/check_runner.rb:98,100
  ./gems/tamoz-cancellation/lib/tamoz/cancellation/process_group.rb:9
  ./gems/tamoz-mcp/lib/tamoz/mcp/supervisor.rb:431,437
```

Exactly the four lines the report cites, no dynamic `send`, no eval, no other gem, app, `bin/`, or
`Rakefile` reference. Both call sites are positive-pid **by construction**:

- `supervisor.rb:429` — `process_group_alive?` starts with `return false unless @pid`, and `@pid` is
  only ever assigned from `spawn_child_process` (`:227`, a real `Process.spawn`). `:437`'s
  `signal_process_group` is reached only through `terminate_process_group` (`:379–389`), which calls
  `process_group_alive?` first. So `signal` cannot see `0`/`nil` here.
- `check_runner.rb:70` passes `wait_thread.pid` from a real `Open3.popen3(..., pgroup: true)`, which
  is always a positive pid. `nil`/`0` is unreachable.

`ProcessGroup` is also **public API** (`public_api_test.rb:115` pins it as an exported constant), so
a future external caller could pass a bad pid — but that is a hypothesis about callers that do not
exist, not an observed cost. The report itself concedes "no reachable caller is currently unsafe".

### Guards searched

`grep -rn "positive?\|Integer(\|validate_" gems/tamoz-cancellation/lib/tamoz/cancellation/process_group.rb`
→ nothing. The gem's own `validate_*!` idiom exists at `cancellation_token.rb:41–43` for callbacks
and is simply not applied here. No guard exists; none was missed.

### Probe

`/tmp/tamoz-agents/f02/probe_sec01.rb` (exact output quoted above), plus the exhaustive caller grep
across `gems/`, `test/`, `apps/`, `bin/`. Both are reproductions I ran, not shipped tests.

### Verdict + reason

**DEMOTED to minor.** I confirmed the arithmetic and the runtime targets exactly as reported, and I
searched for a reachable caller as instructed — there is none, and the report admits there is none.
BAR's `major` requires a gap "with real operational cost"; a missing precondition on a primitive
whose only two callers are positive-pid by construction has no operational cost today. BAR reserves
`critical` for an active boundary violation that can cause an unsafe action; this is the opposite —
a latent boundary gap on an unreachable path. It is a genuine hardening item and a real contract
defect in a public primitive (the comment promises a group-id contract the code does not enforce),
which is `minor`: bounded, local, limited immediate impact. Confidence: **high** (the demotion is
high-confidence; the code fact is exact).

---

## F02-OBS-01

Token-driven cancel durably recorded as `"failed"`, not `"cancelled"` — report says **major / medium**.

### Source re-verified

The citations are accurate **as line pointers**, but the report's central causal sentence is wrong
about which code runs.

- `gems/tamoz-agent/lib/tamoz/agent/worker.rb:1179–1183` — `failure_reason(request)`:
  `error = request.terminal_error; return "failed" unless error.is_a?(Hash);
  error.fetch("reason", "failed").to_s`. Correct as cited.
- `worker.rb:84–117` — `Worker#run` returns the in-memory reason `"signal"` and emits
  `worker.stopped` with it. Correct as cited.
- **The report's mis-citation.** It says this runtime method is `WorkerRuntime#terminal_reason`. It
  is not named `terminal_reason` and it does not live on `WorkerRuntime`; it is the private
  `failure_reason` on `Worker` (`worker.rb:1179`). `grep -rn "terminal_reason" gems/tamoz-agent/lib/`
  returns **no matches at all** — that name lives in `tamoz-agent-session` (a graph-state key) and
  `tamoz-comms-gateway`. The report's `Source evidence` line `worker.rb:1180-1183` is correct; its
  prose attribution (`WorkerRuntime#terminal_reason`) and its five-whys step 2 are not.
- More importantly, the report treats this as the reason a *cancelled* request is recorded `"failed"`.
  I traced who actually calls it:

```
grep -rn "failure_reason" gems/tamoz-agent/lib/tamoz/agent/worker.rb
  673:  reason: failure_reason(request)     # in settle_stale_request — a STALE-CLAIM path
  736:  reason: settled_failure_reason(view)  # in settle_failed_view — the view is :failed
  889:  def settled_failure_reason(view)     # reads view.state[:observations] / :terminal_reason
  1179: def failure_reason(request)
```

`failure_reason` is reached only from `settle_stale_request` (`:660–674`), which handles a request
whose claim is stale — never from a cancellation path. `settled_failure_reason` is reached only from
`settle_failed_view`, which is selected by `settle_view`'s `when :failed` branch
(`worker.rb:680–684`). Neither runs for a token cancellation.

### Reachability + consequence — the two cancellation models never meet

This is the attack the brief asked for, and it dissolves the finding's stated mechanism.

`Worker#poll_once` drives tasks through a pool created with the worker's own token
(`worker.rb:214–220`: `Tamoz::Pool.for(..., cancellation: @cancellation)`). When that token is
cancelled, `Pool::Base#execute` returns early:

```ruby
# pool.rb:80
return cancelled_result(index, cancellation) if cancellation.cancelled?
# pool.rb:103-108
TaskResult::Cancelled.new(index:, reason: cancellation.reason || "cancelled")
```

Probe (`/tmp/tamoz-agents/f02/probe_obs01.rb`):

```
pre-cancel:  ["Succeeded", "Succeeded", "Succeeded"]
post-cancel: ["Cancelled", "Cancelled", "Cancelled"]
responds to value? false
reason => "signal"
inspect => #<data Tamoz::TaskResult::Cancelled index=0, reason="signal">
```

Now follow it into the worker: `progressed_results` (`worker.rb:223–225`) counts
`results.count { |result| value_of(result) == PROGRESSED }`, and `value_of`
(`worker.rb:1219–1221`) is `result.respond_to?(:value) ? result.value : result`.
`TaskResult::Cancelled` is a `Data` with **no `#value`** (probe: `responds to value? false`), so
`value_of` returns the `Cancelled` object itself, which is never `PROGRESSED`.

Consequence: for a token-cancelled pass the worker counts **zero** progressed results and
`advance_thread` is never entered for those entries. **There is no durable write of any kind** — no
`"failed"`, no `"cancelled"`. I then checked the one remaining candidate, the crash path
`handle_thread_failure` → `@runtime.durably_fail_request(..., reason: bounded_reason(error))`
(`worker.rb:355`): that writes `"<SomeError>: <message>"` derived from a **raised exception**, and a
token cancellation does not raise — it short-circuits before the block runs. So the literal value
`"failed"` that the finding is named after is produced by `failure_reason` only when
`request.terminal_error` is a non-Hash, which is the stale-claim path, not the token path.

The in-process token cancellation and the durable `request_cancellation` → `mark_cancellation_observed`
model (`test/cancellation_visibility_test.rb:34–49`) therefore **never meet**, exactly as the brief
hypothesised. The durable cancellation value `'cancelled_by_user'` has a different and real producer:
the queued cancel redirect is consumed by the graph
(`session_bindings.rb:83` → `{ next_node: 'terminal', terminal_reason: 'cancelled_by_user' }`), and
that path is covered by tests (`cancellation_visibility_test.rb:206`, `:283`;
`agent_cli_test.rb:584`).

The CLI argument the report makes is also weaker than stated. `exit_for_view`
(`cli_rendering.rb:124–130`) does fold `:cancelled` into 1, but the token's reason is not lost: for a
SIGINT/SIGTERM the process exit code is produced by the trap path (`Trap::EXIT_CODES`, `trap.rb:12`,
consumed at `cli.rb:13–14`), and `cancel_exit` (`cli_session_commands.rb:234–239`) returns
`exit_for_cancellation` only when `@cancellation&.cancelled?` — the signal codes are reachable.
What I *did* confirm as a real off-by-one in that neighbourhood, and which the report does **not**
record: when `terminal_reason == 'cancelled_by_user'` but `@cancellation` is **not** cancelled,
`cancel_exit` falls through to `0` (`cli_session_commands.rb:239`) rather than `exit_for_view`'s `1`
— a queued-cancel drain reports success. That is a distinct, smaller issue than F02-OBS-01 and I
record it here only so the row owner can decide; it is outside my six assigned findings.

### Guards searched

`grep -rn "terminal_reason" gems/` (non-doc) confirms the name does not exist in
`tamoz-agent` at all, so there is no `:cancelled` branch to find. `grep -rn "stopping?\|@cancellation"
gems/tamoz-agent/lib/tamoz/agent/worker.rb` shows the token is consulted only for loop control
(`:92`, `:102`), pool construction (`:218`) and the interruptible sleep (`:1210`) — there is no
durable write keyed on it. No guard was missed; the finding's premise is what fails.

### Probe

`/tmp/tamoz-agents/f02/probe_obs01.rb` — exact output quoted above, showing `Cancelled` results with
no `#value`. Combined with `worker.rb:1219–1221` and `:223–225` this is a deterministic source proof
that a token-cancelled pass produces no durable terminal write. I did not run a full durable worker to
observe a stored row, because the source proof shows there is no row to observe for this path.

### Verdict + reason

**REFUTED as stated** (the mechanism is wrong), with a **minor** residual. The finding's own
causal claim — that a token-driven cancel reaches `failure_reason`/the `"failed"` fallback and is
durably stored as `"failed"` — is disproved: a token cancellation short-circuits the pool, produces
`TaskResult::Cancelled` with no `#value`, and the worker writes **nothing** durable for it. The two
cancellation models are disjoint by construction. What survives is a narrower, real observability
gap: a token/SIGTERM-stopped turn has **no durable terminal record at all** — the store neither says
`"cancelled"` nor `"failed"`, it says nothing, and the only cancellation signal is the process exit
code. "A durable store that is silent about a cancelled turn" is a genuine gap but a smaller one than
"MISRECORDS it as failed", and it is bounded to a single-operator signal event whose outcome is
already visible in `worker.stopped` (`worker.rb:113–116`) — **minor** under BAR, not major.
Confidence: **high** for the source proof; the report's `medium` was honest and its instinct that the
claim was unverified was correct. The accompanying citation error (`WorkerRuntime#terminal_reason`
does not exist) should be corrected in the record.

---

## F03-REL-01

`StreamSink#finish` closes the queue under a blocked producer, dropping backlog — report says **major / high**.

### Source re-verified

Citations accurate.

- `gems/tamoz-concurrency/lib/tamoz/stream_sink.rb:42–63` — `emit` takes `@emit_mutex` (43), builds
  the part, calls `reserve_sequence!` (53, which takes `@state_mutex` at `:169–171`) and then
  `@queue.push(part)` (58) — a `SizedQueue#push` that blocks when full. The `rescue ClosedQueueError →
  raise StreamClosedError` is at `61–62`. Correct as cited.
- `stream_sink.rb:87–100` — `finish` takes **only** `@state_mutex` (89), sets `@finished`, calls
  `@queue.close` (93) and returns `changed`. It never consults `@emit_mutex`. Correct as cited.
- `stream_sink.rb:30` — `@queue = SizedQueue.new(capacity)`; default 32 via
  `Tamoz.configuration.stream_buffer`. Correct as cited.
- Consumer path: `lifecycle_executor.rb:66–86` runs the block on the coordinator thread and
  `sink&.finish` in the `rescue`/ensure region (`:82`); `stream_emitter.rb:30–36` re-raises
  `StreamClosedError` unless `@sink.cancellation.cancelled?`. Correct as cited — I confirmed the
  re-raise at `:33`.

### Reachability + consequence

I re-ran an equivalent probe against the real class, loaded read-only from the repo
(`/tmp/tamoz-agents/f03/probe_rel01.rb`), with a valid stream type (`node_update`):

```
producer_alive_before_finish=true  status="sleep"  sink_size=4  emitted=4
finish_returned=true
producer_alive_after_finish=false
captured=Tamoz::StreamClosedError  msg="stream closed before emission was accepted"
sink_size_after_finish=4   emitted_total=4/20
finished?=true  closed?=true
consumer_drain_test: consume what is left -> consumer_saw=4
```

This reproduces the report's probe precisely: the producer was blocked in `push` (status `"sleep"`)
with a full queue, `finish` killed it with `StreamClosedError`, the remaining 16 emissions never ran,
and 4 queued parts were left in a closed queue with no counter exposed. Note that a consumer that
drains afterwards still sees the 4 — so the loss is *conditional on the consumer's timing*, which the
report does not say; `finish` does not itself discard the queue, it strands it. The producer's death
is unconditional and is the hard half.

(The first run of my probe used `type: "tick"`, which raised `ConfigurationError` — `stream_sink.rb`
validates `type` against a closed set — and produced a *false negative*. Recording it because it is
exactly the kind of probe artifact a challenger must not report as evidence: the second run with a
valid type is the real result, and it matches the report.)

### The lock-order check (explicitly requested)

The report's `Disposition` asks the reviewer to confirm whether taking `@emit_mutex` inside `finish`
can deadlock against `@state_mutex`. **I tested it, and the answer is: the prescribed order is safe,
but the report's stated reasoning is imprecise.**

- Verified order in `emit`: `@emit_mutex` (43) → `@state_mutex` (via `reserve_sequence!` at 53→169).
- Verified order in `finish`: `@state_mutex` only (89). There is no `@emit_mutex`.
- Probe `/tmp/tamoz-agents/f03/lockorder.rb` shows that the blocked producer holds **`@emit_mutex`
  but not `@state_mutex`**:
  `producer status="sleep"  @emit_mutex.owned?=false  @state_mutex.owned?=false` (neither mutex
  reports as owned from the main thread; the meaningful reading is the `sleep` status plus the
  `push` call site). The producer blocks in `SizedQueue#push` at line 58, which is **outside**
  `reserve_sequence!`'s `@state_mutex` block, so it holds `@emit_mutex` **only**.
- Therefore a `finish` that takes `@emit_mutex` first cannot participate in a cycle: the only other
  lock in `emit` is acquired after `@emit_mutex`, which is the same order. I demonstrated the
  *reversed* order does block (`/tmp/tamoz-agents/f03/lockorder2.rb`: a thread doing
  `@state_mutex → @emit_mutex` stayed alive/`sleep` while an `emit`-order thread held `@emit_mutex`)
  — confirming the ordering constraint is real and that the report's prescription respects it.
- **End-to-end fix test** (`NaiveStreamSink#finish` = `@emit_mutex.synchronize { super }`), with a
  real consumer draining concurrently:

```
producer status before finish="sleep" alive=true size=2
finish thread status after 0.3s = "sleep"   (blocked on @emit_mutex, held by the blocked producer)
consumer(dequeue) draining now...
consumer saw 10
finish_alive=false producer_alive=false captured=NilClass
```

The prescribed fix **works and does not deadlock**: the consumer drained, the producer completed all
10 emissions and captured no error, and `finish` then ran. So the recommendation is viable — with the
caveat that `finish` blocks for as long as the consumer takes to make room, which converts `finish`
from a non-blocking close into one that can hang indefinitely against a stalled consumer. The
report's "drain-then-close" phrasing in its root cause is right; its recommendation should state that
the caller must guarantee the consumer is live, or the second half of its own recommendation
("return a count of events it abandoned") is the safer primitive.

I also note the recommended `@emit_mutex`-only fix does **not** by itself return the abandoned count,
and it does not prevent loss for a producer that has *not yet* entered `emit`; the report's own
`F03-OBS-01` acknowledges the counter half.

### Guards searched

`grep -rn "StreamSink.new" gems/` → exactly two construction sites, matching the report's caller
trace: `gems/tamoz-graph/lib/tamoz/graph/lifecycle_executor.rb:116` and
`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:391`. `grep -rn "StreamClosedError" gems/` → the raise
sites in `stream_sink.rb` and the single conditional swallow at `stream_emitter.rb:33`. There is no
third caller and no unconditional rescue that would make the producer's death harmless. No missed
guard.

### Probe

`/tmp/tamoz-agents/f03/probe_rel01.rb` (reproduction), `/tmp/tamoz-agents/f03/lockorder.rb` and
`lockorder2.rb` (lock order), and the in-line `NaiveStreamSink` fix test. Exact outputs quoted above.

### Verdict + reason

**UPHELD — major.** The source claim, the mechanism, and the runtime reproduction are exact, and the
caller search confirms there is no guard anywhere on either construction site. The operational cost
is concrete: at graph shutdown a backpressured producer is converted into a `StreamClosedError` that
`stream_emitter.rb:33` re-raises (because the token is not cancelled), so a normal stream teardown
surfaces as a run error while events are silently stranded — the graph path (`lifecycle_executor.rb`
consumed by the CLI) makes this operator-visible. It is not `critical` (no authority bypass, no
durable data loss — the checkpoint is unaffected; the loss is to the observability stream). I add two
qualifications the report should carry: (a) the stranded parts are still readable by a consumer that
drains, so "drops the backlog" overstates the loss relative to "strands it and kills the producer";
(b) the recommended fix is verified deadlock-free **only** in the prescribed `@emit_mutex`-first
order, and it makes `finish` blocking. Confidence: **high**.

---

## F03-REL-02

`Drain#close` returns nil, so an abandoning close is indistinguishable — report says **major / high**.

### Source re-verified

Citations accurate.

- `gems/tamoz-concurrency/lib/tamoz/concurrency/drain.rb:67–76` — `close` sets `@closed` and
  broadcasts under `@mutex` (`68–71`), `@thread.join(Float(deadline_ms)/1_000)` (`72`), then a bare
  `nil` (`73`), with `rescue StandardError; nil` at `74–75`. Correct as cited.
- `drain.rb:53–64` — `flush` **does** return `outstanding` (`62`). Correct as cited — the asymmetry
  with `close` is real and is the sharpest part of the finding.
- `drain.rb:137–139` — `outstanding = @queues.values.sum(&:length) + @in_flight`. Correct as cited.
- `drain.rb:147–161` — `take_batch` continues to deliver while `!@closed || !empty_lanes?`:
  `next if @closed && empty_lanes?` (152). So the drain thread *does* attempt to finish accepted work
  after `close` sets the flag; what `close` cannot tell you is whether it got there in time.
- Consumer: `gems/tamoz-agent/lib/tamoz/agent/durable_recorder.rb:25–29` — `close` calls
  `@recorder.flush(deadline_ms: FLUSH_DEADLINE_MS)` and **discards** the result, then
  `@recorder.close` in an `ensure`. Correct as cited — this is the finding's strongest evidence.

### Reachability + consequence

Reproduced against the real class (`/tmp/tamoz-agents/f03/probe_rel02.rb`, subclassing
`Tamoz::Concurrency::Drain` with a slow `deliver_batch`):

```
before close: depths={:a=>0} in_flight=5 outstanding=5 delivered=5/5
close_returned=nil   elapsed=0.055s
after close:  depths={:a=>0} in_flight=5 outstanding=5 delivered=5/5
flush(deadline_ms: 0) => 5    closed?=true    thread_alive=true
```

Exactly as reported: `close(deadline_ms: 50)` returned `nil` in 0.055 s leaving
`outstanding == 5` (all 5 accepted items still in flight), and the caller has no way to learn that
from the return value. `flush` — called immediately afterwards — *does* report `5`, proving the
information is available and simply not returned by `close`.

(My first two attempts at this probe hung; the cause was my own `compose_batch` calling the public
`depths` from inside the drain thread, which re-enters `@mutex` and raises
`ThreadError: deadlock; recursive locking` at `drain.rb:98`. That is a **probe bug on my side**, not
a defect — `drain.rb:95–97` explicitly documents that the helpers require the caller to hold
`@mutex`. Recorded so the negative result is not mistaken for a finding; the third run above is the
valid one.)

**Severity attack — who calls `Drain#close`, and do they need the count?**

```
grep -rn "close(" gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb \
              gems/tamoz-otel/lib/tamoz/otel/async_exporter.rb \
              gems/tamoz-agent/lib/tamoz/agent/durable_recorder.rb
  async_exporter.rb:103:  @exporter.close(deadline_ms: 0) if closed? && @exporter.respond_to?(:close)
  durable_recorder.rb:25-29: @recorder.flush(...) then @recorder.close in an ensure
```

- `DurableRecorder#close` (`durable_recorder.rb:25–29`) is a **production** consumer. It calls
  `flush` first and throws the count away, which is the report's point and it stands: the code is
  written as if close were a barrier, and it is not.
- `async_exporter.rb:102–104` (`on_thread_exit`) calls `@exporter.close(deadline_ms: 0)` — a
  zero-millisecond grace. This is a *stronger* instance of the same defect than the report cites
  (the report mentions it under the reliability lens but does not fold it into the finding): the
  consumer gets no time at all and no return value to check.

So the finding is **not** test-only; it has two real consumers, one of which is
`tamoz-agent`'s durable recorder. The demotion test the brief proposed ("if the only consumer is a
test, DEMOTE") does not fire.

The concrete cost is bounded but real: instrumentation accepted into a lane and not yet delivered is
lost at shutdown with no durable trace, and the *only* place that could have told the caller is a
return value that is hardcoded to `nil`. The observability drop ledger
(`recorder_journal.rb:99–115`) counts only refusals *after* the closed flag flips, never items
already inside a lane — so the loss is genuinely uncounted, which is the observability half of the
BAR criterion. It is not `critical`: no unsafe action, no authority bypass, no durable-store
corruption — the affected records are telemetry.

The bare `rescue StandardError; nil` at `74–75` is a second, independent defect in the same method:
a failed join is reported as the same `nil` as a successful close, so even a future caller that
checks the return value could not distinguish "clean" from "the join itself blew up". The report
notes this under the reliability lens; it belongs in the finding.

### Guards searched

`grep -rn "< Drain" gems/` → exactly two subclasses (`Journal` in `recorder_journal.rb:13`,
`AsyncExporter` in `async_exporter.rb:9`), matching the report. Both reach `close` through the
consumers above. No third subclass, no override of `close` that restores a count, no caller that
compensates. No missed guard — and, notably, **no consumer inspects the return value**, which is
precisely why the current `nil` has gone unnoticed; that is also why the proposed fix is
behaviour-preserving for every existing caller.

### Probe

`/tmp/tamoz-agents/f03/probe_rel02.rb` — exact output quoted above. Control: `flush(deadline_ms: 0)`
on the same instance returned `5`, proving the value exists and is simply not surfaced by `close`.

### Verdict + reason

**UPHELD — major.** The reproduction is exact, the return-value asymmetry with `flush` is real and
source-verified, and — the point the brief asked me to test — the consumers are **not** test-only:
`DurableRecorder#close` (`durable_recorder.rb:25–29`) is production code that flushes-then-closes and
discards the count, and `AsyncExporter#on_thread_exit` closes with a zero-millisecond grace and no
value at all. Accepted telemetry can therefore be abandoned at shutdown with no counter and no
return value that could have carried one — a real observability/reliability gap on an owned seam,
which is the BAR `major` definition. **Not `critical`** (telemetry, not durable state; no unsafe
action) and **not `minor`** (two production consumers, one of them in `tamoz-agent`, and the drop is
uncounted). The fix (return `outstanding`, hoist the rescue) is minimal and breaks no caller because
none currently reads the value. Confidence: **high**.

---

## Net effect on FINDINGS.md

| Finding | Report | Challenge verdict | One-line reason |
|---|---|---|---|
| F24-ERR-01 | major / high | **UPHELD — keep major** | Reproduced through the real exe; `show` is the documented read-only inspector and fails without a credential, with a misleading `--model` error; `list` renders only a subset, so the workflow is genuinely broken. |
| F24-ERR-02 | major / high | **DEMOTED — change severity to minor, and widen scope to `resume`, `cancel`, `show`** | The mechanism is real and the report missed a third victim (`show`), but `exe/tamoz:6` is `exit CLI.run` and `--help` is a success path, so `exit(0)` is indistinguishable from `return 0` — no operational cost, hence minor. |
| F02-SEC-01 | major / high | **DEMOTED — change severity to minor** | Arithmetic and targets confirmed, but an exhaustive caller search found no non-positive pid anywhere; a missing guard on an unreachable path is hardening, not a major with real operational cost. |
| F02-OBS-01 | major / medium | **REFUTED as stated; residual minor, and the citation is wrong** | A token cancel short-circuits the pool into `TaskResult::Cancelled` (no `#value`), so the worker writes *nothing* durable — not `"failed"`; `WorkerRuntime#terminal_reason` does not exist; what remains is "no durable record at all", which is minor. |
| F03-REL-01 | major / high | **UPHELD — keep major** | Re-reproduced exactly; the lock order is verified safe in the prescribed `@emit_mutex`-first form and the naive fix works without deadlock, though it makes `finish` blocking. |
| F03-REL-02 | major / high | **UPHELD — keep major** | Re-reproduced exactly; the consumers are production, not tests (`DurableRecorder#close`, `AsyncExporter#on_thread_exit`), and the abandoned count is available from `flush` but hardcoded away by `close`. |

Net: the F24 row drops from 2 major to 1 major + 1 minor; the F02 row drops from 2 major to 0 major
(1 refuted-to-minor, 1 demoted-to-minor); the F03 row keeps both majors.

## Focused suite results (one file per command)

| Command | Result |
|---|---|
| `ruby -Itest test/agent_cli_test.rb` | **34 runs, 764 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/cancellation_visibility_test.rb` | **11 runs, 106 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/concurrency_drain_test.rb` | **7 runs, 36 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/core_pool_test.rb` | **11 runs, 137 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/agent_worker_test.rb` | **25 runs, 122 assertions, 0 failures, 0 errors, 0 skips** |

All five pass counts match the reports' tables exactly. **What they do NOT prove:**

- `agent_cli_test.rb` never runs `show` (or any durable command) without a `model_factory`, so it
  cannot see F24-ERR-01; it never invokes `--help` on a subcommand (only global `--help` at `:34`),
  so it cannot see F24-ERR-02; and its `cancelled_by_user` assertion at `:584` exercises the
  *queued-redirect* model, not the token — it is evidence *against* F02-OBS-01's stated mechanism.
- `cancellation_visibility_test.rb` proves `request_cancellation → mark_cancellation_observed →
  terminal wording` end to end, i.e. the model that is **not** the in-process token. It contains no
  `CancellationToken#cancel!` call, so it says nothing about F02-OBS-01 either way.
- `concurrency_drain_test.rb` asserts only that `close` returns *within* the grace
  (`elapsed < 5.0`); it never asserts what was delivered, which is exactly why F03-REL-02 survived.
  Its `close` test cannot fail while `close` returns `nil`.
- `core_pool_test.rb` passes explicit tokens (`:85`, `:98`, `:127`) and never passes a non-positive
  pid to `ProcessGroup`; there is **no** `ProcessGroup` unit test in the tree, which is why
  F02-SEC-01 stands unrefuted by tests.
- `agent_worker_test.rb` proves a real SIGTERM is handled cleanly and exits 0 (`:455–497`) and that
  the interruptible sleep is not hostage to the interval (`:501–531`), but it asserts nothing about a
  durable terminal reason for a cancelled request — consistent with my REFUTAL: there is no durable
  write to assert on.
- No suite in this set exercises `StreamSink#finish` under a blocked producer; there is no
  `*_stream_sink_test.rb` at all, which is why F03-REL-01 survived.

## Liveness log

Per-unit lines appended to `/tmp/tamoz-agents/challenge_cli.log`. Zero scratch files in the repo
(`git status --short` shows only the untracked audit directory).
