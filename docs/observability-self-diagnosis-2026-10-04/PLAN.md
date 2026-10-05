# Self-diagnosis and durable traceability — plan

**Branch:** `observability-self-diagnosis` (worktree from `main` @ `7df2cc9e`) · **Set:** 2026-10-04 ·
**Bar:** [`QUALITY_BAR.md`](QUALITY_BAR.md) · **Deferred work:** [`FUTURE_PLAN.md`](FUTURE_PLAN.md)

## 1. The request, and the scope the owner set

1. Raise observability and traceability toward what German regulation expects of an AI system.
2. Let Tamoz read its own state (durable record, telemetry journal, counters), produce reports and
   analysis, find bugs, failures and mistakes, and write a postmortem about itself.
3. Change the ADRs this needs; retire any that contradict it.
4. Prove it with an eval: that it works, what it is worth, what it cannot do yet.

Mid-task the owner set the scope: *"if EU AI Act is too complicated do not implement it, just make it
a plan for the future"* and *"keep the agent simple as much as possible; anything that adds complexity
now we should defer to a future plan"* (now an owner rule in `AGENTS.md`). So this change builds the
smallest thing that makes Tamoz explain and diagnose itself from its durable record. The regulatory
machinery — tamper-evident seal chain, retention, reporting clocks, the AI Act / NIS2 / DSGVO mapping
— is designed in `FUTURE_PLAN.md`, not built.

## 2. What exists today

| Piece | Where | State |
|---|---|---|
| Durable record: requests + transitions, effects + attempts + transitions, checkpoints, approval decisions, occurrences, deletion receipts | `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb` | The source of truth (ADR-045) |
| Telemetry journal (NDJSON, rotating, lossy, drops counted in health sidecars) | `gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb` | Not an audit log (ADR-045, ADR-047) |
| `tamoz observe tail|metrics|doctor`, `tamoz trace` | `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:58-190` | Journal only |
| `TelemetryReader` — read-only reconstruction contract | `gems/tamoz-observability/lib/tamoz/observability/telemetry_reader.rb` | **Stub, no implementation, no dependents** (enola) |
| Read-only open + migration verification | `DatabaseFile#verify_backup!`, `Migrator.verify_connection!` | Used for backups only |
| Investigation: operator-declared read-only MCP probes; `report_findings` whose every finding must cite a probe call that answered | `documentation/guides/investigation.md` | Built; real-model measured |
| Typed failure vocabulary (closed categories) | `gems/tamoz-agent-healing/lib/tamoz/agent/healing/failure_record.rb` | Built |

`documentation/limitations.md:118-132` names the gap this closes first: "the SQLite read-only
telemetry adapter [is] not implemented".

## 3. Design — five small pieces, no new gem, table, migration, loop or model path

### 3.1 `Tamoz::SQLite::RecordReader` (tamoz-sqlite)

Implements `TelemetryReader` v2 (redefined; v1 removed, ADR-059) by duck type — `tamoz-sqlite` never
references observability.

- Opens read-only (`readonly: true`, `PRAGMA query_only = ON`), verifies the schema with the existing
  `Migrator.verify_connection!`, never migrates or creates the database. Verified on this machine: the
  database file stays byte-identical; SQLite creates `-wal`/`-shm` at mode 0600 when absent, and the
  normal adapter reopens afterwards.
- Returns frozen string-keyed rows of metadata and digests: `requests`, `effects` (with attempt
  timings), `approval_decisions`, `checkpoints` (status/sequence only), `occurrences`. Payload,
  response, result and checkpoint content are never read. A failure blob yields only validated `class` and `code` identifiers; its message and schedule
  completion evidence are excluded. Report surfaces scrub secret-shaped metadata and correlation.
  One read transaction pins all queries in a reader to the same snapshot.

### 3.2 Diagnosis (tamoz-observability, pure)

`Diagnosis.run(records:, journal_health:, rules:, now_ms:, since_ms:)` → `Report` value.

- **Rules are data:** `gems/tamoz-observability/diagnosis/rules.yaml`, digest on every report. A rule
  names a detector, its parameters, a severity, a category (healing vocabulary) and the operator text.
- **Six detectors, parameterized by the rules:** `status` (rows of a kind in given statuses — e.g.
  `unknown` effects), `age` (rows in a status for longer than N — stuck effects, queued requests,
  pending approvals), `failure_rate` (failed share of an operation family over the window, with a
  minimum count), `failure_groups` (failures grouped by error class and code, optionally within an
  operation family), `journal_events` (named error events in the lossy journal), `telemetry_loss`
  (counted journal drops, which also mark the report `degraded`, ADR-047).
- **Findings** carry a stable id, count, first/last seen, subjects and evidence references
  (`kind`, `key`) that resolve to rows. Diagnosis returns a value; it cannot write, enqueue or call.

### 3.3 `tamoz explain THREAD [--request ID]`

One turn's decision record from the reader: the request and its outcome, every effect (model, tool)
with attempts and durations, every approval with verdict, rule, policy revision and the actor evidence
of whoever answered, pauses, failures. An unanswered approval reads `unanswered`.

### 3.4 `tamoz diagnose` and `tamoz postmortem`

- `tamoz diagnose [--since DURATION] [--json]` prints the report (Markdown or JSON).
- `tamoz postmortem --since … --title TEXT [--analysis REPORT.json] [--out DIR]` writes
  Markdown + JSON: summary, impact, timeline of durable events, findings, unknowns (degraded windows,
  missing sources), proposed actions from the rules (never executed). `--analysis` embeds a findings
  report from `tamoz investigate --json`, so the root-cause narrative comes from the real model through
  the existing citation-checked investigation loop.

### 3.5 `tamoz self-observe` — Tamoz investigates itself

A stdio MCP server (official `mcp` SDK, already a dependency) with three read-only tools: `diagnose`,
`explain_turn`, `timeline`. The operator declares it in `config.yaml` under `sources.mcp` with all three
in `read_only_tools`, and declares probes over it. Then `tamoz investigate "what went wrong since
yesterday?"` (or a chat turn that admits the probes) investigates Tamoz itself, every finding citing a
probe call that answered. No new capability source, loop or authority.

## 4. ADRs

| ADR | Change |
|---|---|
| 060 (new, Tier F) | Tamoz diagnoses itself read-only, from the durable record, by rules that are data; every model claim about it cites evidence it read; diagnosis never acts |
| 044 | Amend: the contract gem also owns the reconstruction contract and diagnosis |
| 045 | Amend: durable reconstruction is now built (`RecordReader`) |
| 050 | Relates to 060; stays Proposed — no actuator is built |

**Retirement review.** Nine ADRs were read against this design; none contradicts it, so none is
retired. The reason per ADR is in §7. A future seal chain would amend 045 ("the journal is not an audit
log" stays true; the sealed durable record would become one) — see `FUTURE_PLAN.md`.

## 5. Packages

| # | Package |
|---|---|
| P1 | `RecordReader` + `TelemetryReader` v2 |
| P2 | Diagnosis + `rules.yaml` + `tamoz diagnose` |
| P3 | `tamoz explain` + `tamoz postmortem` |
| P4 | `tamoz self-observe` MCP server + guide |
| P5 | ADR-060, amendments, docs, limitations, `FUTURE_PLAN.md` |
| P6 | Eval |

## 6. Eval (thresholds fixed in the bar before any run)

1. **Fault corpus (plumbing).** Scenarios as data (`test/fixtures/self_diagnosis/`) build real
   databases through the real `tamoz-sqlite` APIs: injected faults among healthy noise, and one clean
   scenario. Detector recall per fault class; false positives on clean.
2. **Value (plumbing).** Same scenarios: faults the existing surface (`tamoz status`,
   `tamoz observe metrics`) names vs `tamoz diagnose`.
3. **Self-investigation (real model).** `tamoz investigate` over the self-observe probes on distinct
   fault scenarios with hidden ground truth, graded deterministically: exact root-cause code selected in the existing hypothesis field, decisive
   evidence in a cited probe result, zero fabricated citations. Complete grading inputs are retained. Controls: oracle passes, null fails,
   adversary (right guess, wrong evidence) fails.

## 7. Retirement review, per decision

| ADR | Why retained |
|---|---|
| 020 | Secrets are refused by type and never scrubbed by name. Diagnosis adds no scrubbing by name: failure output is class and code identifiers, and any secret-shaped value is dropped or redacted by shape (`Tamoz::Core.scrub_secrets`); the state codec still refuses `Tamoz::Secret`. |
| 023 | Self-improvement is candidate promotion, never live self-mutation. Diagnosis changes nothing: proposed actions in a postmortem are text, never executed, and no rule, threshold or behaviour is promoted from a finding. |
| 024 | "Smart" means evidence-based and verified: tests prove plumbing only; real-model claims rest on recorded Z.ai runs with model-free baselines beside them (EVAL §4). |
| 028 | Diagnosis uses the healing vocabulary but introduces no remediation loop. |
| 044 | Contract ownership is extended within its existing gem and adapter boundary. |
| 045 | Durable storage remains the source of truth; the reader adds no table or secondary truth. |
| 046 | Payload/result/checkpoint content stays excluded; schedule completion evidence is excluded too. |
| 047 | Journal loss stays counted and separate from durable evidence. |
| 050 | Conditions are computed without an actuator; automated response stays Proposed. |
