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

Current results and remaining gaps will be recorded here as batches finish. All model
providers used by tests are deterministic fixtures; this work makes no reasoning claim.
