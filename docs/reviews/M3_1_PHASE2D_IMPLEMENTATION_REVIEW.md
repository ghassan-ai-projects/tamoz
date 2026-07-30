# M3.1 phase 2D implementation review

Review target: fsynced SQLite selector-control protocol and malicious/mismatch treatments.

Base revision: `dd259bd`.

Decision: accepted for commit on 2026-07-30. No unresolved correctness, security,
reliability, or maintainability finding remains in this slice.

This decision accepts Phase 2D only. It does not claim real SQLite scenario coverage,
transaction atomicity, old/new state classification, recovery convergence, complete
selector execution, evidence-envelope production, or Phase 2 completion.

## Scope reviewed

- creation of a fresh control directory beneath an already private root;
- exact ownership, `0700` mode, same-filesystem placement, and device/inode identity;
- an absent, fixed control filename and exclusive child creation;
- `O_NOFOLLOW` where available plus unconditional `lstat`/`fstat` identity checks;
- exact owned regular `0600` single-link control-file requirements;
- canonical JSON with one trailing newline and a domain-separated content digest;
- a pinned definition digest covering record fields, limits, filesystem policy, stop
  policy, deadline decision, post-kill verification, and final result relation;
- file flush/fsync, close, parent-directory fsync, and post-close inode validation;
- a process-bound and thread-bound child stopper constructed after child start;
- registry-valid exact operation, hook point, statement, attempt, and occurrence matching;
- child `SIGSTOP` after durable close and fail-closed behavior if it is resumed;
- parent acceptance of exact `SIGSTOP` only;
- bounded stable reads with duplicate-key, UTF-8, size, mode, ownership, link, inode,
  canonical-byte, record-shape, identity, digest, scenario, registry, selector, and hook
  checks;
- re-reading and re-fingerprinting the control after process termination;
- exact immutable `SubprocessRunner::Result` attestation for intentional `SIGKILL`;
- absence of database state, paths, owner secrets, or process ids from the control record;
- internal packaging and continued stdlib-only isolation of `tamoz-evals`.

The implementation is split into layout/expectation, child-stopper, and
parent-intervention components. The entire `SQLiteSelectorControl` constant remains
private to the evaluation harness.

## Review method

The primary review followed one real subprocess through:

1. private same-filesystem directory preparation;
2. child-side reattachment by pinned directory identity;
3. construction of the stopper after process start;
4. exact validated occurrence matching;
5. exclusive canonical write, file fsync, close, and directory fsync;
6. child `SIGSTOP`;
7. parent `WUNTRACED` observation;
8. stable independent read and exact expectation comparison;
9. parent-only process-group `SIGKILL`;
10. post-kill control re-read and exact process-result attestation.

The adversarial pass exercised pre-existing directories and files, nonprivate modes,
symlink directories and files, hardlinks, different-filesystem anchors, replaced
directories, replaced files, mid-read mutation, post-authorization replacement, empty and
oversized files, invalid UTF-8, invalid JSON, duplicate keys, noncanonical bytes, unknown
fields, hook/scenario/registry/selector mismatches, invalid selector digests, mutable or
changed registries, mutable hooks, wrong threads/process identities, wrong operations,
wrong stop signals, missing control, early exit, missed occurrences, timeout, and wrong
termination results.

## Findings resolved

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | A child exit or kill could be mistaken for selected-boundary coverage without an authorized control. | Process death and selector reachability were not causally bound. | Require exact durable control plus parent authorization and a separate final result attestation; early exit, missing control, timeout, or wrong kill cannot verify. |
| Critical | A child could write a marker and continue beyond the selected hook before the parent acted. | File visibility is not an execution barrier. | Close/fsync first, then self-send uncatchable `SIGSTOP`; any unexpected resume raises before the hook can return. |
| High | A valid file could be replaced after authorization but before evidence assembly. | Only the pre-kill read was initially treated as authoritative. | Retain the complete stat fingerprint and perform a second canonical read after process termination. |
| High | The writer initially validated any matching post-close path rather than the exact inode it opened. | File properties and file identity were reviewed separately. | Retain the opened file stat and require identical device/inode after close and directory fsync. |
| High | A symlink, hardlink, permissive file, or stale pre-existing file could weaken provenance. | Path existence alone was treated as sufficient. | Require a fresh private directory, absent path, `O_EXCL`, conditional `O_NOFOLLOW`, regular owned `0600` mode, one link, matching device, and pre/post `lstat`/`fstat`. |
| High | A stable registry digest method could hide mutable runtime registry semantics. | Reference identity was checked without requiring immutable referenced data. | Require the registry document to be deeply frozen and revalidate its version/digest before every hook or parent poll. |
| High | Malformed control input could consume resources or exploit parser ambiguity. | Parsing, bounds, duplicate detection, canonicality, and semantic comparison were not one ordered gate. | Bound the file before reading, read at most 64 KiB plus one byte, reject duplicates before parsing, preflight exact shapes, compare exact expected data, require canonical bytes, then recompute the digest. |
| Medium | `control_version: 1` did not bind behavioral semantics such as fsync, stop, re-read, or result policies. | A format version was mistaken for a complete protocol identity. | Add and pin a domain-separated definition digest in every record. |
| Medium | Duck-typed process results could change answers between verification and later serialization. | Interface compatibility was treated as provenance and immutability. | Accept only a frozen exact `SubprocessRunner::Result` and verify its full intentional-kill relation. |
| Medium | The first fsync/mutation probes redefined global `File.open`, producing warnings under the full gate. | Test observability used global method replacement. | Observe the real C-level `flush`, `fsync`, and `read` calls with scoped `TracePoint`; the warning-enabled suite is clean. |

## Five Whys: selector-control authority

1. Why is child death insufficient? It does not identify which boundary, if any, was
   reached.
2. Why is a child-written file insufficient? It may be stale, partial, mismatched, or
   written before the child has stopped progressing.
3. Why require fsync before `SIGSTOP`? The parent must validate complete stable bytes while
   the callback is unable to return.
4. Why independently reconstruct the expected record? Child observations cannot define
   their own success criteria.
5. Why re-read after `SIGKILL` and attest the result? Authorization, actual parent kill,
   and retained evidence must remain one unchanged causal chain.

## Gate evidence

Pinned protocol evidence:

- selector-control definition:
  `sha256:9ced1a4a060c6d5de21f523b9594747c8a4017e482ab7b8086de412218d098f1`.

Focused gates under rbenv Ruby 3.3.11:

- selector-control deterministic, malicious, and real-process tests: 19 runs,
  124 assertions;
- adjacent subprocess tests: 16 runs, 131 assertions;
- combined control/trace/registry/packaging/isolation regression: 60 runs,
  2,661 assertions;
- warning-enabled selector-control test passed;
- selector-control stability treatment: 40 consecutive seeded runs;
- syntax and `git diff --check` passed.

Full gate under rbenv Ruby 3.3.11:

- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI: 279 runs, 5,080 assertions, 0 failures, 0 errors, 0 skips;
- syntax, packaging, public API, dependency isolation, M0-M2 conformance, and SQLite
  regressions passed.

## Residual limits and non-claims

- The synthetic real-process treatment proves the control and parent-kill mechanics at an
  exact registry-valid hook. Phase 2E must drive every fixed real SQLite scenario and
  prove trace/selector reachability.
- A control record proves only that the trusted harness adapter observed the expected
  hook. It does not classify database state. Phase 2F supplies the independent raw-SQL
  oracle.
- Selector provenance currently relies on a verified Phase 2B manifest supplied by the
  fixed runner. Phase 2E/2G must bind that manifest and its exact scenario/subject
  identities into execution and evidence.
- Private modes isolate other users; this is not a sandbox against arbitrary malicious
  code already running as the same operating-system user. Phase 2 evaluates fixed Tamoz
  subjects, not hostile tenant binaries.
- File and directory fsync success is the strongest portable process-level signal exposed
  by the supported POSIX filesystems. Hardware and filesystem durability semantics remain
  environment evidence, not a universal physical-storage claim.
- The protocol targets POSIX process groups, `SIGSTOP`, `WUNTRACED`, and `SIGKILL`.
  Unsupported platforms must refuse this evidence path rather than report a pass.
- Local evidence covers Ruby 3.3.11. Ruby 3.4 and 4.0 remain exact-revision CI gates.

## Acceptance checklist

- [x] The parent creates a fresh private same-filesystem control directory.
- [x] The control path is absent before both child and parent adapters initialize.
- [x] The child adapter is process-bound, thread-bound, and registry-bound.
- [x] Only the exact selector occurrence can write control.
- [x] Exclusive creation, modes, ownership, links, device, and inode fail closed.
- [x] Canonical bytes and the file and parent directory are fsynced before stop.
- [x] The callback cannot return after `SIGSTOP`.
- [x] The parent accepts only exact `SIGSTOP` and never receives a child pid.
- [x] Every record field and protocol semantic is digest-bound.
- [x] Duplicate, malformed, oversized, noncanonical, mismatched, or changed control fails.
- [x] The control is unchanged after parent kill.
- [x] Final attestation requires exact intentional `SIGKILL`, not timeout or cleanup.
- [x] Missing control, early exit, wrong stop, timeout, and wrong result cannot pass.
- [x] No database state, path, secret, owner, or pid enters the control record.
- [x] Focused, stability, warning, and full regression gates pass.
- [x] No Phase 2E scenario-driver work is mixed into this commit.
