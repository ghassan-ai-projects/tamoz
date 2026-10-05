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

## Self-diagnosis

Tamoz can read its own durable record and tell you what went wrong. Everything
here is **read-only**: the database is opened `readonly` with `query_only`,
no migration runs, and nothing is written, enqueued or sent. Payloads, model
responses, tool results and checkpoint state are never selected; a failure
appears as its error class and code only — its message is not shown. Schedule
completion evidence is excluded. Secret-shaped metadata and journal correlation are
redacted at the report surface; the database queries share one read snapshot.

| Command | Answers |
|---|---|
| `tamoz diagnose [--since 24h] [--json]` | Which rules fired in the window, with the rows that prove each finding, plus per-operation attempts, failures, unknown outcomes and p50/p95 latency |
| `tamoz explain THREAD [--request ID] [--json]` | One turn's decision record: requests, executions, every model/tool/check effect with attempts and failures, approvals with policy revision, answer and actor evidence |
| `tamoz postmortem --title T --out DIR [--since 24h] [--analysis FILE]` | A blameless Markdown + JSON postmortem: impact, timeline, findings, unknowns, proposed actions (never executed) |
| `tamoz mcp` | Tamoz's read-only stdio MCP server: `observe_diagnose`, `observe_timeline`, `observe_explain_turn`, so an investigation can read the same evidence |

Pass `--runtime-dir` for a worker or Telegram runtime (`runtime.sqlite3` and its
journal), or `--session-dir` for interactive threads (one database per thread).

**Rules are data.** `gems/tamoz-observability/diagnosis/rules.yaml` holds every
threshold, severity, category (the self-healing failure vocabulary) and the text
an operator reads; each report records the rules digest. A rule names one of six
detectors: `status`, `age`, `failure_rate`, `failure_groups`, `journal_events`,
`telemetry_loss`. Detectors group failures by error class and code, never by
message text.

**Degraded reports.** When the journal's retained health files have counted
dropped signals (a cumulative count, not per window), or a table hit the read
limit (20 000 rows per table), the report says `degraded` and names why: its
journal-derived counts are lower bounds. The durable record itself is never
sampled. Status rules (an unknown effect, an unsettled occurrence) report the
current state whatever the window. Age rules also inspect current unresolved rows, using the
window end as their age clock; they do not reconstruct historical lifecycle state.

**Categories.** Each rule carries a category word from the self-healing failure
vocabulary naming what the rule is about; it is not a per-failure classification.

**Approvals and turns.** In a session directory each database is one thread, so
its approvals belong to it. In a shared worker database approval decisions are
keyed by approval session (`profile:<id>`), not by thread, so `explain` links
them to a turn by time and says `"link": "time_window"`: an approval from any
turn that overlapped in time is shown with it. A request-specific explanation uses this
time-window link in session databases too; approval rows have no request identity. Every
explanation lists record kinds that reached the read limit in `truncated`. A request-specific
view filters effects by their recorded `request_id`; checkpoints are labelled as shared execution
context because they carry execution identity. Terminal failure groups and settled operation
counts/latencies use completion time, so delayed failures belong to the window in which they ended.

`postmortem --analysis FILE` embeds the findings report it is given and labels
it as not verified by the postmortem command; produce it with `tamoz investigate`.

### Let Tamoz investigate itself

Declare the `tamoz mcp` server and probes over it in the runtime's
`config.yaml`, then ask with `tamoz investigate` (or a chat turn that admits
the probes). Every finding in the report must cite a probe call that answered.

```yaml
sources:
  mcp:
    enabled: true
    servers:
      - id: tamoz
        command: /usr/local/bin/tamoz
        arguments: [--runtime-dir, /var/lib/tamoz, mcp]
        env_allowlist: [PATH, HOME, LANG, LC_ALL]
        read_only_tools: [observe_diagnose, observe_timeline, observe_explain_turn]
  probes:
    enabled: true
    targets: {}
    probes:
      - name: probe_self_diagnose
        description: Findings about this Tamoz runtime in the window, ordered most severe first, with evidence rows (error class and code of each failure) and per-operation counts.
        backing: {server: tamoz, tool: observe_diagnose}
        arguments: {from: "{window.from}", until: "{window.until}"}
      - name: probe_self_timeline
        description: Ordered events in the window — failed effect attempts with error class and code, turns, approvals.
        backing: {server: tamoz, tool: observe_timeline}
        arguments: {from: "{window.from}", until: "{window.until}"}
      - name: probe_self_explain_turn
        description: The decision record of one thread, by thread id.
        backing: {server: tamoz, tool: observe_explain_turn}
        arguments: {thread_id: {free: string, max_bytes: 128}}
```

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz investigate "What went wrong in the last 24 hours, and why?" --json > analysis.json
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz postmortem --title "Overnight failures" --out ~/.tamoz/postmortems --analysis analysis.json
```

## What is NOT reported yet

**Not reported:** recent completions, and circuit state. Neither has a
cross-cutting query today — the circuit store is per scope and scope id with no
enumeration. `tamoz trace` still reconstructs journal documents only; merging
the durable record into it, durable model-usage (token and cost) persistence, a
tamper-evident sealed audit trail, and regulatory reporting clocks are designed
but deferred — see
[`docs/observability-self-diagnosis-2026-10-04/FUTURE_PLAN.md`](../../docs/observability-self-diagnosis-2026-10-04/FUTURE_PLAN.md).
See [`../limitations.md`](../limitations.md) for the measured boundaries.

## Next reads

- [`operations.md`](operations.md) — backup, recovery, channels.
- [`../limitations.md`](../limitations.md) — the observability gaps (invariants 59–61, ADR-044–047).
- [`../../docs/OBSERVABILITY_DESIGN.md`](../../docs/OBSERVABILITY_DESIGN.md) — the design.
