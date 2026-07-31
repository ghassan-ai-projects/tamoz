# M3.1 phase 2E pending-write routing correction

Review target: the persisted outcome used by `checkpoint.writes-new` and
`checkpoint.writes-duplicate`.

Reviewed base: `6a85d25`.

Decision: accepted correction on 2026-07-31, subject to the recorded full gate. Phase 2F
remains stopped until this correction is committed independently.

## Finding

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | The pending-write fixture stored a dynamic `goto` for a statically routed node. Raw persistence was internally digest-consistent, but public continuation rejected it with `InvalidUpdateError: static node work returned dynamic routing`. | The synthetic outcome copied the graph's terminal destination into `Outcome#goto`, conflating a declared static edge with a node-returned dynamic route. Phase 2E checked row atomicity and digest relations but did not continue the persisted outcome through the graph planner. | Persist `goto: nil`, retain the declared `work -> END` edge as the sole routing authority, and add a public continuation regression whose node raises if it is reexecuted. |

The production executor creates `goto: nil` when a static node returns only a state
update. During continuation, the route planner applies the graph's declared static edge.
The corrected fixture now represents that production outcome exactly.

## Five Whys: unrecoverable pending outcome

1. Why did continuation fail? The route planner saw a nonempty dynamic route on a static
   node.
2. Why was the dynamic route present? The fixture encoded `Tamoz::END` in
   `Outcome#goto`.
3. Why did that look reasonable? The graph also declares `work -> END`, and the fixture
   confused the effective next route with the source of routing authority.
4. Why did Phase 2E not reject it? Tests proved atomic pending rows, ordering,
   idempotency, and digest validity, but stopped before the executor consumed the stored
   outcome.
5. Why is a continuation regression required? Only the graph planner can prove that the
   persisted outcome is semantically replayable without executing the completed node
   again.

## Correction

- The synthetic successful outcome retains the task, attempt, base checkpoint, node,
  path, and normalized update, but sets `goto: nil`.
- The graph's reviewed static `work -> END` edge remains unchanged.
- The driver definition binds
  `pending_outcome_routing: static-edge-without-dynamic-goto`.
- The corrected driver digest is
  `sha256:25afc66329481cfa7abaff6aec9d32ebaf8b621eec1cb2f7ebf82dfe9d0bac5d`.
- The scenario ids, registry digest, branch traces, state classes, row counts, and
  selector coverage do not change.

## Adversarial regression

The regression builds `checkpoint.writes-new`, expires only the test copy's active
lease, opens a fresh adapter, and compiles the exact fixture graph with a node body that
raises unconditionally. It submits a durable `continue` request and requires:

- the request completes;
- history advances from one checkpoint to two;
- the persisted update produces `value == 1`;
- SQLite integrity remains valid;
- the raising node body is never called.

This distinguishes replay of the durable outcome from accidental node reexecution.

## Review conclusion

No production route-planner or recovery change is warranted. Production correctly
rejected an impossible outcome. The defect was confined to evaluation fidelity but was
release-blocking because a digest-valid yet unrecoverable fixture cannot support the
Phase 2F pending-write convergence claim.

The correction makes no oracle, crash-atomicity, or complete Phase 2 claim.

## Gate evidence

Executed under rbenv Ruby 3.3.11:

- pre-correction public continuation failed with
  `InvalidUpdateError: static node work returned dynamic routing`;
- corrected scenario driver: 13 tests, 17,586 assertions;
- boundary source audit, registry, recorder, selector control, scenario registry/driver,
  request inbox, crash recovery, dependency isolation, packaging, and public API:
  83 tests, 22,198 assertions;
- warning-enabled scenario driver passed;
- 10 fixed seeds: 130 tests, 175,860 assertions, including 240 real
  child-stop/parent-kill sentinels;
- syntax and `git diff --check` passed;
- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI against the Phase 2E correction worktree: 298 tests, 24,547 assertions,
  0 failures, 0 errors, 0 skips.

The unfinished Phase 2F oracle and convergence files were temporarily kept outside the
global test pattern for the final Phase 2E gate and then restored unchanged. The
Phase 2F require entry was likewise removed and restored. None is part of this
correction or its commit.
