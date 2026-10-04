# Branch test review — follow-up quality bar

**Task:** Finish the review of `improve-the-tests` · **Size:** L · **Set:** 2026-10-04 before edits.
**Owner:** repository owner · **Standards:** [testing standard](TESTING_STANDARD.md).
**Prior evidence:** [original bar](QUALITY_BAR.md), which this follow-up re-verifies.

**Later CI finding:** Linux CI exposed a developer-home manifest dependency missed
by this review. The local macOS full-suite results below do not prove Linux portability.
The correction and current evidence are in [CI_PORTABILITY_BAR.md](CI_PORTABILITY_BAR.md).

## Outcome and fence

Finish every pending file disposition; repair observed test defects without deleting,
skipping or weakening behavioral cases. Commit each validated round and push the branch.
No subagents, as explicitly requested by the owner: review each diff locally before committing.
Fixture and offline results prove plumbing only. Production contracts and policy stay unchanged.
Known-red environmental gates remain blockers, never passes.

## Seam and baseline

Extend the existing test helpers, source audits and Rake lanes. Baseline: `01a5674c`,
detached at `/tmp/tamoz-tests-review-baseline`. Enola snapshot/baseline pinned this run;
TestSuite impact: seven dependents within two hops. Read subjects end to end before edits.

## Checks

| ID | Property | Check | Status |
| --- | --- | --- | --- |
| A1 | No weakened safety, durability, boundary or refusal assertion | Existing behavioral identities retained; same API/scorecard/change-evaluation assertion counts; both-locale full lanes green; provider identities restored in round seven | PASS |
| A2 | Fixtures clean up and concurrency assertions use bounded signals | Helper failure-path tests pass; caller cleanup joins and bounded readiness signals reviewed; retained real-process cases listed below | PASS |
| B1 | SQLite snapshot compares all rows without assuming rowid | Driver: 14 runs / 38,425 assertions; rowid mutation errors on WITHOUT ROWID table; restored suite passes | PASS |
| B2 | Runner and source guards discriminate observed gaps | Source, seed, visibility, provider identity and exception-cause mutations fail; restored focused suites pass | PASS |
| D1 | Touched test files pass separately; changed files add no lint offenses | Focused consumers pass separately; final comparison covers 65 changed Ruby files with zero cop/file increases vs baseline | PASS |
| D2 | Everyday and both-locale complete gates | Everyday tests pass; C and UTF-8 full lanes each: 3,408 runs / 82,493 assertions / 0 failures / 0 errors / 4 existing skips. All three gates stop at baseline Errno::EBADARCH | BLOCKED |
| D3 | Fresh line and branch coverage compared over identical production files | Bundler + SEED=1; same 737 production files, 47,032 lines and 15,566 branch leaves. Line 89.97% → 89.98%; branch 71.58% → 71.60% | PASS |
| D4 | No new architectural regression | Fresh final snapshot: zero introduced findings; bundle exec rake quality:architecture passes | PASS |
| E1 | Simple helpers and meaningful public outcomes; no speculative machinery | Every round reviewed locally; exact duplicate helpers of eight or more lines eliminated; cohesive scenarios retained; no production gem changes | PASS |
| E2 | No test deletion, new skip, compatibility code or scratch artifact | No existing behavioral test removed or new skip; only a never-runnable private helper lost the test prefix; new file modes 0644; no scratch files staged | PASS |
| F1 | Every discovered file has a truthful completed review disposition | 355 dispositions: 216 done / 139 fine; source-review limits explicit; generated inventory and its 4/9 regressions pass | PASS |
| F2 | Reports distinguish current proof, historical proof and blockers | Historical report distinguished from this run; compiler never graded PASS; final iteration changes verification records only | PASS |

## Review and loop log

| Round | Findings and changes | Checks | Commit |
| --- | --- | --- | --- |
| 0 | Baseline driver test fails because its snapshot helper assumes rowid; bundled protoc cannot execute on this CPU | Focused driver: one error; detached baseline reproduces both errors | — |
| 1 | Sort snapshots by every projected column; retain duplicate/empty rows and detect a changed value. Withdraw unsupported FTS corruption diagnosis. Local diff review: no weakened assertions, production edits or open critical/high findings. | Driver 14/38,425 green; mutation red; changed-file lint clean; diff check clean | 41aeb93f |
| 2 | Share seven repeating model classes, two strict queued models, profile-session setup, recovery setup and edit plans. Preserve each provider's exhaustion semantics. Local review: every existing test method retained; new helper methods remain below 20 lines; no critical/high findings. | Twelve consumer suites pass individually; helper 10/24; aliasing and repeated-response mutations fail; new helpers lint clean; no changed-file cop increase vs detached baseline | 862a7b61 |
| 3 | Share nine subject-specific storage/transport helpers across 22 suites. Replace the MCP guessed delay with a bounded signal from the real SDK client; retain real timeout/restart assertions and join its caller during cleanup. Local diff review: no test removed or softened; every new helper method meets the configured 20-line bar. | All 22 suites pass separately; final MCP 33/214; no changed-file lint increase across 31 Ruby files; diff/syntax checks pass | 9308f0df |
| 4 | Include application/nested script sources in syntax discovery; use the locked Minitest SEED variable through one shared coverage environment; reject private/protected runnable tests. Rename one private source-list helper using the reserved test prefix. Repair the stale requirements evidence reference and regenerate its manifest. Local review: no existing behavioral assertions removed. | Fast lane: all 321 files pass; runner 18/42; manifest 11/3,266; skills boundary 6/42; source/seed/visibility mutations each fail; no changed-file lint increases | c4650805 |
| 5 | Share remaining duplicate CLI, source-audit, websearch and checkpoint setup. Extract named scorecard/change-evaluation assertions and preserve independently stored API/aggregate expectations. Local review: scenarios, callbacks, retry policy and existing assertions retained; no production edits. | All affected consumers pass individually. API 3/1,176, scorecard 6/215 and change evaluation 2/30 match baseline counts. Expected-value and event-filter mutations fail; 16 changed Ruby files have no cop increase; Enola reports zero new findings. | 73c42938 |
| 6 | Complete the remaining per-file source dispositions with explicit limits on behavioral proof; correct tracker wording so local review is not called independent review. Existing real-process timing and source-audit rescue concerns are recorded separately. | Inventory 355 rows: 215 done / 140 fine; inventory regressions 4/9; generator lint adds no offense; local diff review and diff check pass. | dc3cc394 |
| 7 | Final behavior review found that the runtime uses model.class.name as fallback effect identity. Replace shared-class aliases with thin named subclasses, preserving every original provider name as well as queue behavior. Local review confirms both runtime/worker identity seams; no production change. | All nine consumer suites pass separately; helper 11/25; alias mutation fails the new identity regression; ten Ruby files add no cop offenses; existing test names retained. | fd50788c |
| 8 | Same-environment coverage review found generic SQL/busy error paths had only incidental evidence from the broken baseline snapshot. Add explicit transaction failure regressions for typed cause, message, schema rollback and connection return; use the existing fault-injection seam with zero retries for busy refusal. No existing scenario changed. | Kernel 10/74 passes; removing exception causes fails both new regressions; restored 2/9 passes; local review confirms cleanup and unchanged production code. | 0f1d5f87 |

## Known red at baseline

The bundled grpc-tools compiler is x86_64 and cannot execute on this arm64 machine.
Reproduce against the detached baseline before grading full gates. No waiver granted.

Fresh baseline execution also exposed stale renamed evidence in the requirements manifest;
round four repaired the generator/reference together. The controlled baseline uses Bundler
and SEED=1, matching the final launch environment: 737 production files, 47,032 executable
lines and 15,566 branch leaves; 89.97% line / 71.58% branch. Earlier direct-Ruby results
were not comparable because Bundler preloads version files before coverage starts. The
baseline retains the two observed test errors; it is not a fully green baseline.

The proposed injected MCP concurrency failure was rejected during owner review because
it changed the live-server evidence and retry policy. It was reverted before this commit;
the real server, 0.5-second deadline and retry budget of one remain unchanged.

## Scope and retained evidence

The remaining 161 file dispositions now distinguish source review from complete
behavioral proof. Of these, 139 have identical executable token streams to the
pre-branch revision; 22 changed files were checked against their original scenarios
and shared helpers. Source guards found no ignored assertion predicates or banned
comment vocabulary. No exact duplicate helper of eight or more lines remains.
Long cohesive scenarios were retained rather than split to satisfy a line count.

Existing waits retained after review: the external timeout child in
`test/agent_repair_evaluation_test.rb:222`; SQLite crash/lease evidence in
`test/sqlite_crash_recovery_test.rb:28,82,121`; fan-out completion in
`test/graph_subgraph_fanout_test.rb:56`; drain readiness polling in
`test/concurrency_drain_test.rb:196`. These are not claimed to have mocked clocks.
The SQLite adapter has no public lease-clock injection seam. Changing that facade
or replacing real crash evidence is outside behavior-preserving test refactoring.

`test/support/source_boundary_audit.rb:12` preserves the existing ArgumentError
rescue in both original source audits. Failing closed on unreadable source would
change their behavior; it remains a separately recorded testing-standard concern.

Review is local throughout this follow-up, as the owner explicitly prohibited
subagents. Historical independent reviews remain historical evidence only.


## Final verification

Branch refactoring and review dispositions are complete. The complete quality bar
remains BLOCKED on D2: grpc-tools 1.83.0 selects its x86_64-macos compiler on this
arm64 host. The detached baseline reproduces the same failure. No compiler, protocol,
production contract or policy was changed to obtain a green gate. No waiver is claimed.

Both locales ran every automated lane. The separate manual real-model lane was not
run; all results here are offline plumbing evidence. No speed improvement is claimed.
Fresh coverage from the UTF-8 full run satisfies the committed ratchet and the
same-environment comparison; see [verification.json](verification.json).

The final review found no remaining critical/high finding in the branch diff.
The final iteration changed only evidence and grades; it required no implementation
change. Existing real-process waits and the source-audit rescue listed above remain documented
limits, not silently altered tests.
