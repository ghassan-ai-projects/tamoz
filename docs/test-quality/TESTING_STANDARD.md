# Testing standard

This supplements [coding standard §9](../CODING_STANDARD.md#9-testing-minitest).
Use locked Minitest with plain Ruby; do not add a second framework or a fixture DSL.

## Shape and naming

One file owns a subject or a cohesive contract. Name the class after the subject and the
methods `test_<behavior>_<condition>`. Arrange inputs, invoke the behavior, then assert
its observable result. A scenario may have several assertions when they describe one
contract; do not split it into repeated expensive setups just to reduce assertion counts.

Use behavior names in files, classes, fixtures and descriptions. Remove rollout numbers,
historical task codes and unrelated product comparisons. Keep exact production constants,
CLI paths and wire values where they are the contract under test. Do not rename a public
interface as part of cleaning its tests. No narrative class headers or numbered sections.

The vocabulary rule is enforced mechanically: `TestSourceAudit.plan_vocabulary` fails the
suite when a test comment cites a plan row (`P8`, `DR-5`, `A-13b`, `T2`, `slice 4`,
`Phase 2`, `§`) or a review code. Kept deliberately: pinned benchmark scenario identities
(`C1`–`C9`), the production milestone names in `test/m2_evidence_test.rb`, production
artifact bytes and production error text (for example the kill-required message that
contains `Phase 2`). The detector reads Prism comments only, so pinned bytes inside
heredocs and string literals are out of its scope by design. Known false-positive
surface: a bare `F1`/`F2` code is banned while the hyphenated metric spelling
`macro-F1` is accepted, and `Q3`-style tokens are treated as review codes — spell out
"quarter" or use the hyphenated metric form in a behavioral comment.

## Assertions and coverage

Use `assert_equal expected, actual`, `assert_nil`, `assert_empty`, `assert_includes`,
`assert_predicate`, `assert_operator`, and their refutations. A broad truthiness assertion
loses useful diagnostics when a specific assertion exists. Use `fetch` for required
fixture fields. Check typed errors and relevant messages; never rescue an error into a pass.

Protect outcomes through the narrowest stable public seam. Exercise success, refusal,
boundary values and failure cleanup. A fake models only the collaborator's required
contract; it must reject unexpected calls where silence could hide an error. Assertions
against locally manufactured values or incidental private layout do not add coverage.
Architecture, protocol and public API guards are useful when they protect a stated rule.

Each added regression must fail under a targeted intentional mutation, then pass after
restoration. Compare both line and branch coverage using fresh resultsets over the same
production files. A larger test count or assertion count alone is not improved coverage.

## Helpers and resources

Prefer keyword arguments, blocks, `Data.define` for fixed values and small modules over
deep inheritance. Keep one-off data local. Extract an identical helper with two or more
real consumers; opt in explicitly with `include`. A helper's name exposes its subject.
Do not turn differing scenarios into a switch-filled generic factory.

Use small frozen case tables with `define_method` for genuinely identical contracts;
each case gets its own descriptive test name, setup and failure result. Keep large domain
catalogs in the existing domain JSON fixtures. Preserve distinct behavioral boundaries.

Use block-scoped temporary directories and `ensure` for adapters, processes and global
state. Cleanup executes on failure and must not replace the original exception. Restore
absent environment variables to absence. Avoid changing process-global state in threaded
tests. Minitest 6 has extracted mock/stub support; this repository does not install it.
Use existing injection seams and plain Ruby fakes instead of assuming `Object#stub`.

## Time, concurrency and processes

Inject clocks and sleepers for logical elapsed time. Coordinate threads with queues or
condition variables; observe readiness before assertions. No fixed sleep to guess when
another thread has run. A process fixture may deliberately block when blocking itself is
the behavior, but readiness must have a bounded deadline and teardown must reap children.
Keep actual crash, packaging and socket scenarios in the existing appropriate lane.
Preserve WAL and synchronous durability; never gain speed by weakening the tested setting.

## Running and reviewing

Use Ruby 3.3.11. Run one file per command, or use the repository runner which explicitly
requires all selected files. All test roots need discovery; every file belongs to one
lane and every runnable class/method pair is unique. A renamed test retains its lane and
weight. The full gate must include gem and evaluation suites as well as the root suite.

Run focused files after each change, changed-file lint with no new offenses, and review
the diff independently before a commit. Finish with everyday and complete gates, both
locales for this suite-wide change, fresh coverage and architecture checks. Profile the
same lane and workload before claiming speed. Record baseline failures without waiving
them. Never delete, skip or soften a useful test to obtain a green result.
