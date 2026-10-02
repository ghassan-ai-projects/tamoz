# ADR-010 retirement — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and seam

Withdraw ADR-010 as requested, preserving its number and historical meaning in the retired folder.
Keep Ruby specifications, development pin, CI and runtime untouched. Update the existing catalog,
index, retirement ledger, traceability and requirements manifest together. Remove only the retired
ADR evidence mapping from the existing manifest generator; its generation logic stays unchanged. No commit or push requested for this change.

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Number/history retained; old active path absent; no successor invented | Tombstone, ledger, reference and diff review | PASS |
| B2 | Existing nested discovery and traceability handle retirement | ADR tooling tests and regenerated views | PASS |
| D1 | ADR/citation/catalog and documentation checks pass | Existing focused gates | PASS |
| E1 | Only retirement docs and generator evidence mapping; no runtime/CI/version change | Diff/status/mode/whitespace review | PASS |
| F1 | Report does not claim runtime or full-CI proof | Results review | PASS |

## Loop

1. Bar set before edits; checks OPEN.
2. Retired the record and updated catalog/index/ledger/traceability. Validator caught the missing retired index entry, then documentation and manifest tests caught stale consumers; fixed each before completion.
3. Removed only ADR-010's manifest evidence mapping and regenerated the manifest. Pruned its historical audit row and adjusted counts, preserving execution date, remaining verdicts and historical case count; explicitly documented that the full audit was not rerun.
4. Final self-review changed nothing. All rows PASS. A fresh independent reviewer remains required before any later commit.

## Results

- ADR tooling: 18 runs / 71 assertions. Documentation: 3 runs / 1,649 assertions. Manifest: 11 runs / 3,266 assertions. All passed.
- ADR validator: 59 records, next number 60. Evidence verifier: 441 citations. Catalog current. No Ruby-version, CI, gemspec or runtime change.
- Generator lint: one existing redundant-sort offense, also present in the HEAD copy; no new offense. First lint attempt could not write its cache; reran with cache disabled. Whitespace passed; new records mode 644.
- Full CI and full requirements audit not rerun. No real-model or runtime evidence claimed. Unrelated AGENTS.md, docs/README.md and docs/templates edits remain untouched. No commit or push.

## Lesson

Retiring a version-policy ADR does not change version requirements. Preserve the record and keep
operational constraints in their existing executable configuration.

## Delivery

2026-10-02: owner requested commit. Fresh `precommit_adr010` review passed with no blocking
findings. Corrected E1 to name the generator evidence-mapping deletion. Validator, verifier,
catalog and manifest checks passed again; whitespace passed. Commit only the retirement package;
pre-existing AGENTS.md, docs/README.md and docs/templates changes stay excluded. No push requested.
