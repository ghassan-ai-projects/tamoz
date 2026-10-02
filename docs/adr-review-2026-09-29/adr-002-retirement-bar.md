# ADR-002 retired-folder move — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and seam

Move only ADR-002 into `documentation/adr/retired/`, keeping its history, successor and number.
Update existing catalog discovery, validation, traceability and documentation consumers atomically.
No alias at the old location. Other retired ADRs stay where they are for this change. Commit requested;
push is not requested in this turn. Pre-existing AGENTS.md, docs/README.md and template edits remain local.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Nested retirement remains numbered, indexed and reciprocal | Discriminating tooling test | PASS |
| B2 | Broken links inside retired folder are caught | Tooling negative test | PASS |
| B3 | ADR-002 moved without changing accepted history; no old-path alias | Diff and reference scan | PASS |
| D1 | Catalog, citations, docs and manifest valid | Existing focused checks | PASS |
| D2 | No new lint offenses or structural regressions | RuboCop against HEAD, enola diff | PASS |
| E1 | Existing discovery seam extended; no parallel catalog | Diff review | PASS |
| E2 | Authorized files only; modes and whitespace correct | Status/diff check | PASS |
| F1 | Independent review before commit; results and limits recorded | Fresh reviewer and report | PASS |

Known full-CI limitation: installed protoc fails EBADARCH, reproduced at unchanged HEAD in the preceding package. Focused document/tooling checks cover this migration; no runtime/model result is claimed.

## Review and loop

1. Bar set before edits; checks OPEN.
2. Nested-record regression failed before discovery changed (expected two records, found one). Updated discovery/links and fixed the fixture index to handle nested names; all focused checks passed.
3. Fresh `review_retired_move` reviewer found no actionable issues at any severity. Final self-review required no changes; all listed rows PASS. Full CI is separately BLOCKED by the known compiler limitation, not counted as green.

## Results

- Tooling tests: 18 runs / 71 assertions. Documentation: 3 runs / 1,649 assertions. Manifest: 11 runs / 3,279 assertions. All passed.
- Validator: 59 records; next number 60. Citation verifier: 441 citations. Catalog current; derived views regenerated.
- Changed catalog/validator/tooling/documentation-test Ruby files: zero lint offenses. Traceability script: 52 current versus 54 at HEAD; no new offense (shared discovery removed two existing offenses).
- Enola snapshot diff: no new findings. Extractor is v0.4.25; v0.4.26 is available, no upgrade performed.
- `rake ci`: fast test files passed; blocked at `stream:proto:check` by the already established baseline EBADARCH protocol compiler failure. No runtime or real-model claim.
- Retired file mode 644; old path absent; whitespace check passed. Unrelated working-tree files remain outside the commit.
- Commit authorized by the owner; no push requested.

## Lesson

Moving a retired decision changes its path, not its identity. Catalog discovery and reciprocal links must follow it in the same commit.
