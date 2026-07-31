# M3.1 phase 2E plan correction

Review target: [M3_1_PHASE2_PLAN.md](../M3_1_PHASE2_PLAN.md)

Reviewed base: `7ca44b9`

Decision: accepted correction; Phase 2E implementation remains stopped until this
correction passes full CI and is committed independently.

## Finding

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | The fixed scenario matrix could not reach `request.claim.active_execution`, so its trace union could never cover every Phase 2 `kill_required` registry entry. | The review checked operation coverage but did not require a statement-to-scenario witness for every conditional branch. | Add the fixed `request.claim-resume` scenario and make the exact statement-to-scenario witness map a Phase 2E acceptance gate. |

`CheckpointStore#claim_next_request` chooses the execution binding through two mutually
exclusive branches:

- `turn`, `fork`, and `redirect` generate a new execution id and do not execute
  `request.claim.active_execution`;
- `resume` and `retry_failed` read the active execution through
  `request.claim.active_execution`;
- `redirect` alone executes `request.claim.redirect_target` and
  `request.claim.cancellation_generation`.

The accepted matrix had `request.claim-turn` and `request.claim-redirect`, but no
`resume` or `retry_failed` witness. All existing claim scenarios could pass while the
runtime trace union remained incomplete.

## Five Whys: missing claim branch witness

1. Why could the planned trace union not cover the registry? No fixed scenario executed
   `request.claim.active_execution`.
2. Why did the claim scenarios miss it? Both `turn` and `redirect` take branches that bind
   generated execution ids.
3. Why was this not rejected during plan review? The scenario matrix demonstrated
   operation coverage, not reachability of every registered statement.
4. Why was operation coverage insufficient? One operation contains mutually exclusive
   statement paths, and source/registry agreement does not prove that fixtures reach each
   path.
5. Why add a fixed witness rather than weaken the registry? The statement is a real
   durability boundary. A bounded `resume` fixture reaches it and tests the distinct
   invariant that a queued request retains the active execution identity.

## Corrected witness map

The conditional Phase 2 statement paths now have explicit witnesses:

| Operation | Conditional statement or template | Fixed witness |
|---|---|---|
| `request.enqueue` | existing-row idempotency path | `request.enqueue-duplicate` |
| `request.claim` | generated execution path | `request.claim-turn` |
| `request.claim` | `request.claim.active_execution` | `request.claim-resume` |
| `request.claim` | redirect target and cancellation generation | `request.claim-redirect` |
| `request.recover` | claimed, running, and redirecting state preservation | the three `request.recover-*` scenarios |
| `request.transition` | claimed and redirecting running branches | `request.mark-running`, `request.mark-redirect-running` |
| `checkpoint.append_writes` | activation/new-write and duplicate verification paths | `checkpoint.writes-new`, `checkpoint.writes-duplicate` |
| `checkpoint.commit` | start, pending consumption, request transition, fork, pause, and failure branches | the six `checkpoint.commit-*` scenarios |

The unconditional lease paths retain their five existing fixed witnesses. Source review
found no other Phase 2 `kill_required` statement that lacks a planned witness.

## Added scenario contract

`request.claim-resume` has a versioned, bounded fixture:

- setup creates one active execution and one queued `resume` request for the same address;
- the recorder remains disarmed throughout setup;
- the action arms the recorder and directly invokes exactly one
  `request.claim` persistence operation;
- the old contract requires the queued request and active execution;
- the new contract requires `claimed`, the same active execution id, the current owner
  fence, and exactly one queued-to-claimed transition;
- the trace must include `request.claim.active_execution`;
- convergence must preserve the claimed request/execution binding.

The correction increases the fixed matrix from 23 to 24 scenarios, below the reviewed
ceiling of 32. It adds no dynamic fixture, selector, retry, or oracle behavior.

## Acceptance gates

Before Phase 2E can be accepted:

- every source-audited Phase 2 `kill_required` statement or bounded template has at least
  one named fixed scenario witness;
- the observed trace union equals the required registry set exactly;
- `request.claim-resume` proves active-execution identity independently of production
  materialization;
- removing or changing its branch fixture fails the coverage gate;
- all deterministic tests and full CI pass.

This correction changes design coverage only. It makes no crash-safety, scenario-driver,
or M3.1 completion claim.
