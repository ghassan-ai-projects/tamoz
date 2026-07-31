# M3.1 phase 2E running-recovery correction

Review target: the `request.recover-running` fixed scenario and its public recovery
precondition.

Reviewed base: `50b30d8`.

Decision: accepted correction on 2026-07-31, subject to the recorded full gate. Phase 2F
remains stopped until this correction is committed independently.

## Finding

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | The fixed running-recovery scenario produced a `running` request with no checkpoint, so a later public `DurableRunner#recover` failed with `CheckpointConflictError: thread does not exist`. | The fixture used the standalone request-transition helper and its Phase 2E assertions checked request status, fence, and transitions without checking the checkpoint relation required by graph continuation. | Create the initial running checkpoint and request transition in one `checkpoint.commit`, assert their relation, and run a public recovery regression that preserves execution identity and completes the graph. |

The production recovery path is internally consistent. A recovered running turn enters
`Compiled#continue_with_writer`, which requires the latest compatible checkpoint to be
`running`. Real execution first commits that checkpoint together with the request's
`claimed`-to-`running` transition. The fixture had modeled only the latter state.

## Five Whys: impossible running recovery

1. Why did public recovery fail? `continue_with_writer` could not find a thread
   checkpoint.
2. Why was there no checkpoint? The scenario setup called
   `mark_request_running` directly after claiming the request.
3. Why was that setup accepted? Phase 2E proved the `request.recover` transaction branch,
   but its focused contract stopped at inbox status, execution id, owner fence, and
   transition count.
4. Why was that contract insufficient? A running request is executable protocol state,
   not an isolated row; it must reference the running checkpoint that continuation will
   consume.
5. Why correct the fixture instead of production recovery? Production already creates
   and requires the atomic relation. Weakening that requirement would turn impossible
   state into an accepted recovery path and conceal corruption.

## Correction

The setup now:

1. enqueues and claims one turn under lease fence 1;
2. derives the fixed initial graph state and frontier;
3. creates a `running` request transition for the claimed execution;
4. commits the sequence-0 running checkpoint and request transition atomically;
5. expires the old lease and acquires fence 2;
6. arms the evidence gate and invokes exactly one `request.recover` operation.

The subject operation, scenario registry, boundary coverage, state class, and transition
count do not change. The executable driver definition now explicitly binds the running
fixture policy and has the new digest
`sha256:69b4c24372261e423823f7090c500551d83204144244be1a7cee7bf0d332ea26`.

## Adversarial review

- A request row alone no longer satisfies the fixture test; the request must join through
  its checkpoint id to one running checkpoint.
- Request and checkpoint execution ids must be equal.
- The public regression expires the scenario's active lease, opens a fresh adapter,
  compiles the fixed graph independently, and calls `DurableRunner#recover`.
- Recovery must complete, preserve the original request execution id, append exactly one
  continuation checkpoint, produce the expected state, and pass SQLite integrity.
- The observer remains disarmed during checkpoint construction, so the scenario trace
  still contains only the selected `request.recover` operation.
- The fixed setup remains bounded by the existing one-request, one-task, and
  two-setup-checkpoint ceilings.

## Review conclusion

No production recovery change is warranted. The defect was confined to evaluation
fidelity, but it was release-blocking because Phase 2F convergence would otherwise test
an impossible state. The correction restores the invariant:

> Every fixed state advertised as publicly recoverable satisfies the production
> continuation preconditions before fault injection begins.

The correction makes no crash-atomicity, oracle, or complete Phase 2 claim.

## Gate evidence

Executed under rbenv Ruby 3.3.11:

- direct public-path reproduction before the correction failed with
  `CheckpointConflictError: thread does not exist`;
- corrected scenario driver: 12 tests, 17,578 assertions;
- boundary source audit, registry, recorder, selector control, scenario registry/driver,
  request inbox, crash recovery, dependency isolation, packaging, and public API:
  82 tests, 22,190 assertions;
- warning-enabled scenario driver passed;
- 10 fixed seeds: 120 tests, 175,780 assertions, including 240 real
  child-stop/parent-kill sentinels;
- syntax and `git diff --check` passed;
- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI against the Phase 2E correction worktree: 297 tests, 24,537 assertions,
  0 failures, 0 errors, 0 skips.

The unfinished Phase 2F oracle files were temporarily kept outside the global test
pattern for the final Phase 2E gate and then restored unchanged. They are not part of
this correction or its commit.
