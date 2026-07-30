# M3.1 phase 2B implementation review

Review target: bounded SQLite trace recording, semantic selector derivation, and
deterministic manifest verification.

Base revision: `2c2df35`.

Decision: accepted for commit on 2026-07-30. No unresolved correctness, security,
reliability, or maintainability finding remains in this slice.

This decision accepts Phase 2B only. It does not claim selector intervention, child
suspension, process killing, crash atomicity, scenario completeness, independent database
classification, recovery convergence, or Phase 2 completion.

## Scope reviewed

- disarmed bootstrap and one-way recorder lifecycle;
- binding to one Phase 2 kill-required operation and one owner thread;
- exact first-attempt transaction/statement hook protocol;
- deeply frozen hook input and recorder-owned retained strings;
- event, operation, statement, attempt, occurrence, selector, scalar, and string ceilings;
- zero-based contiguous dynamic statement instances;
- exact event sequence and occurrence construction;
- semantic selector grouping by registry template;
- deterministic `single`, `first`, lower-median `middle`, and `final` selection;
- domain-separated selector, recorder-definition, subject, and manifest digests;
- canonical digest ordering and duplicate coverage/digest rejection;
- scenario, registry, recorder, revision, tree, and dirty-state binding;
- independent manifest preflight, canonicalization, event replay, and selector
  re-derivation;
- internal packaging and absence of a new documented public API.

The implementation is separated into recorder, selector-deriver, and manifest-verifier
files. All three remain internal under the private `SQLiteTraceRecorder` constant.

## Review method

The review followed one real SQLite lease-release operation from the production fault hook
through:

1. bootstrap suppression and arming;
2. registry validation and protocol state transitions;
3. immutable event construction and bounded counters;
4. template-based selector grouping and digest ordering;
5. subject/registry/scenario/recorder manifest binding;
6. JSON round-trip and fresh-recorder replay verification.

The adversarial pass then exercised malformed hook shapes, mutable hooks, unexpected
operations, retries, cross-thread events, invalid ordering, mismatched SQL pairs, repeated
exact boundaries, dynamic gaps, empty SQL traces, event overflow, invalid scenario and Git
metadata, mutable registries, digest tampering, occurrence tampering, selector deletion,
reference replacement, extra fields, empty selectors, oversized arrays/strings/integers,
and non-scalar values.

## Findings resolved

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | A generated manifest had no independent verifier. | Deterministic construction was mistaken for independently checkable evidence. | Add bounded preflight, canonical digest verification, fresh-recorder event replay, selector re-derivation, and exact manifest equality. |
| High | Dynamic statement templates initially accepted gaps or repeated concrete indices. | Template expansion count did not prove loop identity or order. | Require each dynamic point to observe zero-based contiguous registry instances. |
| High | A transaction with no SQL could finish as a valid trace. | Transaction framing and boundary reachability were conflated. | Require at least one complete SQL hook pair before finalization. |
| High | Untrusted manifests were canonicalized before container and scalar bounds were checked. | Canonical validity was treated as a resource bound. | Preflight exact shapes, event/selector counts, scalar types, 256-byte strings, and bounded integers before normalization. |
| High | Mutable hook metadata could race recording, while deep-freezing an event could freeze caller-owned strings. | Hook lifetime and recorder ownership were implicit. | Require deeply frozen hook input and copy all serialized strings into recorder ownership. |
| Medium | The declared lower-median selector used the upper median for even loop counts. | Zero-based array indexing was not checked against the protocol wording. | Select `(length - 1) / 2` and pin a four-instance regression. |
| Medium | Selector bodies were coverage-unique but their serialized digests were not explicitly checked for uniqueness. | Coverage identity and sharding identity were reviewed separately. | Reject duplicate selector digests after canonical ordering. |
| Medium | Finalization errors from derivation or manifest construction could leave the recorder armed. | Only explicit incomplete-trace branches set the failed state. | Make every finalization exception transition irreversibly to failed. |
| Medium | Recorder, selector derivation, and manifest verification occupied one 850-line file. | Cohesive protocol work accumulated without a maintainability boundary. | Split state recording, selector derivation, and untrusted-manifest verification into three internal files. |
| Medium | Protocol behavior was broader than the recorder-definition digest described. | Limits and field names were pinned before lifecycle and verification rules. | Bind operation/thread/bootstrap/hook ownership, hook order, dynamic-index, replay, scalar, and ordering policies in the exact recorder-definition digest. |
| Medium | The full gate exposed a race in the existing TERM-resistant subprocess test. | Its child installed the TERM trap after spawn, but the 50 ms deadline could fire during Ruby startup. | Temporarily inherit `SIG_IGN` into the child, replace it with the child trap when the script starts, restore the parent handler in `ensure`, and pass 50 consecutive focused runs. |

## Five Whys: replay verification

1. Why is a valid outer digest insufficient? A producer can consistently digest incorrect
   events or selectors.
2. Why are exact event shapes insufficient? Ordering, pairing, occurrences, and registry
   ownership are relational.
3. Why are individually valid selectors insufficient? They may omit or disagree with the
   recorded trace.
4. Why replay through a new recorder? It applies the same bounded state machine from an
   independent initial state and deterministically reconstructs every derived field.
5. Why still bind the recorder protocol digest? Replay semantics themselves are versioned
   and must not change under an old manifest identity.

## Gate evidence

Pinned protocol evidence:

- recorder definition:
  `sha256:ebf5a908b273654e63a35bd1ba98c06a57b0ee41cb88e14f4b843983c8153a47`;
- production lease-release trace manifest:
  `sha256:b5f7eaf727e8fe3163a014ca5720f18c99845f020d332aac2931a4f83d937d9f`.

Focused gates:

- trace/selector/manifest tests: 11 runs, 952 assertions;
- registry/hook tests: 5 runs, 1,328 assertions;
- Ripper source-audit tests: 7 runs, 55 assertions;
- canonical JSON tests: 5 runs, 7 assertions;
- evaluation verifier tests: 22 runs, 142 assertions;
- SQLite kernel regression: 6 runs, 20 assertions;
- TERM-resistant timeout stability treatment: 50 consecutive runs;
- syntax and `git diff --check` passed.

Full gate under rbenv Ruby 3.3.11:

- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI: 248 runs, 4,855 assertions, 0 failures, 0 errors, 0 skips;
- syntax, packaging, public API, M0-M2 conformance, and all SQLite regressions passed.

## Residual limits and non-claims

- Phase 2B proves deterministic trace/selector construction, not that every fixed scenario
  reaches every required registry boundary. Scenario definitions and trace-union coverage
  belong to Phase 2E.
- Selector occurrence has not yet controlled a child. Parent intervention, stop
  observation, and intentional termination semantics belong to Phases 2C and 2D.
- The `retry` and `exhausted` attempt vocabulary is versioned, but Phase 2B accepts only
  successful first attempts. Real busy/locked traces remain Phase 5 work.
- Subject Git revision/tree/dirty fields are validated and bound, but this component does
  not invoke Git. The fixed evidence runner must capture them through the bounded process
  primitive.
- Manifests remain internal and unsanitized. Public artifact schemas and the
  `m3.persistence` cases belong to Phase 7.
- Local evidence covers Ruby 3.3.11. Ruby 3.4 and 4.0 remain exact-revision CI gates.

## Acceptance checklist

- [x] Bootstrap hooks cannot contaminate an armed trace.
- [x] One trace cannot silently mix operations, threads, or attempts.
- [x] Every retained hook is registry-valid, deeply frozen, and copied.
- [x] Transaction and SQL hook ordering is complete and paired.
- [x] Dynamic loop instances are finite, contiguous, and semantically collapsed.
- [x] Concrete selectors retain replayable labels and occurrences.
- [x] Coverage identities and selector digests are unique.
- [x] Selector order is canonical digest order.
- [x] Manifest provenance binds scenario, registry, recorder, revision, tree, and dirty state.
- [x] Manifest verification is bounded and independently replays all derivation.
- [x] Protocol and real integration digests are pinned.
- [x] Focused and full regression gates pass.
- [x] No Phase 2C intervention work is mixed into this commit.
