# PR 67 review fixes — quality bar

**Task:** fix the owner's PR 67 review findings 1–5 and 7 · **Owner:** Ghassan · **Size:** M · **Set:** 2026-10-05 (before the change)
**Governing ADRs / invariants:** ADR-060 (loss is reported; read-only), ADR-052 (gem boundaries), invariants 59–61 · **Branch:** observability-self-diagnosis

## 0. Outcome and fence

**Outcome:** a diagnosis never silently under-reports — an unreadable database or health file marks the
report degraded instead of aborting or reading as zero, and no readable database at all is an error — the
agent side names no SQLite3 type, `SelfObservation` lives in `tamoz-agent`, detectors read as one named
filter, and `tamoz mcp` serves the observe tools.

**Not in scope:** a `tamoz-diagnosis` gem and moving the Markdown renderers (owner decision pending,
item 6); filtering diagnosis by workspace (owner declined, item 8); the pre-existing `::` suffix on
journal drop keys (separate task).

**Owner decisions:** item 5 move approved; item 7 `tamoz mcp` approved; no alias for `self-observe`
(ADR-059); ADR-060 condensed at the owner's request.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | `RecordReader.read_only_connection` (error mapping), `SelfObservation#loaded`/`#thread_database`, `Recorder::Journal#persist_health` + `Files.read_health`, `Diagnosis.degraded_reasons`, `Diagnosis::Detectors`, `SelfObserveServer` → `MCPServer` |
| 1.2 | Existing pieces reused | `ExceptionMapper.raise_mapped`, `Tamoz::Core::AtomicFile.replace`, `Report#degraded_reasons` |
| 1.3 | Blast radius | enola diff: no cycle; new edge tamoz-agent → observability/diagnosis (tamoz-agent already depends on tamoz-observability) |
| 1.4 | Baseline | enola baseline pinned 2026-10-05; nine diagnosis test files green at HEAD 89fa7a4a |

## A. Safety

| # | Property | Check | Status |
|---|---|---|---|
| A1 | `RecordReader.open` raises a Tamoz error, never a raw `SQLite3::` one, when SQLite cannot open the file | `sqlite_record_reader_test#test_a_database_sqlite_cannot_open_raises_a_tamoz_permission_error`, red with the mapping removed | PASS |
| A2 | An unreadable database is skipped and named in `degraded_reasons`; no readable database is an error | `self_observation_test` (4 cases), red without the skip and without the raise | PASS |
| A3 | An unreadable health file marks the report degraded, never reads as zero loss | `self_diagnosis_test#test_an_unreadable_health_file_marks_the_report_degraded` + `observability_runtime_test#test_journal_health_sums_drops_and_names_an_unreadable_health_file`, both red when their guard is removed | PASS |
| A4 | Health file written through `AtomicFile.replace`, mode 0600, no temp left behind | `observability_runtime_test` checks mode and no `.tmp`; atomicity itself is by construction (the test cannot tell it from `File.write`) | PASS (scope noted) |
| A5 | No actor and no `SQLite3::` constant on the reading side | `self_diagnosis_boundary_test` (66 assertions) | PASS |
| A6 | Secrets never reach outputs (invariant 60) | `self_diagnosis_boundary_test#test_a_secret_shaped_value_reaches_no_report_explanation_timeline_postmortem_or_tool_result` | PASS |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Detectors behave as before for the shipped rules | `self_diagnosis_test` 16, `self_diagnosis_corpus_test` 16, `diagnosis_rules_test` 6 green; each filter mutated and seen red (the `missing` filter needed the new `test_an_answered_approval_is_not_waiting`) | PASS |
| B2 | `tamoz mcp` serves `observe_diagnose`, `observe_timeline`, `observe_explain_turn` over stdio; `self-observe` is gone | `mcp_server_test` 7, including the subprocess stdio case | PASS |
| B3 | Docs, probes fixture, eval script and requirements manifest/audit name `tamoz mcp` | grep: no `self-observe` outside dated plan/run records; manifest + audit regenerated, only the renamed row moved | PASS |

## D. Gates

| # | Gate | Status |
|---|---|---|
| D1 | Touched test files green, one per command | PASS |
| D2 | `rubocop` on changed files adds no offense (stdin mode; HEAD counts equal) | PASS |
| D3 | `rake adr:validate adr:verify`, `enola check` PASS; enola diff: no cycle, one dead-method candidate is the renamed `cmd_mcp`, dispatched through `SUBCOMMAND_HANDLERS` | PASS |
| D4 | `rake ci`: design, ADR, syntax, 318 test files, `quality:architecture` pass; `stream:proto:check` BLOCKED — `grpc-tools` ships an x86_64 `protoc` that cannot exec on this Apple Silicon host (recorded in 8777a9c7) | PASS except BLOCKED step |

## E/F. Simplicity, honesty

| # | Row | Status |
|---|---|---|
| E1 | No new class beyond the rename; no alias; one comment (why `MCPServer` autoloads) | PASS |
| F1 | ADR-060, evidence.md, CHANGELOG, guides updated in the same change | PASS |

## Review log

| Reviewer | Findings | Disposition |
|---|---|---|
| Fresh subagent (correctness+soundness, architecture+simplicity) | 0 critical, 0 high. M1 no readable DB returned an empty "healthy" report; M2 reader test could not fail; M3 health-file degraded reason untested; M4 ADR-060 condensed beyond the rename; L1 `fdiv` NaN with `min_count: 0`; L2 rescue broader than needed; L3 wrong-shape health JSON aborts (pre-existing); L4 A4 cannot prove atomicity; L5 bar stale; L6 `Journal.health` name clash | M1 fixed (error); M2 mode-000 test added, unfailable test removed; M3 test added; M4 owner-requested, raised in the report; L1 restored HEAD comparison; L2 narrowed; L3 not fixed (rare case, pre-existing); L4 scope noted in A4; L5 this update; L6 renamed `read_health` |

## Loop log

| Iteration | Changed | Rows still FAIL/OPEN |
|---|---|---|
| 1 | Items 1–5, 7 implemented; mutation checks | none (review pending) |
| 2 | Review M1–M3, L1, L2, L4–L6 | none |
