# ADR-006 clarification — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and fence

ADR-006 explains Hash state, declared keys and explicit named/versioned reducers, with accurate
conflict and validation limits. Remove the framework comparison; relocate the existing keyword
configuration rule to the coding standard without changing it. Scope: ADR-006, coding standard,
and this record. No runtime/interface change, no commit requested.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | State and merge decision preserved; context self-contained | Source/diff review | PASS |
| B2 | Named/versioned reducers, single writes, conflict refusal and runtime limits accurate | Existing reducer/state/execution tests and source inspection | PASS |
| B3 | Keyword-argument rule preserved outside the state ADR | Coding-standard diff | PASS |
| D1 | Structure, citations, catalog and documentation pass | Existing ADR commands and documentation test | PASS |
| E1 | Concise existing sections; no unrelated changes | Diff/whitespace/mode checks | PASS |
| F1 | Independent semantic review; results scoped honestly | Fresh reviewer and report | PASS |

The change is prose only. Existing deterministic tests support the mechanics, not agent reasoning;
no new test mirrors the wording. Full CI retains its established baseline compiler limitation.

## Review and loop

1. Bar set before edits; checks OPEN.
2. Clarified representation, reducer metadata and validation limits; relocated configuration convention to coding standard. Checks passed.
3. Fresh `review_adr006` reviewer found the existing example used a nonexistent `message_events` reducer. Replaced it with `state :events, default: [], reduce: Tamoz::Reducers.append`; reran document checks. Re-review: no remaining actionable findings.
4. Final self-review required no changes; all rows PASS.

## Results

- Reducer tests: 4 runs / 111 assertions. State-manager tests: 4 runs / 16 assertions. Execution conflict test: 1 run / 5 assertions. All passed.
- Documentation: 3 runs / 1,649 assertions. Validator: 59 records. Citation verifier: 441 citations. Catalog check current. Rerun after example repair passed.
- Source inspection confirmed reducer name/version enforcement, declared-key validation, single-write replacement and pre-commit conflict refusal.
- Existing method-configuration convention retained in coding standard. Metadata and accepted state semantics preserved. Only the three scoped Markdown files changed in this task; no runtime change or real-model claim.
- New record mode 644 and whitespace checks passed. No commit requested.

## Lesson

State representation and merge semantics belong together. Method-configuration conventions belong
in the coding standard, without being silently dropped when the state ADR is clarified.

## Delivery

2026-10-02: owner requested commit. Fresh pre-commit reviewer `precommit_adr006` confirmed no actionable findings. Current ADR/citation/catalog/documentation checks and whitespace check passed. Commit scope is ADR-006, the coding-standard rule relocation and this record; no push requested.
