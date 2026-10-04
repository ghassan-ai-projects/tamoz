# Branch test review — follow-up quality bar

**Task:** Finish the review of `improve-the-tests` · **Size:** L · **Set:** 2026-10-04 before edits.
**Owner:** repository owner · **Standards:** [testing standard](TESTING_STANDARD.md).
**Prior evidence:** [original bar](QUALITY_BAR.md), which this follow-up re-verifies.

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
| A1 | No weakened safety, durability, boundary or refusal assertion | Branch and round diff review; test inventory | OPEN |
| A2 | Fixtures clean up and concurrency assertions use bounded signals | Helper failure paths and concurrency review | OPEN |
| B1 | SQLite snapshot compares all rows without assuming rowid | Driver: 14 runs / 38,425 assertions; rowid mutation errors on WITHOUT ROWID table; restored suite passes | PASS |
| B2 | Runner and source guards discriminate observed gaps | Focused suites plus targeted mutation proof | OPEN |
| D1 | Touched test files pass separately; changed files add no lint offenses | Ruby 3.3.11 one file per invocation; baseline lint comparison | OPEN |
| D2 | Everyday and both-locale complete gates | `bundle exec rake ci`; `LANG=C/en_US.UTF-8 bundle exec rake ci_full` | OPEN |
| D3 | Fresh line and branch coverage compared over identical production files | Separate fresh baseline/final resultsets; ratchet | OPEN |
| D4 | No new architectural regression | Enola snapshot diff; architecture gate | OPEN |
| E1 | Simple helpers and meaningful public outcomes; no speculative machinery | Local diff review before every commit | OPEN |
| E2 | No test deletion, new skip, compatibility code or scratch artifact | Diff, inventory, modes, status | OPEN |
| F1 | Every discovered file has a truthful completed review disposition | Review ledger and generated tracker | OPEN |
| F2 | Reports distinguish current proof, historical proof and blockers | Re-grade original report; final unchanged iteration | OPEN |

## Review and loop log

| Round | Findings and changes | Checks | Commit |
| --- | --- | --- | --- |
| 0 | Baseline driver test fails because its snapshot helper assumes rowid; bundled protoc cannot execute on this CPU | Focused driver: one error; detached baseline reproduces both errors | — |
| 1 | Sort snapshots by every projected column; retain duplicate/empty rows and detect a changed value. Withdraw unsupported FTS corruption diagnosis. Local diff review: no weakened assertions, production edits or open critical/high findings. | Driver 14/38,425 green; mutation red; changed-file lint clean; diff check clean | 41aeb93f |

| 2 | Share seven repeating model classes, two strict queued models, profile-session setup, recovery setup and edit plans. Preserve each provider's exhaustion semantics. Local review: every existing test method retained; new helper methods remain below 20 lines; no critical/high findings. | Twelve consumer suites pass individually; helper 10/24; aliasing and repeated-response mutations fail; new helpers lint clean; no changed-file cop increase vs detached baseline | This round |

## Known red at baseline

The bundled grpc-tools compiler is x86_64 and cannot execute on this arm64 machine.
Reproduce against the detached baseline before grading full gates. No waiver granted.
