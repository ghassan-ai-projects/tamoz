# ADR-008 concurrency clarification — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and fence

Explain thread and inline modes plainly, preserve the synchronous API and fiber conformance bar,
and scope deterministic-history claims to deterministic behavior and matching inputs/identity.
Only ADR-008 and this review record change. No runtime change; commit requested, no push requested.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Modes/default and future fiber condition preserved | Configuration/pool source review and focused refusal test | PASS |
| B2 | History scope, scheduling limits and MRI CPU caveat accurate | Existing deterministic graph tests and semantic review | PASS |
| D1 | ADR/citation/catalog/documentation checks pass | Existing validators and documentation test | PASS |
| E1 | Concise existing sections, no unrelated files or code changes | Diff/mode/whitespace review | PASS |
| F1 | Fresh review before commit; actual evidence distinguished from broad guarantees | Independent reviewer and report | PASS |

No new test mirrors the prose. Existing deterministic tests cover mechanics; no real-model or
performance result is claimed. Full CI retains the previously established compiler limitation.

## Review and loop

1. Bar set before edits; checks OPEN.
2. Rewrote the two modes and scoped state-history equivalence. Existing focused tests passed.
3. Fresh reviewer `precommit_adr008` identified missing branch/completion assumptions. Replaced the condition with successful executions and deterministic graph behavior.
4. Reviewer rechecked the revised diff: resolved, no remaining findings. Final checks passed; self-review required no further changes. All rows PASS.

## Results and delivery

- Pool refusal/bounds: 1 run / 5 assertions. Graph history: 1 run / 2 assertions. Determinism properties: 2 runs / 480 assertions. All passed. An initial nonexistent pool filter ran zero cases; the correct bounds/refusal filter was then run and is the counted result.
- ADR validation: 59 records. Citation verification: 441 citations. Catalog current. Documentation test: 3 runs / 1,649 assertions. All passed after the final prose revision.
- Only ADR-008 and this record are included. Record mode 644 and whitespace checks passed. No runtime, real-model, performance or full-CI success claim; the previously established compiler limitation remains.
- Owner requested commit; independent review completed before commit. No push requested.

## Lesson

Predictable scheduling is not deterministic application behavior. State-history equivalence needs
explicit assumptions and does not describe execution timing or arbitrary external effects.
