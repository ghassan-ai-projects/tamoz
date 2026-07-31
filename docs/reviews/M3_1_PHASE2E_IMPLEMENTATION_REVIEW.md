# M3.1 phase 2E implementation review

Review target: fixed SQLite scenario registry, isolated setup/action runtime, trace-union
verification, and real-process sentinel integration.

Base revision: `f7829e8`.

Decision: accepted for commit on 2026-07-31. No unresolved correctness, security,
reliability, or maintainability finding remains in this slice.

Post-acceptance correction: the original `request.recover-running` setup created a
running inbox row without the running checkpoint required by public recovery. The
corrected fixture, regression, Five Whys analysis, and new driver identity are accepted
in
[M3_1_PHASE2E_RUNNING_RECOVERY_CORRECTION.md](M3_1_PHASE2E_RUNNING_RECOVERY_CORRECTION.md).
The original gate evidence below remains the evidence for commit `50b30d8`, not for the
corrected driver.

The later pending-write fixture correction is accepted in
[M3_1_PHASE2E_PENDING_WRITE_CORRECTION.md](M3_1_PHASE2E_PENDING_WRITE_CORRECTION.md).

This decision accepts Phase 2E only. It does not classify killed databases, run public
recovery convergence, execute every crash selector, produce release evidence envelopes,
or claim Phase 2 or M3.1 completion.

## Scope reviewed

- 24 fixed, versioned, deeply frozen scenarios under the ceiling of 32;
- the added `request.claim-resume` witness for
  `request.claim.active_execution`;
- exact family, operation, setup, action, state-class, contract, convergence, and
  statement-coverage fields;
- a domain-separated digest for every scenario and for the complete registry;
- exact equality between declared coverage and all Phase 2 `kill_required` registry
  statements/templates;
- exact equality between each real trace and its scenario's branch coverage;
- exact identity and union verification for one manifest per fixed scenario;
- a process- and thread-bound fault gate that ignores setup and arms once;
- fresh absolute database paths beneath private, owned directories;
- fixed graph, lease, request, task, write, checkpoint, and failure fixtures;
- one direct persistence action per scenario with no `open_writer`, lease guard,
  renewal thread, sleep, retry treatment, or arbitrary dispatch;
- bounded setup-only lease expiration, clock-watermark reset, and expiry shortening;
- generated execution/checkpoint identities excluded from deterministic trace identity;
- real SQLite traces for every scenario;
- a branch-specific real child stop and parent-only `SIGKILL` sentinel for every
  scenario;
- stable duplicate enqueue, duplicate pending-write, and redirect-ready behavior;
- resume execution identity, recovery fences, redirect branches, checkpoint fork
  ancestry, and atomic request/checkpoint relations;
- stdlib-only load isolation and unchanged public API/package boundaries.

The implementation remains private to `Tamoz::Evals::Harness`. `tamoz-evals` does not
require a production Tamoz package at load time. Runtime capability references are
resolved only when this explicitly SQLite-specific harness runs.

## Review method

The review mapped every fixed definition through:

1. a fresh private database path;
2. disarmed migration, graph binding, and bounded setup;
3. immediate observer and gate arming;
4. one direct production persistence operation;
5. complete recorder finalization and deterministic replay;
6. exact scenario statement coverage;
7. exact 24-manifest trace union;
8. a separate real child stopped at the scenario's last SQL branch;
9. parent validation, `SIGKILL`, reaping, and final control attestation.

The adversarial pass removed a claim-resume branch label, duplicated a scenario identity,
changed source shapes, state classes, versions, and coverage, drifted the boundary
registry, duplicated and removed manifests, supplied malformed observers and paths,
reused database paths, weakened parent permissions, crossed owner threads, and checked
logical no-op states independently with raw SQL.

## Findings resolved

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | The accepted matrix originally had no runtime witness for `request.claim.active_execution`. | Operation coverage was reviewed without a statement-to-branch witness map. | Stop before implementation, commit the separate Five Whys correction, add `request.claim-resume`, and require exact declared/observed union equality. |
| High | Migration or fixture hooks could be mistaken for subject evidence. | Adapter setup and the selected operation shared one fault-injector channel. | Add a process/thread-bound gate that ignores all bootstrap hooks and arms immediately before one direct action. |
| High | A generic runner could execute arbitrary setup or actions while retaining a valid scenario id. | Flexibility would separate executable behavior from reviewed definitions. | Use a private exact 24-id dispatch with source-controlled setup and action methods; reject every unknown id. |
| High | `open_writer` would introduce a lease-renewal thread and nondeterministic hooks. | The public convenience API owns background lease maintenance. | Call the fixed internal persistence capability directly with a setup-created lease; source and runtime tests contain no `open_writer`. |
| High | Sleep-based takeover or renewal fixtures would be slow and flaky. | Wall-clock passage was being used as fixture state. | Use bounded setup-only SQL to expire a lease, reset a clock watermark, or shorten an expiry; arm afterward and use no sleep. |
| High | Duplicate and read-only cases could be mislabeled as successful mutations. | Transaction success and logical state change were conflated. | Declare only `stable` for the three no-op/read-only scenarios and verify their relational state in focused tests. |
| High | Scenario source hashes were frozen but concatenated nested arrays initially remained mutable. | Shallow Ruby freezing was mistaken for an immutable source definition. | Deep-freeze the complete source matrix before any registry instance is built and test every nested value. |
| Medium | The first driver definition understated checkpoint bounds for the fork fixture. | Setup and subject checkpoint counts were collapsed into one ambiguous number. | Declare separate maximums of two setup checkpoints and one subject checkpoint, plus the two-acquisition lease ceiling. |
| Medium | Millisecond-equal backend times could make validate/renew contracts non-strict. | Fast local execution can observe the same backend millisecond twice. | Reset the setup watermark to zero and shorten the stored expiry by one millisecond, making the subject transition strictly monotonic without waiting. |
| Medium | Cleanup failure could replace the primary scenario failure. | `ensure` called adapter close without preserving the active exception. | Preserve the primary exception and suppress only secondary close failure; raise close failure when it is the sole failure. |
| Medium | Reusing or placing a database in a shared directory would weaken isolation and fixture freshness. | Path validity did not imply ownership, privacy, or absence. | Require an absent absolute path under an owned directory with no group/world permissions; reject relative, existing, symlink, missing, or permissive targets. |

## Five Whys: executable branch completeness

1. Why is registry equality insufficient? It proves listed boundaries, not that fixtures
   execute mutually exclusive branches.
2. Why is one scenario per operation insufficient? `request.claim`,
   `checkpoint.append_writes`, and `checkpoint.commit` contain conditional statement
   paths.
3. Why use per-scenario exact coverage? A loose union can let one broad fixture hide a
   broken narrow branch.
4. Why also verify the union? Exact individual traces could still omit a registry
   statement if the source matrix omitted its witness.
5. Why require real child sentinels? Recorder replay proves trace structure; a stopped
   child proves the same fixed driver can causally reach the selector-control protocol.

## Five Whys: setup/evidence isolation

1. Why not attach the recorder only after creating the adapter? The adapter must receive
   its fault injector at construction.
2. Why not let the recorder filter setup operations? Unknown or accidentally matching
   setup labels could make the evidence authority depend on fixture details.
3. Why use a gate? It creates one explicit transition from ignored bootstrap to delegated
   evidence.
4. Why bind the gate to a process and thread? Forking or background callbacks must not
   inherit authority to attest to the subject action.
5. Why invoke direct capabilities? One synchronous call yields one transaction protocol
   and prevents unrelated lease-renewal hooks from racing the selector.

## Five Whys: deterministic lease fixtures

1. Why not sleep until lease expiry? Scheduler and filesystem load make timing tests
   nondeterministic and slow.
2. Why not use a tiny TTL? It still races setup and action and can fail before the subject
   begins.
3. Why is setup-only SQL acceptable? It constructs fixed old state while the evidence
   gate is disarmed; it is not the operation being evaluated.
4. Why use three narrow mutations? Each changes one reviewed column for one exact lease
   identity and checks that exactly one row changed.
5. Why test old and new values? A complete trace alone cannot prove the intended takeover,
   watermark, or strict-expiry branch contract.

## Gate evidence

Pinned source identities:

- scenario registry:
  `sha256:e30afb2490ae9a5907d87ebeba7f442c70bd27e320442d7e0c2a2fe2ef05c23f`;
- scenario driver:
  `sha256:6a23d729cb155343b3361a9aaf37dc21466fb694a6f7d180ebfdeb15233f42a3`.

Focused gates under rbenv Ruby 3.3.11:

- scenario registry and driver: 17 tests, 19,440 assertions;
- combined source-audit, boundary-registry, recorder, selector-control, and scenario
  regression: 59 tests, 21,899 assertions;
- warning-enabled registry and driver tests passed;
- dependency isolation, packaging, and public API tests passed;
- 10 seeded scenario-driver runs: 110 tests, 175,670 assertions, including 240 real
  child-stop/parent-kill sentinels;
- syntax and `git diff --check` passed.

Full gate under rbenv Ruby 3.3.11:

- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI: 296 tests, 24,524 assertions, 0 failures, 0 errors, 0 skips;
- syntax, packaging, public API, dependency isolation, M0-M2 conformance, and SQLite
  regressions passed.

## Residual limits and non-claims

- Phase 2E proves successful full-operation traces and one branch-specific process
  sentinel per scenario. It does not yet run every derived selector under process death.
- Scenario state-class and convergence identities are declared, but killed database
  classification and third-process convergence are Phase 2F work.
- Focused raw-SQL assertions validate fixture branches but are not the standalone,
  Tamoz-free projector required for release evidence.
- Setup SQL is trusted, fixed harness code. It does not classify post-kill state and is
  excluded from the armed trace by construction.
- Scenario manifests bind the scenario definition, production subject, boundary registry,
  and recorder. The repository tree binds executable driver code; a separate manifest
  driver field is not added retroactively to the accepted Phase 2B schema.
- The real-process path targets POSIX `SIGSTOP`/`SIGKILL`. Unsupported platforms must skip
  explicitly and cannot provide release crash evidence.
- Local evidence covers Ruby 3.3.11. Ruby 3.4 and 4.0 remain exact-revision CI gates.

## Acceptance checklist

- [x] The corrected fixed matrix contains exactly 24 scenarios under the ceiling of 32.
- [x] Every source definition and derived registry value is deeply frozen and digest-bound.
- [x] Every scenario maps to one Phase 2 kill-required operation.
- [x] Declared statement coverage exactly equals the required boundary registry.
- [x] Every real manifest exactly equals its scenario's declared branch coverage.
- [x] The 24-manifest trace union is exact, complete, and duplicate-free.
- [x] `request.claim-resume` reaches `request.claim.active_execution`.
- [x] Setup is disarmed and the observer is armed immediately before one direct action.
- [x] No background lease thread, sleep, retry treatment, or arbitrary action runs.
- [x] Fixture counts, dynamic write indices, and consume indices are bounded.
- [x] Duplicate and read-only scenarios are explicitly stable.
- [x] Identity, recovery fence, redirect, fork, pause, failure, and request/checkpoint
  branches have focused relational treatments.
- [x] Every fixed scenario stops a real child at a branch-specific SQL selector.
- [x] Only the parent authorizes and attests to the resulting `SIGKILL`.
- [x] Freshness, permissions, malformed input, branch drift, and owner-thread violations
  fail closed.
- [x] Package loading remains stdlib-only and the public surface is unchanged.
- [x] Focused, seeded stability, warning, packaging, and full regression gates pass.
- [x] No Phase 2F oracle or convergence implementation is mixed into this commit.
