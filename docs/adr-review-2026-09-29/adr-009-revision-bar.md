# ADR-009 clarity revision — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and seam

Explain stable request prefixes with the requested example, distinguish local consistency from
provider cache outcomes, and preserve accepted intent while identifying incomplete implementation.
The existing seams are RequestHeader, Series, WorkContext and WorkCompaction. Prose/catalog only;
no runtime, interface, authority or structural change. No commit or push requested this turn.

## Checks

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Plain example and request-series definition; no cache-hit guarantee | Source and semantic review | PASS |
| B2 | Header scope, skill link and history boundaries accurately distinguished from accepted intent | Source inspection, header/work-loop tests and independent review | PASS |
| D1 | ADR, evidence, catalog and documentation valid | Existing validators and documentation test | PASS |
| E1 | Simple sections, scoped diff, mode 644 and no compatibility/code changes | Diff/status/whitespace check | PASS |
| F1 | Gaps marked Partial; no real-provider or full-CI claim | Independent review and results record | PASS |

Existing tests check mechanics; no new test mirrors prose. Full CI retains the previously proven
protoc architecture limitation. No real-model or provider-cache measurement is claimed.

## Loop

1. Bar set before edits; all rows OPEN.
2. Added request-series definition and example, removed unsupported cache-miss attribution, corrected the skill relationship, and marked implementation gaps Partial. The first validator run required a gap summary in Partial metadata; this was fixed and the catalog regenerated.
3. Independent `review_adr009` confirmed the gaps and no blocking findings. Applied its two clarity suggestions: label the example simplified and identify invariant 16 as the rule rather than completed enforcement.
4. Final self-review changed nothing. All rows PASS; final validators, catalog and documentation checks passed.

## Results

- Header tests: 9 runs / 21 assertions; append-only request test: 1 run / 2 assertions. All passed. These are deterministic plumbing checks, not provider-cache measurements.
- Final ADR validator: 59 records; evidence verifier: 441 citations; catalog current; documentation test: 3 runs / 1,649 assertions. All passed.
- Diff scope: ADR-009, its derived catalog entry and this record. New record mode 644; whitespace passed. Existing unrelated AGENTS.md, docs/README.md and docs/templates changes remain untouched.
- No runtime change, commit, push or real-model run. The previously established full-CI compiler limitation remains; full CI was not rerun for this prose revision.

## Lesson

A digest proves only the fields included in it. Stable local request content supports caching;
it does not explain every provider cache outcome.

## Delivery

2026-10-02: owner requested commit. Fresh `precommit_adr009` reviewer found no blocking findings.
ADR validation, evidence verification, catalog and documentation checks passed again; whitespace
passed. Commit scope is ADR-009, its catalog entry and this record. No push requested.
