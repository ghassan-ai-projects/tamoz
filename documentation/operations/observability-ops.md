# Observability for operators

Tamoz's observability is an observer-only signal plane: it explains a turn,
measures what it cost, and proves what it did not do — and it cannot change what
the run does. Signals are written to a bounded local journal under the runtime
directory; there are no durable telemetry tables, so the observability gems add
no writer and no migration to the SQLite record.

Current version: `0.1.0.alpha.1` (pre-release).

## The state surface: `tamoz status --json`

`status` is what an operator needs without a UI. With `--json` it reports:

- `pending_work` — threads with work waiting;
- `paused_approvals` — threads paused on an approval, with the exact interrupt
  (kind, tool, task id) they are waiting on;
- `blocked_effects` — effects sitting at `:unknown`, listed by effect key;
- `budget_exhaustions` — durable records of occurrences that hit a budget
  ceiling;
- `capability_sources` — what the operator asked for in `config.yaml`;
- `capability_catalog` — what the agent can actually dispatch (the two differ
  whenever a source is configured but not yet wired);
- `memory` — the memory configuration summary (tenant, owner);
- `safety_counters` — evidence-derived counts: duplicate effects,
  unknown-effect retries, unauthorized effects, headless auto-approvals;
- `channels` — surfaces, last-poll age, outbox depth, `:unknown` deliveries and
  comms safety counters;
- `observability` — journal file count, bytes and counted drops.

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz status --json
```

Every safety counter is a count of durable evidence, so "zero" means "the
journal contains no instance of this", not "nothing incremented a variable".
The counters are derived by `status` from the effect journal — a component is
never the only witness to its own safety.

## The journal: `tamoz observe`

The worker writes bounded, rotating NDJSON journals in the runtime directory.
The journal is observer-only and never a second writer; every bounded bulk drop
is counted. The `observe` verbs:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz observe tail --follow --json
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz observe metrics --format prometheus
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz observe doctor --json
```

- `observe tail` — streams journal entries; `--follow` keeps watching, `--thread`
  and `--kind` filter, `--since MS` starts after a millisecond timestamp.
- `observe metrics` — renders the derived local metrics as JSON (default) or
  Prometheus text (`--format prometheus`).
- `observe doctor` — the redaction self-test: it emits a secret-shaped value and
  a token-shaped value, and fails unless the secret was dropped, the token was
  recorded, and neither appears in the journal.

## Traces: `tamoz trace`

`tamoz trace THREAD` reconstructs the journal view for one thread from its
durable correlation identity:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz trace THREAD --json
```

Trace identity is derived, never generated: the trace id is a digest over
`(thread_id, execution_id)`, so a resumed turn (including one that paused for an
approval) is one trace. `--execution ID` narrows to one execution.

## Content and secret policy

Content capture is off by default. Every signal carries a policy digest and a
digest/size pair for omitted content, so two runs can be proven to have sent the
same prompt without the prompt leaving the machine. Two properties hold by
construction:

- **Secrets never appear.** `Tamoz::Secret` values are structurally rejected
  before any policy decision, credential-shaped environment variables are
  stripped from every check subprocess, and an MCP child's stderr tail redacts
  resolved credential values by value.
- **The policy is recorded with the signal.** A trace from last week states the
  content policy that produced it.

`tamoz-otel` is an optional, governed exporter: OTLP over HTTP, exact host,
HTTPS only, no redirects, no proxy environment, private destinations refused
unless the operator explicitly opts into local delivery. Installations without
`tamoz-otel` run unchanged and report a typed missing-adapter error for export.

## What is NOT reported yet

**Not reported:** recent completions, and circuit state. Neither has a
cross-cutting query today — the circuit store is per scope and scope id with no
enumeration, and terminal requests leave the pending view by design. Both need a
new read-only storage query and a boundary-registry entry. The authoritative
SQLite read-only telemetry reader and durable model-usage persistence are also
not implemented, so `tamoz trace` reconstructs journal documents and cannot
claim the complete checkpoint/effect tree. See
[`../limitations.md`](../limitations.md) for the measured boundaries.

## Next reads

- [`operations.md`](operations.md) — backup, recovery, channels.
- [`../limitations.md`](../limitations.md) — the observability gaps (invariants 59–61, ADR-044–047).
- [`../../docs/OBSERVABILITY_DESIGN.md`](../../docs/OBSERVABILITY_DESIGN.md) — the design.
