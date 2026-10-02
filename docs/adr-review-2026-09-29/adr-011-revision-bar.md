# ADR-011 persistence clarification — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and seam

Explain SQLite persistence plainly while preserving the one-host/local-filesystem/operator
boundary, safety settings, immediate bounded transactions, fencing and online backup ownership.
Only ADR-011 and this record change. No runtime/interface change. Commit requested; no push.
Existing seams: SQLite ConnectionPool, adapter transaction kernel and Backup.

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | SQLite/default/deployment and safety rules preserved with plain explanations | Source and independent semantic review | PASS |
| B2 | No zero-operations, literal-single-file or physical power-loss-test claim | Diff review and existing transaction/backup tests | PASS |
| D1 | ADR, evidence, catalog and documentation valid | Existing validators and documentation test | PASS |
| E1 | Simple existing sections; no unrelated/code changes; mode/whitespace correct | Diff/status checks | PASS |
| F1 | Independent review before commit; evidence and limits recorded | Fresh reviewer and final report | PASS |

No new test mirrors prose. Existing tests check persistence mechanics; no real-model result or
physical power-loss test is claimed. Full CI retains the already proven compiler limitation.

## Loop

1. Bar set before edits; checks OPEN.
2. Rewrote the deployment and durability explanation, named the three settings plainly, and removed zero-ops and literal-single-file claims.
3. Fresh independent `precommit_adr011` reviewer found no blocking issues and confirmed the owning seams. Final self-review changed nothing; all rows PASS.

## Results and delivery

- Backup tests: 3 runs / 16 assertions. Transaction fault test: 1 run / 42 assertions. All passed; in-process fault checks, not physical power-loss evidence.
- ADR validator: 59 records; evidence verifier: 441 citations; catalog current. Documentation: 3 runs / 1,649 assertions. All passed. Metadata and sections unchanged; catalog regeneration unnecessary.
- Only ADR-011 and this record change in the package; new record mode 644 and whitespace passed. No runtime or real-model result claimed. Full CI was not rerun for this prose change; prior compiler limitation remains.
- Owner authorized commit; fresh review completed before commit. No push requested. Pre-existing AGENTS.md, docs/README.md and docs/templates changes excluded.

## Lesson

A local database removes the database-server dependency, not backup and recovery responsibilities.
Describe the logical database separately from WAL files and operator configuration.
