# Test suite review and improvement

Start with the [quality bar](QUALITY_BAR.md), [testing standard](TESTING_STANDARD.md), and
[library research](RESEARCH.md). The audit covers root, gem and evaluation tests.

## Plan

1. Identify the installed library, current runner, test roots, coverage and baseline failures.
2. Audit discovery, duplicate test identities, assertion quality, helper duplication,
   resources, waits, behavior naming and uncovered branches across every test file.
3. Repair discovery and test identity first. Extract proven shared helper implementations.
4. Refactor disjoint subject batches. Keep behavioral cases; remove only proved redundancy.
5. Replace arbitrary waits with deterministic signals or injected clocks at existing seams.
6. Run focused checks, independent review and commit each accepted batch.
7. Run whole-suite assertion audit, both-locale complete gates and fresh coverage comparison.
8. Re-grade all rows; continue until a verification-only iteration passes.

## Initial findings

- `Gemfile.lock` pins Minitest 6.0.6, RuboCop Minitest 0.40.0 and SimpleCov 0.22.0.
- 341 root files contain 86,468 lines and 3,313 literal test method definitions;
  seven gem test files and one evaluation grader file are outside default discovery.
- Root and gem durable CLI adapter suites share a class name, though their current
  methods do not overlap. Give each suite its own identity before expanding discovery.
- `test/test_helper.rb` eagerly loads ten corpus/benchmark/support files for every test.
- Seven suites repeat the same `plan_for`; five repeat `assert_deeply_frozen`.
- Initial syntax-tree comparison found no exact duplicated test body of at least five lines.
  Absence of exact duplicates does not prove absence of redundant behavioral coverage.
- The restricted baseline cannot bind loopback fixture listeners. A permitted baseline
  is running to distinguish environmental refusal from existing failures.

## Deletion ledger

No behavioral test deleted yet. Each deletion must name the contract, the surviving
test and why the deleted case adds no distinct input, failure mode or boundary.

## Evidence

Round one committed as `945a05a1`. It removed repeated plans and recursive assertions
from twelve files. Eleven consumer suites passed; the SQLite scenario driver retains
the detached HEAD `request.redirect_ready` SQL error. Missing cancellation/journal rows,
incorrect check status, wrong attribution and incorrect event occurrence are now detected.

Round two expands discovery to all roots and adds identity and assertion-block checks.
All 318 fast files pass across nine workers. The grader runs separately because its
`ROOT` conflicts with the shared helper. Manual real-model evidence is excluded from
automated gates. Static identity checks include `def` and literal `define_method` names;
computed names still need case-table review.

The detached baseline executed 3,008 main tests (29,659 assertions, five skips) and
287 slow tests (27,630 assertions, two failures and one error). The slow failures expose
competing SimpleCov and raw Coverage instrumentation in graph-audit children; the error
is the known SQLite scenario. These failed runs do not establish complete coverage.
The existing protocol compiler also fails with `Errno::EBADARCH` on this Mac.

All normal test providers are deterministic fixtures; this work makes no reasoning claim.

Round three preserves all 120 generated DAGs and their independent model while replacing
synthetic delays with scheduling yields. A bounded barrier proves concurrent participation
in pool and subgraph tests. A separate probe records reverse callback completion and verifies
ordered public results; it does not claim to control the pool's internal publication order.
Missing participants and wrong result order produce failures. One-sample pool/DAG runtimes
were 0.646/1.966 seconds at HEAD and 0.629/1.737 afterwards; those are directional samples,
not a stable whole-suite performance comparison.
