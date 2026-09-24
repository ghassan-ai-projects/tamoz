# Operating a durable Tamoz session

Every durable thread is one SQLite file under `--session-dir`, named
`<thread>.sqlite3`. That file is the whole truth of the thread: its checkpoints,
its request inbox, its leases, its effect journal, and its application store.
Back up the file and you have backed up the thread.

Current version: `0.1.0.alpha.1` (pre-release).

Read [`../limitations.md`](../limitations.md) for what is outside the fault
model.

## Backup and restore

Use the online backup — it is consistent against a live writer, refuses to
follow a symlink, and never implicitly overwrites its destination:

```ruby
adapter = Tamoz::SQLite::Adapter.new(path: "sessions/fix-parser.sqlite3")
report = adapter.backup(to: "backups/fix-parser.sqlite3")
```

Restoring is a file copy back into the session directory. A restored copy
resumes from its last committed barrier: `test_a_paused_session_survives_backup_
and_restore_and_resumes_from_the_copy` proves a paused thread restored from a
backup continues rather than restarting.

Do not copy a live database with `cp`. Use the backup API, or stop every writer
first.

## When a thread will not move

```bash
rbenv exec bundle exec tamoz --session-dir DIR --json show THREAD
```

`show` renders the status, the accepted plan digest, the pending interrupts and
the recent effect receipts. The three states worth recognising:

| Symptom | What it means | What to do |
|---|---|---|
| `status: paused` with interrupts | The thread is waiting for YOU | `resume` (answer them) or `continue` (drive it without new input) |
| An effect at `:unknown` | An unsafe effect's outcome could not be determined, and Tamoz refuses to guess | Establish the truth yourself, then `resolve` |
| `thread namespace already has an unexpired lease` | A previous owner died holding the lease | Wait for the TTL to expire; a new owner takes over automatically |

An `:unknown` effect is the one state nothing automatic can leave. That is the
design: a non-idempotent effect whose outcome nobody observed must not be
retried blindly.

```bash
rbenv exec bundle exec tamoz --session-dir DIR resolve THREAD EFFECT_KEY succeeded
```

The status is `succeeded`, `failed` or `abandoned`. The decision is journalled
as a durable transition with your actor identity — it is an audited record, not
a status flip.

## Crash recovery runbook

1. **Confirm the workspace.** A killed publication never leaves a partial public
   file: publication is a rename or a link, so a target either has its old bytes
   or its complete new ones.
2. **Look for staging leftovers.** A crash can orphan a private
   `.tamoz-*.tmp` file beside its target. The next action-capable session sweeps
   files older than 60 seconds automatically; nothing is required of you.
3. **Restart the session.** `continue` or `resume` re-enters the thread at its
   last committed barrier. The effect journal returns the recorded receipt for
   work that already completed, so a reviewed edit is applied exactly once
   across both processes.
4. **If resume reports a typed stop, believe it.** A changed skill tree, a
   changed MCP catalog, a changed egress declaration or a changed behavior
   version each fail closed with their own error. The thread was planned under
   different instructions; restore the exact snapshot or start a new thread.
5. **Check integrity if storage itself is suspect.**
   `adapter.integrity_check.fetch("ok")` runs SQLite's own check. A corrupted
   payload is reported, never silently skipped.

## Retention and deletion

Pruning preserves the active tip of a paused thread and the ancestry a resume
needs. Thread deletion first tombstones new work, then refuses to purge while a
live lease or an unresolved effect exists — an effect must have a separately
authorized, recorded resolution before its thread can be erased, and the final
purge emits a receipt enumerating what was removed and what was retained.

The order matters: deletion never destroys the truth about an effect that
reached the outside world.

## Observability

The worker's `--json` stdout remains the compatibility stream for its lifecycle
events. Operational telemetry is written separately to bounded, rotating journal
files in the runtime directory and can be inspected without a collector:

```bash
rbenv exec bundle exec tamoz --runtime-dir DIR observe tail --follow --json
rbenv exec bundle exec tamoz --runtime-dir DIR observe metrics --format prometheus
rbenv exec bundle exec tamoz --runtime-dir DIR observe doctor --json
```

`tamoz status --json` includes journal size, policy digest and counted drops. The
durable SQLite record remains authoritative for safety and recovery; telemetry is
observer-only and never a second writer. Two properties hold by construction:

- **Secrets never appear.** Secret values are rejected from checkpoints, streams
  and instrumentation rather than scrubbed by key name, credential-shaped
  variables are stripped from every check subprocess, and an MCP child's stderr
  tail redacts resolved credential values BY VALUE.
- **A rejection says which layer rejected it.** Structural rejections disclose a
  bounded summary of the issues; semantic and provider-quoting rejections
  disclose only a generic phrase, so a hostile plan cannot use the error channel
  to echo content back.

See [`observability-ops.md`](observability-ops.md) for the operator's
observability surface.

## Channels

The gateway is one foreground process per bot, supervised the way `tamoz worker`
is. `tamoz status --json` reports a `channels` section — surfaces, last-poll
age, outbox depth and the comms safety counters — so a silent bot is visible
before anyone notices.

### Pairing and revocation

In `admission.direct: pairing` mode an unbound sender receives a short-lived
single-use code, and the OPERATOR approves it — the code grants nothing by
itself:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms pair list
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms pair approve <CODE>
```

Approval consumes the challenge and writes the active binding in one
transaction. Revocation takes effect for future admissions and atomically
invalidates unused approval prompts; it does not rewrite admitted work — the
revoke command prints the affected threads and the exact `tamoz cancel`
commands, and you must run them yourself:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms pair revoke telegram:user:11111111
```

### When a delivery is `:unknown`

A send whose outcome is genuinely unknown (a timeout on the wire, no receipt)
is recorded `:unknown` — never retried blindly, never guessed. The operator
reconciles it against the channel and resolves it explicitly:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms delivery resolve <ID> succeeded
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms delivery resolve <ID> failed
```

`resolve` prints the delivery's effect key; reconcile the journal with
`tamoz resolve THREAD EFFECT_KEY {succeeded|failed|abandoned}` so the effect
journal and the outbox agree. An `:unknown` delivery stays visible in
`tamoz status` until resolved, and blocks purge under invariant 54.

### Approving from a channel or the terminal

Approval authority is a function of evidence strength, not of which transport
pressed a button. A Telegram correspondent supplies `chat_bound` evidence; the
base policy (`gems/tamoz-approval/policy/base.yaml`, `evidence.approve`)
accepts it, so the paired chat can Approve or Deny. A policy that raises
`evidence.approve` to `filesystem_operator` makes the chat deny-only. The local
operator path always works:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz approve REQUEST_ID
```

An approval records a decision; the worker resumes the same occurrence on its
next pass. Deny with `--deny`. The evidence model is in
[`../adr/adr-049-telegram-approval.md`](../adr/adr-049-telegram-approval.md).

## Migrations

Schema migrations are numbered, checksummed and applied in one transaction; a
failed migration rolls back every statement, and checksum tampering is refused.
There are thirteen; the full list and the retirement of the old streaming-engine
tables are in [`../architecture/data-model.md`](../architecture/data-model.md). A
database from an older Tamoz migrates forward on open; a database from a NEWER
Tamoz fails before any partial load.

Runtime configuration schema migrations are separate and explicit: `tamoz
config migrate` moves schema 1 ("no channels") to schema 2 (`channels:`) with
a backup and an atomic rename, and startup never rewrites operator authority.

## Next reads

- [`../getting-started/sessions.md`](../getting-started/sessions.md) — multi-turn sessions and exit codes.
- [`observability-ops.md`](observability-ops.md) — status, journal, metrics, traces.
- [`../guides/telegram.md`](../guides/telegram.md) — the channel runbook.
- [`../limitations.md`](../limitations.md) — measured gaps and non-goals.
