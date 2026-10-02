# ADR-005 clarification — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and seam

ADR-005 explains Tamoz's pause mechanism without naming LangGraph, separates pause signals from
errors, and scopes its guarantees to ordinary exception handlers and one worker's task. Preserve
the accepted throw/catch mechanism and describe supplied resume values accurately. Only ADR-005
and this review record change; no runtime or interface change, no commit requested.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Context is self-contained; accepted mechanism and metadata preserved | Source and diff review | PASS |
| B2 | Resume, worker-local catch, typed result and interception limit are accurate | Source review and focused existing tests | PASS |
| D1 | ADR/citation/catalog and documentation checks pass | Existing validators and documentation test | PASS |
| E1 | Concise Context/Decision/Consequences only; no unrelated edits | Diff, whitespace and mode checks | PASS |
| F1 | Fresh semantic review and honest validation report | Independent reviewer | PASS |

No new test mirrors this prose edit. Existing deterministic pool/cursor checks support the named
mechanism; they are not real-model evidence. Full CI's previously established protocol-compiler
limitation remains; no runtime readiness claim is made.

## Review and loop

1. Bar set before edits; checks OPEN.
2. Rewrote only ADR-005's rationale, mechanism description and limits; all checks passed.
3. Fresh `review_adr005` reviewer found no actionable findings. Final self-review required no changes; all rows PASS.

## Results

- Focused pool tests: 2 runs / 10 assertions. Cursor test: 1 run / 4 assertions. Documentation: 3 runs / 1,649 assertions. All passed.
- Validator: 59 records. Citation verifier: 441 citations. Catalog check current; regeneration unnecessary because catalog metadata/sections did not change.
- Source inspection confirmed cursor resume handling and worker-local catch. Reviewer read the diff and both enforcement seams; no issues at any severity.
- Only the ADR and this review record changed in this task. New record mode 644 and whitespace checks passed; pre-existing changes remain untouched. No commit or runtime change.

## Lesson

A pause signal is distinct from an execution error. Describe that control-flow property without
promising isolation from application code or relying on another framework's design.

## Delivery

2026-10-02: owner requested commit. Fresh pre-commit reviewer `precommit_adr005` confirmed no actionable findings. ADR structure/citation/catalog checks passed again; whitespace check passed. Commit scope remains ADR-005 and this record; no push requested.
