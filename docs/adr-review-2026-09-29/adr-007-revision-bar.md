# ADR-007 plain-language revision — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and fence

Explain read-only node state and returned updates with a simple example. Accurately distinguish
built-in deep freezing, codec encode/decode preparation, custom-type immutability contracts and
replay limits. Only ADR-007 and this review record change; no runtime change or commit requested.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Plain-language context and correct update example | Example check and semantic review | PASS |
| B2 | Accepted immutability rule preserved; actual codec mechanism and custom-type limits stated | Source inspection and existing codec tests | PASS |
| B3 | No assertion that freezing alone guarantees replay | Diff review | PASS |
| D1 | ADR/citation/catalog and documentation checks pass | Existing validators and documentation test | PASS |
| E1 | Concise existing sections; authorized files/modes/whitespace only | Diff/status checks | PASS |
| F1 | Fresh semantic review and scoped results | Independent reviewer | PASS |

No runtime or real-model claim. Existing deterministic tests and a small example check cover the
wording; no new test mirrors the prose. Full CI retains the previously established compiler issue.

## Review and loop

1. Bar set before edits; checks OPEN.
2. Rewrote the ADR with a read-only-state explanation, returned-update example and scoped codec/custom-type guarantees. All checks passed.
3. Fresh `review_adr007` reviewer found no issues. Final self-review required no changes; all rows PASS.

## Results

- Codec tests: 13 runs / 149 assertions. State-manager tests: 4 runs / 16 assertions. Documentation: 3 runs / 1,649 assertions. All passed.
- Standalone example check confirmed a new update value can be returned and assignment to normalized state raises FrozenError; this was a direct check, not an additional counted Minitest case.
- ADR validator: 59 records. Citation verifier: 441 citations. Catalog check current; metadata and section names unchanged.
- Independent reviewer checked clarity and the codec/state preparation seams; no actionable findings. Existing implementation and accepted intent preserved; no runtime or real-model claim.
- Only the ADR and this record changed in this task; new record mode 644 and whitespace checks passed. No commit requested.

## Lesson

Explain immutability through what a node may read and return. Frozen state protects a snapshot;
serialization and execution replay are distinct guarantees.

## Delivery

2026-10-02: owner requested commit. Fresh pre-commit reviewer `precommit_adr007` found no actionable issues. Current ADR/citation/catalog/documentation checks passed again; whitespace passed. Commit scope is ADR-007 and this record; no push requested.
