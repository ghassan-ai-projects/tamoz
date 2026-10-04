# Self-diagnosis and durable traceability — quality bar

**Task:** Tamoz explains and diagnoses itself from its durable record and writes its own postmortem ·
**Owner:** Ghassan · **Size:** L · **Set:** 2026-10-04 (before the change; scope narrowed by the owner
the same day, before any code) · **Plan:** [`PLAN.md`](PLAN.md) · **Deferred:**
[`FUTURE_PLAN.md`](FUTURE_PLAN.md) · **Governing ADRs / invariants:** ADR-016, 028, 044, 045, 046,
047, 050, 052, 058, 059; invariants 59–61 · **Branch:** `observability-self-diagnosis`

Status values: `PASS` (evidence named) · `FAIL` (what is wrong) · `OPEN` (not built) · `BLOCKED` (reason
named; never a pass) · `WAIVED` (owner only).

## 0. Outcome and fence

**Outcome:** from an operator's runtime, `tamoz explain`, `tamoz diagnose` and `tamoz postmortem`
produce — read-only, from the durable record — a per-turn decision record, a findings report that
names every injected fault class in the corpus with evidence and nothing on a clean runtime, and a
postmortem; and a real model running `tamoz investigate` over `tamoz self-observe` finds the root
cause of Tamoz's own failures with every finding citing evidence it actually read.

**Done when:** every row is PASS (or WAIVED by the owner), the review log has no open critical/high
finding, and the loop log's last iteration changed nothing.

**Scope set by the owner (2026-10-04):** keep the agent as simple as possible; anything that adds
complexity is written into `FUTURE_PLAN.md`, not built. Deferred there: the tamper-evident seal chain,
retention, regulatory reporting clocks, the EU AI Act / NIS2 / DSGVO mapping, durable trace merging,
durable model-usage persistence, alerting.

**Not in scope:** everything above; a new gem, table, migration, capability source, loop or model path;
Go repository changes.

**Owner decisions needed:** none for this scope; the deferred work's decisions are in `FUTURE_PLAN.md`.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `Tamoz::Observability::TelemetryReader` (stub) implemented by `tamoz-sqlite`; the CLI command table (`cli.rb` `SUBCOMMAND_HANDLERS`); investigation probes over an operator-declared MCP server |
| 1.2 | Reused, not copied | `Migrator.verify_connection!`, `DatabaseFile#verify!`, `Recorder::Journal::Files.inventory` (drop counts), `StateCodec#load`, healing categories (as rule data), investigation `report_findings` and its citation check, the official `mcp` SDK |
| 1.3 | Blast radius | enola: `TelemetryReader` — 0 dependents; `CLIWorkerCommands` — CLI dispatcher + 29 test refs (untouched methods) |
| 1.4 | Baseline | enola MCP baseline + `enola baseline pin` in the worktree, both before any code edit, at `7df2cc9e` |

## A. Safety and authority — each test seen to fail under its mutation

| # | Property | Check (test; mutation) | Status |
|---|---|---|---|
| A1 | The reader never writes: the database file is byte-identical after a read; no migration runs; a write through its connection is refused | `test/sqlite_record_reader_test.rb`; mutation: drop `readonly`/`query_only` | PASS |
| A2 | No content leaves the durable record: payload, response, result and checkpoint blobs are never selected; no secret-shaped value reaches a report, explain, postmortem or MCP result | reader test (column scan) + redaction test; mutation: select `payload` | PASS |
| A3 | Diagnosis, explain, postmortem and self-observe cannot act: no DB writer, enqueue, network or effect dispatch is reachable from their files; DB bytes unchanged after every command | `test/self_diagnosis_boundary_test.rb`; mutation: add a writer call | PASS |
| A4 | `explain` attributes every decision: verdict, rule, policy revision, and the actor evidence of whoever answered; an unanswered approval reads `unanswered`, never approved | explain test; mutation: default a missing answer | PASS |
| A5 | Failure text is untrusted: detectors group by error class only; changing a reason's prose never changes which rule fires | diagnosis test; mutation: group by message | PASS |
| A6 | Gem boundaries: observability never references `Tamoz::SQLite`; sqlite never references `Tamoz::Observability` | `test/dependency_isolation_test.rb` + boundary test | PASS |
| A7 | Counted telemetry loss (cumulative over retained health files) marks the report `degraded` | diagnosis test; mutation: ignore health sidecars | PASS |
| A8 | Rules are data: no threshold, severity, category or wording literal in Ruby; a rule naming an unknown detector, kind or category fails at load | `test/diagnosis_rules_test.rb`; mutation: inline a threshold | PASS |

## B. Function — scripted data proves plumbing, never intelligence

| # | Property | Check | Status |
|---|---|---|---|
| B1 | `tamoz diagnose` end to end on a worker runtime dir and on a session dir; Markdown and JSON | `test/agent_cli_self_diagnosis_test.rb` | PASS |
| B2 | `tamoz explain THREAD [--request ID]` end to end on a real database | same file | PASS |
| B3 | `tamoz postmortem` writes Markdown + JSON (summary, impact, timeline, findings, unknowns, proposed actions); embeds `--analysis`; writes only in `--out` | same file | PASS |
| B4 | `tamoz self-observe` answers MCP `initialize`, `tools/list`, `tools/call` over stdio; all tools read-only and bounded; the probe loader accepts a config over it | `test/self_observe_server_test.rb` | PASS |
| B5 | Error paths end typed: missing DB, wrong schema version, unknown thread, bad window, bad analysis file | per-command tests | PASS |
| B6 | Determinism: same database, journal and injected time → byte-identical report | diagnosis test | PASS |
| B7 | Scale: diagnose over 20 000 effects < 3 s here | scale test (slow lane if > 1 s) | PASS |

## C. Evaluation — thresholds fixed before any run

| # | Property | Check | Status |
|---|---|---|---|
| C1 | Grader controls discriminate: oracle report passes; null fails; adversary (right cause, cites a result without the decisive evidence) fails; fabricated citation fails | `test/self_investigation_grader_test.rb` | PASS |
| C2 | Corpus is data, digest-pinned (`test/fixtures/self_diagnosis/scenarios.json`); the builder writes only through real `tamoz-sqlite` APIs | `test/self_diagnosis_corpus_test.rb` | PASS |
| C3 | Detector recall = 100% of injected fault classes; false positives = 0 on the clean scenario (plumbing) | corpus test + EVAL.md | PASS |
| C4 | Value: per scenario, faults named by `tamoz status` / `observe metrics` vs `tamoz diagnose` | EVAL.md | PASS |
| C5 | Real model: ≥ 8 distinct fault scenarios; root cause correct with decisive evidence in a cited probe result in ≥ 6/8; fabricated citations = 0; every run recorded (failed and invalid too); model, calls and cost named; development set, not held out | `runs/provider-credit-2026-10-04.json`: $0.451297018 remains, prior calls refused; no new paid calls; exact-code contract is not yet measured | BLOCKED |
| C6 | One real-model postmortem (`--analysis` from a real investigation) shown verbatim in EVAL.md | EVAL.md | PASS |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Every touched test file, one per command | `VALIDATION.md` focused test table; one file per command | PASS |
| D2 | `rake ci` (minus known-red) | `VALIDATION.md`: full test and gate evidence, known-red proof at HEAD | BLOCKED |
| D3 | `rake ci_full` in both locales (packaging and MCP are touched) | `VALIDATION.md`: full test and gate evidence, known-red proof at HEAD | BLOCKED |
| D4 | RuboCop zero offenses in new files; no new offense in touched files | `bundle exec rubocop <files>` | PASS |
| D5 | enola: no new cycle, layer violation or unintended coupling | `enola check` + `diff_snapshot`: no new cycle/layer; expected scrub-secrets reuse; v0.4.25 coverage limit | PASS |
| D6 | `rake adr:validate adr:verify` | output | PASS |

**Known-red at HEAD** (reproduced 2026-10-04 in detached worktree
`/private/tmp/tamoz-test-quality-baseline` at `7df2cc9e`):
- `stream:proto:check`: installed x86_64 `protoc` cannot run on this arm64 machine
  (`Errno::EBADARCH`).
- C-locale full test loading: `test/agenteval_skills_optimizer_test.rb:11` rejects an invalid
  US-ASCII string. UTF-8 final default suite ran 3,084 tests with one missing documentation-file
  failure, repaired by supplying `VALIDATION.md` and rerunning documentation checks.
- Full later phases are unverified, not graded PASS. See `VALIDATION.md`.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest design: no new gem, table, migration, capability source, loop or model path; six small detectors | diff review | PASS |
| E2 | No shim or alias; `TelemetryReader` v1 removed (ADR-059) | diff review | PASS |
| E3 | No comments beyond the one-line class doc | diff scan | PASS |
| E4 | New files 644, scripts 755; no scratch files | `git ls-files -s`, `git status` | PASS |
| E5 | Methods ≤ 20 lines, classes ≤ 250; no new `.rubocop_todo.yml` entry | RuboCop | PASS |
| E6 | Deferred work is in `FUTURE_PLAN.md`, not half-built in code | review | PASS |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Final report separates plumbing from real-model results; claims nothing unrun | review | PASS |
| F2 | README, CLI reference, observability ops guide, investigation guide, limitations match what was built | `test/documentation_test.rb` + review | PASS |
| F3 | ADR-060 written to the ADR bar; 044/045/050 amended; catalog, index, evidence register updated | `rake adr:validate adr:verify` + review | PASS |
| F4 | Lessons recorded in `AGENTS.md` / `.agent/rules/` in the change that taught them (the owner's defer-complexity rule is in `AGENTS.md`) | review | PASS |
| F5 | The ADR retirement review is recorded with a reason per ADR | PLAN.md §4 | PASS |
| F6 | `FUTURE_PLAN.md` is usable: requirement → design → tests → owner decisions, per deferred item | review | PASS |

## Continuation evidence (2026-10-04)

All PASS rows refer to this continuation's checks in [`VALIDATION.md`](VALIDATION.md), not the prior
uncommitted run. Safety mutations A1–A8 and a snapshot guard each failed in an isolated copy, then the
working-tree regressions passed. The completion-window and shared-execution reproductions were also
seen red before their fixes and green afterward. C5 and the complete gate remain BLOCKED; the overall
outcome is not declared complete. Historical C6 is the recorded artifact printed verbatim in EVAL.md,
not a final-design real-model run.

## Review log

| Package | Findings (critical / high / medium / low) | Resolution | Commit |
|---|---|---|---|
| P1–P3, safety/correctness reviewer | 0 / 1 / 3 / 0 | Excluded schedule evidence; pinned read snapshot; corrected request creation timing; declared explain truncation; independently rechecked | this delivery commit |
| P4–P6 + CLI, architecture/eval reviewer | 0 / 1 / 4 / 0 | Redacted metadata/correlation; exact-code selection rejects negation; retained grading inputs; filtered request approvals; historical results labelled non-replayable | this delivery commit |
| P1–P6, fresh final reviewer | 0 / 1 / 1 / 0 | Delayed failures grouped by completion; request effects bound by request_id and checkpoints labelled as context; final verdict PASS, 29 tests / 90 assertions | this delivery commit |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 1 | 2026-10-04 | Bar set; scope narrowed by owner before code; HEAD gates proven; baselines pinned | 1.1–1.4 answered | all A–F | P1 |
| 2 | 2026-10-04 | Continued existing P1–P6; fixed content export, secret metadata, snapshot and truncation, approval/timeline attribution, grader and replay records; new files lint-clean | A1–A8, B1–B7, C1–C4/C6, D1/D4–D6, E/F PASS | C5; complete gate | Final independent review |
| 3 | 2026-10-04 | Fresh review found delayed completion and shared execution attribution; fixes seen red then green; reviewer PASS | B2/B6 regraded PASS; thresholds unchanged, temporal field data corrected | C5; complete gate | Full gate on frozen tree |
| 4 | 2026-10-04 | Final default suite completed; supplied missing validation record; owner stopped lint work | Documentation rechecked | C5; later full-gate phases | Funded evaluation and remaining gates |
