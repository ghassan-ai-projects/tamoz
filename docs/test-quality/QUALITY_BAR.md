# Test suite improvement — quality bar

**Task:** Review and improve every test · **Owner:** repository owner · **Size:** L
**Set:** 2026-10-04, before implementation · **Branch:** improve-the-tests
**Plan:** [README](README.md) · **Standards:** [TESTING_STANDARD](TESTING_STANDARD.md)
**Governing rules:** ADR-016, ADR-024, ADR-052, ADR-058, ADR-059; coding standard §9.

Statuses: PASS requires a current check; FAIL identifies a defect; OPEN means unfinished;
BLOCKED identifies an unavailable check and is never a pass. Only the owner can waive a row.

## Outcome and fence

Every test has a meaningful subject, runs in an explicit lane, uses consistent Minitest
assertions and fixtures, and protects an observable contract without redundant setup or
unnecessary elapsed time. Improve uncovered behavior without weakening existing properties.

Done means all rows pass, no critical/high review finding remains, and a final iteration
changes nothing. Review all three roots: `test/`, `gems/*/test/`, `agenteval/test/`.
Production contracts, benchmark wire names, pinned artifacts and authority policy remain
unchanged. Renaming a test must update its lane, weight and active references. A production
identifier containing a vendor or phase label is retained only where it selects the actual
subject or exact protocol bytes; descriptions and fixture identities use behavior names.
No paid model runs. Fixture results prove plumbing, never reasoning.

## Seam and baseline

Extend `Minitest::Test`, opt-in modules under `test/support/`, and the existing Rake lanes.
Do not introduce another test framework or a general fixture DSL. Minitest 6.0.6 is locked;
`minitest/mock` is absent, so do not assume the Minitest 5 mock API exists.
Enola snapshot and baseline pinned before implementation. Its helper impact map reports no
dependents; the Ruby require inventory is needed because that result is incomplete for tests.
Baseline outputs are kept under `/tmp/tamoz-test-baseline-*`; record results in the loop log.

## Safety and behavior

| ID | Property | Proof | Status |
| --- | --- | --- | --- |
| A1 | Effect, authority, denial, cancellation, crash/replay and immutable-receipt assertions survive | Before/after test inventory, focused regressions and independent diff review | OPEN |
| A2 | No weakened durability settings, skipped failures, real model calls or production interface changes | Diff review; full suite in both locales | OPEN |
| A3 | Helpers restore resources/global state even when the block raises | Helper failure-path tests and independent review | OPEN |
| B1 | All test roots are discovered exactly once; duplicate class/method definitions cannot silently overwrite tests | Discovery regression tests and suite audit | OPEN |
| B2 | Every deleted case has a named surviving behavioral proof | Deletion ledger in README; no deletion based on age, label or length alone | OPEN |
| B3 | New tests cover observed gaps and fail when the guarded behavior is removed | Record intentional mutation and failing test, restore and rerun | OPEN |
| B4 | Failures identify the case and relevant expected/actual values | Minitest assertion audit; seed checks | OPEN |

## Simplicity and speed

| ID | Property | Proof | Status |
| --- | --- | --- | --- |
| E1 | No exact duplicated substantial test bodies; repeated helper implementations share one owner | Syntax-tree audit across all roots; review near duplicates | OPEN |
| E2 | Test names/descriptions state behavior; phase/vendor labels are not organizational vocabulary | Whole-suite naming audit; document unavoidable protocol references | OPEN |
| E3 | Plain Ruby helpers have at least two consumers or an isolated resource lifetime | Consumer inventory; review | OPEN |
| E4 | Assertions use the specific Minitest form and expected-before-actual ordering | RuboCop Minitest cops across all roots; review | OPEN |
| E5 | Unit tests inject time/waits; concurrency waits observe a signal with a bounded deadline | Audit every sleep call, classify process fixtures, replace arbitrary delay | OPEN |
| E6 | No speculative helper hierarchy, nested fixture DSL or assertions of self-created constants | Review every changed file and whole-suite audit findings | OPEN |
| E7 | Measured same-lane runtime does not regress; startup and slow tail improvements have measurements | Before/after profile with equal workers and discovery; no speed claim from fewer cases | OPEN |

## Gates and records

| ID | Gate | Proof | Status |
| --- | --- | --- | --- |
| D1 | Touched files run individually with Ruby 3.3.11 | One file per command, names/counts in loop log | OPEN |
| D2 | Everyday gate | `bundle exec rake ci` | OPEN |
| D3 | Complete gate in both locales | `LANG=C LC_ALL=C bundle exec rake ci_full`; repeat in en_US.UTF-8 | OPEN |
| D4 | No new lint offense; test assertion cops pass across all test roots | Changed-file lint against HEAD and whole-suite Minitest scan | OPEN |
| D5 | No new architecture regression | Generate snapshot, diff baseline, enola check | OPEN |
| D6 | Line and branch coverage do not fall on the same measured subjects; report added coverage separately | Fresh SimpleCov baseline and final reports, no stale merged results | OPEN |
| F1 | Every file has an audit disposition; review/gaps are explicit | Per-file inventory under this folder | OPEN |
| F2 | Standards are linked from AGENTS.md and coding standard; active references and file modes are valid | Documentation gate, diff check and tracked file modes | OPEN |
| F3 | Independent reviewer before each commit; no open critical/high findings | Review log | OPEN |
| F4 | Final report states actual evidence and any blocked/open rows | Review report against outputs | OPEN |

## Review log

| Batch | Reviewer / findings | Resolution | Commit |
| --- | --- | --- | --- |
| Initial audit | Read-only suite auditor running | Pending | — |
| 1: helpers and assertion correctness | Independent suite auditor: no critical/high findings; all 15 existing files retain test methods | Corrected helper privacy and audit wording; mutation proofs recorded | Pending commit |
| 2: discovery and executable source checks | Independent helper author reviewed runner/source audit; no critical/high findings | Added duplicate literal generated-method regression; 15/29 identity checks and 6/10 predicate checks pass | Pending commit |
| 3: scheduling fixtures | Runner author reviewed five files: no critical/high findings; two medium findings | Bound result-queue reads and describe observed callback order precisely; intentional wrong output order fails | 72d02c62 |
| 4: shared fixtures, injected clock, tracker | Independent reviewer: PASS WITH FINDINGS — one medium (untested stale-record guard, fixed in batch), one low (graph-audit double-run byte check, open) | 15 files green individually; frozen-clock mutation fails with CheckpointConflictError; zero lint offenses on new files; reviews.json/TEST_TRACKER bootstrapped | 61f0d4f8 |
| 5: planning-vocabulary purge | Independent reviewer: PASS WITH FINDINGS — 2 high (guard blind to A-n codes and bare T-codes; half-renamed method), 3 medium, 4 low; all nine fixed in-batch, four thermal/deep-research WP-T survivors cleaned after widening the guard | Full suite 3095 runs green after fixes; per-cop lint counts none rising vs HEAD; detector clean over all 407 root/support files; guard widened and rescan forced the cleanup it exists for | 916ee726 |
| 6: waits audit | Independent reviewer: PASS WITH FINDINGS — 1 high (probe_source removal silenced a detection window, restored with truthful comment), 1 low-class note (graph_stream window restored too); all other checks answered with verified code reads | All 68 sleeps classified: 8 dead waits removed (each 3x-stress green or mutation-probed), 2 blind waits → bounded readiness polls, 1 fixture made deterministic (trap-then-ready-file), 6 kept with truthful comments, post-SIGKILL settles proved load-bearing by removal failure; full suite green; per-file lint ≤ HEAD except a documented rubocop self-inconsistency on one pre-existing line | Pending |

## Loop log

| Iteration | What changed | Checks / results | Still open | Next |
| --- | --- | --- | --- | --- |
| 0 | Research and baseline; no test edits | Ruby 3.3.11, Minitest 6.0.6; 349 test files; restricted ci failed on local socket permission | All implementation rows | Rerun with local socket access; inventory and bounded batches |
| 1 | Two shared helpers replace twelve implementations; five underchecked properties strengthened | Eleven consumer suites pass; driver retains detached HEAD error; helper 8/52; experience 17/74; observability 13/55; MCP 33/213; twelve mutation probes fail as intended | Complete gates, naming, waits, semantic review, coverage | Commit reviewed batch; repair discovery |
| 2 | Complete discovery, isolated grader/manual lanes, argument-vector execution, duplicate identities and ignored-predicate guards | Expanded fast lane: 318 files / nine workers pass; grader 16/94 and gem adapter 12/59 pass; inventory/syntax pass; four new files have zero lint offenses | Full-lane baseline fails on driver and competing coverage instrumentation; semantic review, naming and timing remain open | Commit reviewed runner; improve test bodies |
| 3 | Two consumers use a bounded condition-variable barrier; generated DAGs yield instead of sleeping; callback-order probe added | Pool 12/140, DAG 2/480, fanout 2/7, barrier 4/6 pass; five files lint clean; disabling barrier and reversing result order each fail | One fanout delay and other suite waits remain; no stable whole-suite speed result | Commit; continue deduplication and naming |
| 4 | Shared ScriptedGeneration (6 consumers), CommsCliFixture (2), ApprovalCase adopted by 3 suites; lease-expiry sleep replaced by injected clock; graph-audit children no longer inherit RUN_COVERAGE; per-file tracker (reviews.json → TEST_TRACKER) | 15 touched files pass individually; stale-record guard tested; lint zero on new files, none new vs HEAD; committed 61f0d4f8 | Naming sweep, remaining waits, dedup ledger, coverage | Batch 5 naming sweep |
| 5 | Deleted every planning-vocabulary comment (~2,000 lines / 172 files); renamed ~190 code-named test methods, 4 files+classes, 3 constants, one fixture; added TestSourceAudit.plan_vocabulary guard over all roots + support files; updated manifest generator ids and regenerated docs/requirements-manifest.json | Full suite green (3095 runs); detector reports zero; per-cop lint comparison vs HEAD shows no rise after restoring 34 swallowed pragmas; requirements manifest test 11/11 | Dead-citation § refs kept only where the artifact is production-generated; benchmark C1–C9 and m1/m2 milestone names kept deliberately | Batch 6 waits audit |
| 6 | Audited all 68 sleep sites. Removed 8 unjustified waits (work_loop ttl sleep dead — frozen-clock probe; smoke_corpus 1.1s; three 0.25s reopen hedges; two tiny hedges). Converted mcp_supervisor's two 0.3s waits to bounded stderr-readiness polls. Made the cli_telegram ignore-TERM child deterministic (trap-then-ready-file). Shrunk unattended-policy expiry wait 1.5s→0.3s with timeout 0.2s. Kept with truthful comments: poll-proportional and scenario-ordering waits; kill-matrix/crash-recovery post-SIGKILL settles proven load-bearing by removal failure. Restored two detection windows the reviewer caught (probe_source lock probe, graph_stream late-commit probe) | Touched files green 3x each where probed; full suite 3095 runs green; lint per-file ≤ HEAD (cli_telegram improved 4→0) | review-tasks note: rubocop -a must not run over TODO-excluded debt files (it force-migrates their style); one mirrored alignment offense in cancellation_visibility is a rubocop self-inconsistency proven by a cross-tree experiment | Batch 7 dedup + coverage |

**Known red at HEAD:** permitted `rake ci` passes all 309 fast files, then fails
`stream:proto:check` with `Errno::EBADARCH` for bundled x86_64 protoc. Detached
`/private/tmp/tamoz-test-quality-baseline` reproduces the SQLite scenario driver's
`request.redirect_ready` SQL error (13 runs / 19,342 assertions / one error). Neither
is waived. Baseline coverage/full-lane run is still in progress.

A repeated failure in the same row for three iterations goes to the owner. Do not lower
the bar to make the loop finish. Environmental refusal is a blocker, never a product failure.
