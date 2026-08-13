# Durable sessions

A Tamoz turn can be a durable **thread**: one SQLite file under a session
directory that survives `kill -9`, resumes from its last committed barrier, and
reconciles an interrupted effect from proven state instead of guessing.

Current version: `0.1.0.alpha.1` (pre-release).

## Making a thread durable

Pass `--session-dir` (a directory you own) and `--session` (a name), and use the
`ask` subcommand:

```bash
rbenv exec bundle exec tamoz --session-dir ~/.tamoz/sessions --session fix-parser --root . ask "Fix the parser"
```

Every durable thread is one SQLite file named `<thread>.sqlite3` in the session
directory. That file is the whole truth of the thread: its checkpoints, its
request inbox, its leases, its effect journal, and its application store.

The session directory must not be readable or writable by group or others.

## The interactive subcommands

| Subcommand | What it does |
|---|---|
| `ask` | Start a new turn on a thread |
| `resume` | Answer the approvals or questions a paused thread is waiting on |
| `continue` | Drive a paused thread forward without new input |
| `list` | Show every thread in the session directory |
| `show` | Render one thread's state, plan digest, receipts and outcome |
| `follow-up` | Queue another turn behind the current one |
| `redirect` | Replace the goal of an in-flight turn |
| `cancel` | Route a thread to a terminal cancellation |
| `resolve` | Record a human decision about an `:unknown` effect |

Add `--json` to any of them for a newline-delimited JSON event stream, and
`--non-interactive` to fail instead of prompting.

- `resume THREAD` answers the pending interrupts on a paused thread (approvals
  and questions). `--answer ANSWER` supplies one non-interactively, `--all`
  approves every pending interrupt, `--recover` forces recovery before
  resuming.
- `continue THREAD` advances a paused thread without new input.
- `follow-up THREAD TASK` queues another turn behind the current one.
- `redirect THREAD NEW-TASK` replaces the goal of an in-flight turn.
- `cancel THREAD` routes the thread to a terminal cancellation; `--force`
  cancels even when the thread is not active.
- `show THREAD` renders status, plan digest, interrupts and effect receipts;
  `--transcript N` controls how many records are shown.

## What survives a crash

1. **`kill -9`.** A killed process leaves the thread at its last committed
   barrier. Restart it with `continue` or `resume` — no loss, no guessing.
2. **Interrupted effects.** The effect journal returns the recorded receipt for
   work that already completed, so a reviewed edit is applied exactly once
   across both processes.
3. **Staging leftovers.** A crash can orphan a private `.tamoz-*.tmp` file
   beside its target. The next action-capable session sweeps files older than
   60 seconds automatically.
4. **A dead owner's lease.** `thread namespace already has an unexpired lease`
   means a previous owner died holding the lease. Wait for the TTL to expire; a
   new owner takes over automatically.

Backup and restore, and the full crash-recovery runbook, are in
[`../operations/operations.md`](../operations/operations.md).

## When a thread will not move

| Symptom | What it means | What to do |
|---|---|---|
| `status: paused` with interrupts | The thread is waiting for YOU | `resume` (answer them) or `continue` (drive it without new input) |
| An effect at `:unknown` | An unsafe effect's outcome could not be determined, and Tamoz refuses to guess | Establish the truth yourself, then `resolve` |
| `thread namespace already has an unexpired lease` | A previous owner died holding the lease | Wait for the TTL to expire; a new owner takes over automatically |

An `:unknown` effect is the one state nothing automatic can leave. That is the
design: a non-idempotent effect whose outcome nobody observed must not be
retried blindly.

### Resolving an `:unknown` effect

Establish the effect's real outcome yourself, then record the human decision:

```bash
rbenv exec bundle exec tamoz --session-dir DIR resolve THREAD EFFECT_KEY succeeded
```

The status is `succeeded`, `failed` or `abandoned` — exactly the three states
the effect journal can be resolved into. (`unknown` is the state being resolved
*out of*, and is refused as an answer.) The decision is journalled as a durable
transition with your actor identity — it is an audited record, not a status
flip.

## Exit codes

The CLI reports its outcome through its exit status, which is what a script or
supervisor should read.

| Code | Meaning |
|---|---|
| `0` | OK — the turn completed and its verification is satisfied (a direct response also exits 0) |
| `1` | Fatal error (`tamoz: ...`), or a failed turn |
| `2` | Incomplete — the turn completed but verification is **not** satisfied |
| `3` | Paused — the thread is waiting for an approval, a question, or a blocked effect resolution |
| `64` | Usage error — bad arguments or flags (`Try 'tamoz --help'.`) |
| `130` / `143` | Interrupted by `SIGINT` / `SIGTERM` |

## Next reads

- [`install.md`](install.md) — installation and the full subcommand surface.
- [`../operations/operations.md`](../operations/operations.md) — backup, restore, crash recovery.
- [`../reference/cli.md`](../reference/cli.md) — every subcommand and flag.
