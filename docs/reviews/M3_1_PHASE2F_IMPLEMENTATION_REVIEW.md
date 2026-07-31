# M3.1 phase 2F implementation review

Review target: standalone raw-SQL classification and fresh-process convergence for the
24 fixed SQLite scenarios.

Base revision: `541e2f5`.

Decision: accepted for commit on 2026-07-31. No unresolved correctness, security,
reliability, or maintainability finding remains in this slice.

This decision accepts Phase 2F only. It does not execute every derived selector, produce
the PR/release evidence matrix, implement sharding or merge verification, or claim Phase
2 or M3.1 completion.

## Scope reviewed

- one executable, Tamoz-free oracle accepting only a fixed scenario id and absolute
  database path;
- a private, stable snapshot of the main database, WAL, and SHM before any SQLite open;
- source-file ownership, privacy, link, stability, and aggregate-byte checks;
- read-only/query-only SQLite access to fixed, ordered projections;
- application id, schema version, migration checksum, integrity, and foreign-key checks;
- independent checkpoint, request payload, response, terminal error, pending outcome,
  and pending-write digest recomputation;
- bounded canonical JSON, state-codec, checkpoint-codec, request, transition-evidence,
  ancestry, counter, head, lease, and pending-consumption validation;
- 24 hand-authored relational contracts with explicit `old`, `new`, or `stable`
  classification;
- `partial` for structurally valid mixed or wrong-scenario state and `invalid` for
  structural, schema, digest, integrity, or bound failure;
- normalized logical projections that omit paths, owners, raw ids, payloads, and times;
- a fixed convergence-probe map covering every scenario and every declared complete
  state;
- fresh-process lease fencing, duplicate delivery, request recovery, checkpoint/request
  reopening, and pending-write replay;
- execution-identity preservation for claimed, running, and redirecting recovery;
- a separate `synchronous=FULL`, strict, primary-keyed call ledger for detecting node
  reexecution;
- canonical, digest-bound convergence reports with fixed bounded facts;
- unchanged public API and stdlib-only `tamoz-evals` load isolation.

## Review method

Classification and convergence were reviewed as separate claims:

1. create one complete pre-action and post-action state from each fixed driver;
2. run the standalone oracle in a clean process with no Tamoz require or source load;
3. compare the observed class only to the hand-authored scenario contract;
4. kill real scenario children at `before_commit` and `after_commit`;
5. independently classify those databases as old/new or stable;
6. copy a classified complete state for convergence treatment;
7. elide only lease expiry on that copy when passage of the 30-second fixture TTL is the
   precondition;
8. spawn a fresh Ruby process with no inherited adapter;
9. run exactly the scenario's fixed convergence probe;
10. verify bounded semantic facts and a canonical report digest.

No production materializer or recovery path contributes to the oracle classification.
No oracle projection contributes generated identifiers or payloads to convergence.

## Findings resolved

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | The original running-recovery fixture had no running checkpoint and could not pass public recovery. | Inbox-row status was mistaken for complete executable protocol state. | Stop Phase 2F, add the Phase 2E Five Whys correction and public recovery regression, fully gate it, and commit it independently as `6a85d25`. |
| Critical | The original pending-write fixture stored a dynamic terminal route for a static node and could not be continued. | Effective routing was confused with node-returned routing authority. | Stop Phase 2F again, persist `goto: nil`, add a non-reexecution continuation regression, fully gate it, and commit it independently as `9f8b4e9`. |
| Critical | Opening the source database read-only could still change or consume WAL/SHM state. | SQLite read-only semantics were treated as byte-level source immutability. | Copy a stable, private main/WAL/SHM snapshot first, open only that copy, and prove source bytes are unchanged. |
| Critical | Reopening through Tamoz could reproduce the writer's assumptions and falsely attest atomicity. | Recovery and classification shared implementation authority. | Keep the oracle self-contained with only `digest`, `json`, `sqlite3`, and `tmpdir`; prohibit every Tamoz require and classify before recovery. |
| High | A production transition run on a clone would be a correlated expected-state generator. | Executable behavior was being considered an oracle. | Encode every expected state as a hand-authored relational contract and use production code only afterward for convergence. |
| High | Generated ids and timestamps made correct states physically different and risked leaking internal values. | Physical identity was conflated with logical identity. | Validate raw relations, then replace generated executions/checkpoints with ordered logical roles and omit times, paths, owners, payloads, and raw ids. |
| High | Duplicate enqueue, duplicate pending writes, and redirect readiness do not have distinct old/new bytes. | Successful commit was conflated with logical mutation. | Permit `stable` only for the three scenario-declared cases and reject ambiguous opportunistic stability. |
| High | A running transition may be direct with no checkpoint or atomic with a checkpoint. | The first validator encoded only the original direct fixture shape. | Require transition evidence checkpoint id to equal the request checkpoint id, allowing both `nil == nil` and the corrected atomic binding. |
| High | Persisted writes could be replayed while silently executing the node again. | Database convergence alone cannot observe an external sibling invocation. | Use a separate FULL SQLite ledger with an exact strict schema and unique logical invocation; require one invocation after both normal and durable replay paths. |
| High | Treating every low-level scenario as a request to “complete the graph” would overclaim public semantics. | Convergence was modeled as one generic action instead of scenario-specific invariants. | Map all 24 scenarios to fixed lease, inbox, duplicate, recovery, pending replay, checkpoint, or request/checkpoint probes. |
| Medium | Checkpoint history was initially read as oldest-first. | Storage sequence order was assumed instead of checked. | Use the documented newest-first history order and assert exact counts and current statuses. |
| Medium | A graph node block initially called the convergence object through DSL `self`. | Ruby block ownership under `instance_eval` was overlooked. | Capture a bound recorder method before graph construction and call that closure from the node. |
| Medium | Per-file size bounds allowed aggregate main/WAL/SHM bytes to exceed the declared database ceiling. | Component bounds were mistaken for a total resource bound. | Enforce the 256 MiB ceiling across all copied SQLite files before copying. |
| Medium | Missing migration tables surfaced as a generic database failure. | Schema-query exceptions were not classified at the schema boundary. | Translate schema SQL failures to `schema_invalid` and test missing-table and checksum drift. |
| Medium | Snapshot or adapter cleanup failure could mask the primary diagnostic or disappear after success. | Cleanup was not modeled as a secondary failure channel. | Preserve primary failures, suppress only secondary cleanup errors, and fail successful runs if cleanup alone fails. |
| Medium | The convergence ledger and database paths had no explicit file-size ceiling. | Classification bounds were not carried into the post-classification process. | Enforce 256 MiB for the database copy and 1 MiB for the ledger before opening either. |
| Medium | The first full gate exposed a 75 ms subprocess test deadline that could expire before its child reached `SIGSTOP`. | A scheduling-sensitive startup budget was coupled to the requirement that the nil-intervention branch be exercised. | Stop acceptance, record a Five Whys correction, stabilize it across 20 seeds and full CI, and commit the test-only fix independently as `541e2f5`. |

## Five Whys: independent classification

1. Why not recover first? Recovery can repair or reinterpret the state before it is
   classified.
2. Why not use Tamoz readers without mutation? They share codecs, materializers, and
   invariants with the writer.
3. Why not generate an expected database with a successful reference run? The same
   defect can occur in both executions.
4. Why use relational contracts? They state the required rows, ordering, counters,
   digests, and references without copying generated values.
5. Why run convergence afterward? Atomicity and recoverability are separate properties;
   both must pass without one serving as evidence for the other.

## Five Whys: source immutability

1. Why was `readonly: true` insufficient? SQLite may inspect or alter WAL-related state
   while opening a database.
2. Why not hash only the main file? Committed state may reside in WAL, and SHM affects
   interpretation.
3. Why copy all three? The oracle needs a self-contained snapshot while preserving the
   killed source as evidence.
4. Why fingerprint before and after copying? A concurrent change could otherwise create
   a torn snapshot.
5. Why impose aggregate bounds before copying? A hostile sidecar must not bypass the
   database resource ceiling or cause unbounded I/O.

## Five Whys: pending-write convergence

1. Why is a completed request insufficient? The executor could have called the node
   again and still reached the same database state.
2. Why not use an append-only marker? Its own crash behavior and torn writes would become
   an unreviewed durability dependency.
3. Why use a second SQLite database? It provides an independently committed invocation
   fact.
4. Why `synchronous=FULL` and a primary key? The fact must be durable, and the same
   logical invocation must be impossible twice.
5. Why test old and durable states? The old path must call the node exactly once; the
   durable-write path must consume the stored outcome and leave the prior single call
   untouched.

## Adversarial treatments

- unknown scenarios, missing arguments, missing/random/oversized files, aggregate
  sidecar overflow, permissive modes, and symlinks;
- user-version, migration-table, and migration-checksum drift;
- malformed canonical JSON, duplicate keys, noncanonical Unicode, invalid state/checkpoint
  wires, and bounded depth/item/string limits;
- request payload, response, terminal-error, checkpoint, pending-write, and correlated
  pending-outcome digest corruption;
- transition gaps and evidence mismatch, broken parent foreign keys, counter/head drift,
  request/checkpoint execution mismatch, and pending-consumption mismatch;
- logically mixed transaction state and valid state supplied under the wrong scenario;
- active-lease recovery without expiry elision, classification mismatch, unexpected or
  oversized ledger, wrong ledger seed, and exact-ledger-schema mismatch;
- two independently generated executions producing byte-identical normalized oracle and
  convergence reports;
- source main/WAL/SHM byte comparison before and after oracle execution;
- static source checks for Tamoz requires, dynamic eval surfaces, read-only/query-only
  policy, and executable mode.

## Residual limits and non-claims

- Phase 2F classifies full pre-action/post-action states and real `before_commit`/
  `after_commit` kills. Phase 2G must execute and retain every derived statement selector.
- Lease expiry elision changes only a convergence copy after classification. It models
  elapsed TTL without waiting and is not part of atomicity evidence.
- Fresh-process enforcement belongs to the process harness. The probe definition records
  this caller obligation; the probe class cannot prove its own process ancestry.
- The convergence process intentionally loads Tamoz. Its result cannot revise or replace
  the prior independent oracle class.
- The standalone oracle duplicates the reviewed wire and relational formats by design.
  A format or schema change must update its pinned definition digest and tests.
- The source tree binds executable oracle code; the oracle definition digest binds its
  versioned policy, scenario set, classifications, limits, and output contract.
- Real kill evidence remains POSIX-only. Unsupported platforms cannot make the release
  crash-safety claim.
- Local evidence covers Ruby 3.3.11. Ruby 3.4 and 4.0 remain exact-revision CI gates.

## Acceptance checklist

- [x] The oracle runs without loading any Tamoz feature.
- [x] The oracle accepts no arbitrary SQL, class, method, or contract input.
- [x] Source main/WAL/SHM bytes remain unchanged.
- [x] Schema, integrity, foreign keys, digests, canonical payloads, bounds, and relations
  fail closed.
- [x] All 24 fixed pre-action and post-action states classify exactly.
- [x] All three declared stable scenarios remain byte-logically stable.
- [x] Real `before_commit` and `after_commit` kills classify old/new or stable exactly.
- [x] Mixed complete state is `partial`; structural failure is `invalid`.
- [x] Reports are canonical, digest-bound, bounded, normalized, and non-disclosing.
- [x] Every scenario and declared complete class has one fixed convergence probe.
- [x] Claimed/running/redirecting recovery preserves execution identity.
- [x] Stale leases are fenced after takeover.
- [x] Duplicate delivery retains one binding.
- [x] Pending writes replay without a second logical invocation.
- [x] Checkpoint history, head, request status, and terminal relation reopen consistently.
- [x] Package loading remains isolated and the public surface is unchanged.
- [x] Focused, seeded, warning, packaging, syntax, design, and full-CI gates are recorded.

## Gate evidence

Pinned identities:

- raw oracle:
  `sha256:072d5bed69eb5d0253aedbddcb4623ab0cffd8c7a637bb242c05a779c5138530`;
- convergence probe:
  `sha256:cced9b548e63f02c4fe77461cc022540c9e3d31b569b109d45642eab09bdc96e`.

Executed under rbenv Ruby 3.3.11:

- focused oracle and convergence: 15 tests, 2,249 assertions;
- all SQLite, dependency-isolation, packaging, and public-API regressions:
  126 tests, 24,600 assertions;
- warning-enabled oracle and convergence passed;
- five fixed seeds: 75 tests, 11,245 assertions, including 240 real
  child-stop/parent-kill classifications and 225 fixed-state fresh convergence
  processes;
- executable mode, static dependency/eval audit, syntax, and `git diff --check` passed;
- subprocess timing correction: 20 focused seeds and 16-test complete-file regression,
  committed separately as `541e2f5`;
- design validation: 22 documents, 55 invariants, 40 ADRs;
- final full CI: 313 tests, 26,899 assertions, 0 failures, 0 errors, 0 skips.
