# Operating a durable Tamoz session

Every durable thread is one SQLite file under `--session-dir`, named
`<thread>.sqlite3`. That file is the whole truth of the thread: its checkpoints,
its request inbox, its leases, its effect journal, and its application store.
Back up the file and you have backed up the thread.

Read [`LIMITATIONS.md`](LIMITATIONS.md) for what is outside the fault model.

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

The status is `succeeded`, `abandoned` or `unknown`. The decision is journalled
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

`--json` emits newline-delimited JSON events for every plan, review, approval,
tool call, receipt and terminal transition. Two properties hold by construction:

- **Secrets never appear.** Secret values are rejected from checkpoints, streams
  and instrumentation rather than scrubbed by key name, credential-shaped
  variables are stripped from every check subprocess, and an MCP child's stderr
  tail redacts resolved credential values BY VALUE.
- **A rejection says which layer rejected it.** Structural rejections disclose a
  bounded summary of the issues; semantic and provider-quoting rejections
  disclose only a generic phrase, so a hostile plan cannot use the error channel
  to echo content back.

## Migrations

Schema migrations are numbered, checksummed and applied in one transaction; a
failed migration rolls back every statement, and checksum tampering is refused.
There are five: the base runtime, the memory index, the scheduler, the stream
admission tables and the stream processing plane. A database from an older
Tamoz migrates forward on open; a database from a NEWER Tamoz fails before any
partial load.
