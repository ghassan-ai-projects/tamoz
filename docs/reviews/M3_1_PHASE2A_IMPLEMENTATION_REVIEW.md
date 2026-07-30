# M3.1 phase 2A implementation review

Review target: boundary registry, Ripper source audit, and hook metadata v1.

Base revision: `dbd637f`.

Decision: accepted for commit on 2026-07-30. No unresolved correctness, security,
reliability, or maintainability finding remains in this slice.

This decision accepts Phase 2A only. It does not claim runtime trace reachability,
selector replay, process-kill evidence, crash atomicity, recovery convergence, or Phase 2
completion.

## Scope reviewed

- the internal, versioned SQLite durable-boundary registry;
- operation ownership, statement access, dynamic templates, and expansion ceilings;
- nullable read attempts and positive transactional attempts on every SQL hook;
- fixed-shape, deeply frozen hook metadata;
- the Ripper audit of `checkpoint_store.rb` and `lease_operations.rb`;
- helper-call label propagation and reviewed dynamic-index normalization;
- source/registry comparison in both directions;
- fail-closed handling of unbounded labels, unreachable helpers, direct database access,
  filesystem access, dynamic dispatch, and dynamic execution;
- compatibility with migration, kernel, checkpoint, request, lease, packaging, and existing
  fault-injector behavior;
- the amended per-slice review and commit discipline.

The source audit resolves 18 operations and 91 statement boundaries. Its result is a
canonical, deeply frozen operation-to-label/access model. It does not run on production
calls and is not loaded by the normal `tamoz/sqlite` entry point.

## Review method

The review compared four independently obtained views:

1. the accepted Phase 2 design and ownership table;
2. the handwritten registry;
3. a Ripper-derived source model with bounded helper-call propagation;
4. real hook events from write transactions and read operations.

The adversarial pass then attempted to bypass the audit with command-form calls, missing
blocks, missing or dynamic operation names, mixed metadata key types, arbitrary
interpolation, dead transaction helpers, keyword-carried transaction objects, database
aliases, direct execute calls, filesystem aliases, dynamic dispatch, and `eval`.

## Findings resolved

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | The first implementation had a registry but no independent source audit. | Registry construction was started before the complete Phase 2A gate was applied. | Add a Ripper audit and require exact source/registry agreement before acceptance. |
| High | A literal-only AST walk could miss labels reached through transaction helpers. | Statement extraction and bounded data-flow were treated as the same problem. | Resolve required and keyword transaction parameters through reviewed helper calls; reject unreachable or recursive transaction helpers. |
| High | Command syntax, aliases, dynamic dispatch, or dynamic operation names could bypass a narrow call matcher. | Only the current source spelling was initially modeled. | Parse parenthesized and command calls, normalize only literal dispatch, reject dynamic execution, and fail closed on missing/nonliteral operation declarations. |
| High | Direct database or filesystem use through an assigned constant could evade receiver-only checks. | Only the final method receiver was inspected. | Reject `SQLite3::Database` and filesystem capability constants anywhere in the audited AST. |
| Medium | Sorting arbitrary metadata keys could raise `ArgumentError` instead of the contract error. | Exact-shape validation assumed homogeneous String keys. | Validate length and required String-key membership without sorting attacker-controlled keys. |
| Medium | Hook metadata froze some caller-owned strings directly. | Internal literal call sites hid an ownership ambiguity. | Copy and freeze kind, operation, and statement strings before emission. |
| Medium | The first digest-stability test compared a memoized value with itself. | Runtime consistency was mistaken for contract stability. | Pin the exact registry digest so any boundary change requires an intentional versioned review. |
| Medium | The first syntax check used macOS Ruby 2.6 and produced a false compatibility signal. | The review command bypassed the repository's pinned toolchain. | Run every authoritative gate through rbenv Ruby 3.3.11, matching `.ruby-version`. |
| Process | The accepted plan required one final Phase 2 commit, contrary to the user's per-slice gate. | The implementation discipline changed after plan acceptance. | Amend the plan: every slice receives deep review, full CI, a review record, and its own commit; Phase 2 still ends with a cross-slice review. |

## Five Whys: source completeness

1. Why is a runtime trace insufficient? Missing instrumentation produces no event.
2. Why is a handwritten registry insufficient? It can omit the same boundary as the
   tests.
3. Why is a text search insufficient? Ruby call syntax, helpers, and interpolation have
   multiple equivalent spellings.
4. Why is a generic AST walk insufficient? Labels can cross bounded helper parameters, and
   an unvisited helper can hide a statement.
5. Why use a small fail-closed source interpreter? It accepts only the transaction,
   statement, helper, and interpolation forms this capability package intentionally uses,
   then requires exact equality with the reviewed registry.

## Gate evidence

Focused gates:

- source-audit tests: 7 runs, 55 assertions;
- registry/hook tests: 5 runs, 1,328 assertions;
- SQLite kernel regression: 6 runs, 20 assertions;
- syntax checks passed for the registry, hook factory, source audit, and tests;
- `git diff --check` passed.

Full gate under rbenv Ruby 3.3.11:

- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI: 237 runs, 3,902 assertions, 0 failures, 0 errors, 0 skips;
- syntax, packaging, public API, M0-M2 conformance, and all SQLite regressions passed.

The first full-gate attempt inside the outer workspace sandbox reached the test suite but
could not nest the M1/M2 network sandbox (`sandbox_apply: Operation not permitted`). The
same exact command passed outside that outer restriction. This was classified as harness
infrastructure, not a product pass or failure.

## Residual limits

- The static audit covers only the two Phase 2 capability files. Effects, Store, migration,
  backup, deletion, and their file boundaries remain assigned to later phases.
- Static source equality does not prove scenario reachability. Phase 2B must compare
  registry entries with bounded runtime traces.
- Phase 2 records successful first attempts only. Real busy/locked retry evidence remains
  Phase 5 work even though hook metadata can represent later attempts.
- Local evidence covers Ruby 3.3.11. The supported Ruby 3.4 and 4.0 revisions remain CI
  matrix gates.
- The Ripper audit intentionally rejects new syntax forms until they receive a review and
  an explicit bounded interpretation.

## Acceptance checklist

- [x] Registry is internal, versioned, deterministic, and deeply frozen.
- [x] Deferred ownership is visible without a Phase 2 kill claim.
- [x] Source and registry omissions fail in both directions.
- [x] Dynamic statement labels are limited to the two reviewed index templates.
- [x] Helper-derived lease labels resolve to enumerated call-site values.
- [x] Statement hooks carry their transaction attempt.
- [x] Read hooks carry a nullable attempt.
- [x] Hook metadata has fixed keys, bounded values, and immutable owned strings.
- [x] Production SQL behavior is unchanged.
- [x] Focused and full regression gates pass.
- [x] No Phase 2B work is mixed into this commit.
