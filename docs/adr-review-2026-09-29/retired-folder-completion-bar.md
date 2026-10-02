# Retired ADR folder completion — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and fence

All retired decisions live in `documentation/adr/retired/`; active and proposed decisions remain
in the main ADR folder. Move the remaining seven tombstones without changing their identity,
history or successor. Update incoming and relative links and regenerate the catalog in the same
commit. Existing nested discovery already supports this layout; no code changes or new tests
are needed. Commit requested, no push requested. Pre-existing guidance/template edits stay local.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Eight retired records in retired folder; none in main folder; identities retained | Catalog/source comparison before and after | PASS |
| B2 | Links and reciprocal relationships follow the moves; no old-path aliases | ADR validator and documentation tests | PASS |
| D1 | Nested discovery, catalog, citations and manifest remain correct | Existing tooling, manifest tests and catalog check | PASS |
| E1 | Only tombstone/link/generated-view changes; no new machinery | Diff review and whitespace/mode checks | PASS |
| F1 | Fresh review before commit; truthful report of checks | Independent reviewer and record | PASS |

Full CI has the established baseline protoc EBADARCH limitation. This documentation-only move uses
focused document/tooling checks; it changes no runtime behavior and makes no real-model claim.

## Review and loop

1. Bar set before edits; checks OPEN.
2. Moved seven tombstones and updated links; catalog/source comparison and all focused gates passed.
3. Fresh `review_all_retired_move` reviewer found no actionable findings. Final self-review required no changes; all rows PASS.

## Results

- Source/catalog comparison: eight retired records in the retired folder, none retired in the main folder; active/proposed records stay in the main folder. All seven moved records are unchanged apart from links. Modes 644, old paths absent.
- ADR validation: 59 records, next number 60. Citation verifier: 441 citations. Catalog check current.
- Documentation tests: 3 runs / 1,649 assertions. Tooling: 18 runs / 71 assertions. Manifest: 11 runs / 3,279 assertions. All passed.
- No Ruby or runtime change; no additional lint/architecture/full-runtime run needed for this path-only documentation migration. The previously established full-CI compiler limitation remains unresolved.
- Whitespace passed; no real-model claim. Independent review was read-only; no issues at any severity. Commit authorized; push not requested.

## Lesson

An archive directory separates current rules from historical decisions while keeping numbers and
supersession links intact.
