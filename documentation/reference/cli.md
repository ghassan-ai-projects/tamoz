# CLI reference

The `tamoz` executable is the whole operator surface — one CLI, one reference
application. It has two shapes: a one-shot form for a single task, and a
subcommand form for durable sessions and unattended operation.

Current version: `0.1.0.alpha.1` (pre-release).

## Invocation forms

```text
tamoz [global-options] [subcommand] [options] [ARGS]
tamoz [options] TASK
```

The one-shot form runs a single task and exits:

```bash
rbenv exec bundle exec tamoz --root . "Explain the persistence boundary"
```

With `--session NAME`, the one-shot form routes through the durable `ask` path
on that thread.

## Global options

| Flag | Meaning |
|---|---|
| `--profile PROFILE` | Trusted profile path or id (durable sessions) |
| `--model MODEL` | OpenAI-compatible model identifier |
| `--provider PROVIDER` | Model provider (default: `openai`) |
| `--root PATH` | Workspace root (default: current directory) |
| `--session-dir PATH` | Durable session directory |
| `--runtime-dir PATH` | Operator runtime directory (worker, queue, schedule) |
| `--session NAME` | Thread name (default: generated) |
| `--allow-changes` | Enable reviewed and approved workspace changes |
| `--experimental-routing` | Use the experimental fused request router |
| `--shadow-routing` | Record routing decisions while using the standard workflow |
| `--work-routing` | Serve worker and chat turns with the tool-calling work loop |
| `--guidance FILE` | Project guidance file for the work loop, e.g. `AGENTS.md` (repeatable, workspace root only) |
| `--check NAME=COMMAND` | Configure a named verification command |
| `--json` | Emit newline-delimited JSON events |
| `--non-interactive` | Fail instead of prompting |
| `--version` | Print the Tamoz version |
| `-h`, `--help` | Show help |

`--json` and `--help` are also accepted after a subcommand, so `tamoz worker
--json` works without remembering which side of the subcommand the flag belongs
on. Run `tamoz <subcommand> --help` for a subcommand's own options.

## Interactive subcommands

Work you are watching, against a session directory.

| Subcommand | Purpose | Key options |
|---|---|---|
| `ask` | Start a new turn on a thread | `TASK` (positional) |
| `code` | Start a coding turn in the durable tool-calling work loop; needs `--allow-changes` or a profile, and a known context window (profile role `normalized_settings.context_window`, `TAMOZ_CONTEXT_WINDOW`, or the route's recorded window). See [the coding guide](../guides/coding.md) | `TASK` (positional) |
| `resume` | Answer the approvals or questions a paused thread is waiting on | `THREAD`, `--answer ANSWER`, `--approval-profile NAME`, `--recover` |
| `continue` | Drive a paused thread forward without new input | `THREAD` |
| `list` | Show every thread in the session directory | |
| `show` | Render one thread's state, plan digest, receipts and outcome | `THREAD`, `--transcript N` |
| `follow-up` | Queue another turn behind the current one | `THREAD TASK` |
| `redirect` | Replace the goal of an in-flight turn | `THREAD NEW-TASK` |
| `cancel` | Route a thread to a terminal cancellation | `THREAD`, `--force` |
| `resolve` | Record a human decision about an `:unknown` effect | `THREAD EFFECT_KEY {succeeded\|failed\|abandoned}` |
| `profile` | Manage trusted profiles | verbs below |

`resume` answers the pending interrupts of ONE thread; each approval is
resolved through the session's approval engine (an operator deny is a
first-class answer, never an error). `resolve` accepts exactly three statuses:
`succeeded`, `failed`, `abandoned` — `unknown` is the state being resolved out
of and is refused.

### Profile verbs

| Verb | Purpose | Options |
|---|---|---|
| `profile preview PATH` | Validate and render a profile without adopting it | |
| `profile list` | List profiles in the operator profile directory | |
| `profile show ID` | Render one profile | |
| `profile import PATH` | Install a profile into the operator profile directory | `--force` to overwrite |
| `profile activate` | Record a candidate digest transition for a thread | `--thread THREAD --digest DIGEST` |

A repository file such as `.tamoz/suggested-profile.yaml` is evidence only;
`preview`/`import` are the only way it becomes authority.

## Unattended subcommands

Work an operator runs against the runtime directory.

| Subcommand | Purpose | Key options |
|---|---|---|
| `init` | Create the runtime directory for a workspace | `--workspace PATH` |
| `queue` | Submit a task durably, or list pending work | verbs below |
| `worker` | Run the foreground worker that executes queued and scheduled work | `--once`, `--concurrency N`, `--poll-interval SECONDS` |
| `status` | Report pending work, capability sources and safety counters | `--json` |
| `schedule` | Manage recurring work | verbs below |
| `approve` | Grant (or deny) a paused approval so its occurrence can resume | `REQUEST_ID`, `--deny` |
| `observe` | Tail the local journal, render metrics, run the redaction self-test | verbs below |
| `trace` | Reconstruct the journal view for one thread | `THREAD`, `--execution ID` |
| `comms` | The channel surface | verbs below |
| `telegram` | Set up and run the Telegram bot | verbs below |
| `config` | Explicit configuration migration | `migrate` |

### Telegram verbs

| Verb | Purpose | Options |
|---|---|---|
| `telegram setup` | Pair the bot once and write its channel + workspace profile | `--workspace PATH`, `--owner TELEGRAM_USER_ID`, `--env-file PATH`, `--runtime-dir PATH` |
| `telegram start` | Verify the token and provider, then run the gateway and worker together | `--env-file PATH`, `--provider NAME`, `--model NAME`, `--runtime-dir PATH` |

### Chat commands (sent in Telegram)

| Command | Reply |
|---|---|
| `/help [more]` | The short command list, or every command. |
| `/new` | Starts a fresh conversation; earlier messages are no longer used. |
| `/status [r<ref>] [--diagnostic]` | One plain sentence (working, queued, waiting for Approve/Deny, stopping, nothing running); `--diagnostic` prints every state axis. |
| `/cancel [r<ref>]` | Stops every open message in the conversation (or one), replies "Stopping…", and the turn ends with "Stopped." at its next step. |
| `/start <code>` | Pairing: shows the code to read to the operator, or the greeting once paired. |

### Queue verbs

| Verb | Purpose | Options |
|---|---|---|
| `queue add` | Submit a task durably | `--task TASK`, `--profile ID`, `--thread NAME` |
| `queue list` | List pending work | |

### Schedule verbs

| Verb | Purpose | Options |
|---|---|---|
| `schedule add` | Add a schedule | `--id ID`, (`--interval SECONDS` or `--at TIME`), `--task TASK`, `--profile ID`, `--thread NAME`, `--max-steps N`, `--max-wall-seconds N` |
| `schedule list` | List schedules | |
| `schedule show ID` | Render one schedule | |
| `schedule pause ID` | Pause a schedule (lifecycle, not definition) | |
| `schedule resume ID` | Resume a paused schedule | |
| `schedule remove ID` | Remove a schedule (tombstone; history retained) | |
| `schedule run-now ID` | Queue the schedule's task immediately | |
| `schedule occurrences ID` | List an occurrence history | `--limit N` |

`--interval SECONDS` and `--at TIME` are mutually exclusive; `--at` takes an
ISO-8601 UTC instant. A schedule only materializes due occurrences into the
ordinary request inbox — there is one execution path, not two.

### Observe verbs

| Verb | Purpose | Options |
|---|---|---|
| `observe tail` | Stream journal entries | `--follow`, `--thread ID`, `--kind KIND`, `--since MS` |
| `observe metrics` | Render derived local metrics | `--format json\|prometheus` |
| `observe doctor` | Run the redaction self-test | |

### Comms verbs

| Verb | Purpose | Options |
|---|---|---|
| `comms serve` | Run the long-polling gateway (one per bot) | `--surface ID`, `--once` |
| `comms list` | Show surfaces, bindings, conversation-to-thread map, outbox state | `--surface ID` |
| `comms doctor` | Named channel checks; `--bootstrap` before a surface exists | `--bootstrap`, `--credential-ref NAME` |
| `comms pair list` | Show pending pairing codes and active bindings | |
| `comms pair approve CODE` | Approve one pairing code | |
| `comms pair revoke ID` | Revoke a correspondent binding | |
| `comms delivery resolve ID STATUS` | Resolve an `:unknown` delivery | `STATUS` = `succeeded` or `failed` |

`comms serve --once` does a single poll/drain pass and reports each surface's
outcome as JSON. `comms doctor` checks runtime permissions, token presence,
adapter presence, TLS, token validity, the exact bot id, the webhook/poller
conflict and the poller lease — each failure named, exit 1.

### Config verbs

| Verb | Purpose |
|---|---|
| `config migrate` | Migrate runtime configuration schema 1 to schema 2 (`channels:`), with a backup and atomic rename |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | OK — turn completed and verification satisfied (a direct response also exits 0) |
| `1` | Fatal error (`tamoz: ...`), or a failed turn |
| `2` | Incomplete — verification not satisfied |
| `3` | Paused — waiting on an approval, a question, or a blocked effect |
| `64` | Usage error — bad arguments (`Try 'tamoz --help'.`) |
| `130` / `143` | Interrupted by `SIGINT` / `SIGTERM` |

## Next reads

- [`../getting-started/install.md`](../getting-started/install.md) — installation and examples.
- [`../getting-started/sessions.md`](../getting-started/sessions.md) — the session workflow.
- [`config.md`](config.md) — environment variables and the runtime directory.
- [`../operations/operations.md`](../operations/operations.md) — recovery and channel operations.
