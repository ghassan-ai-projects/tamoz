# ADR-013 concepts guide — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and seam

Remove the twelve-concept target, require a maintained public concepts guide, and create
`documentation/concepts.md` with accurate definitions, when-needed guidance and relevant links.
Extend the existing docs index and overview introduction rather than duplicating its narrative.
Only ADR-013, its index/catalog/traceability/manifest title, the new guide, documentation README,
overview guide link and this record change. The existing manifest generator is reused unchanged.
No runtime/interface change. Owner requested commit on 2026-10-02; no push requested.

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | No numeric target; concept documentation/update rule and visible failure boundaries explicit | ADR diff and semantic review | PASS |
| B2 | Guide distinguishes agent/framework and operation concepts accurately | Current owning sources/ADRs and independent review | PASS |
| D1 | Links and ADR/citation/catalog/documentation valid | Existing focused validators/tests | PASS |
| E1 | Discoverable page, simple structure, scoped diff, mode/whitespace correct | Index/link and diff checks | PASS |
| F1 | No claims of learning proof, provider performance or full-CI success | Review and report | PASS |

Existing documentation tests cover links; no new test mirrors prose. No real-model or learning
study is claimed. Prior full-CI compiler limitation remains separate.

## Loop

1. Bar set before edits; all rows OPEN.
2. Removed the twelve-concept target, replaced budget wording with a plain title/rule, created the concepts guide, and linked the existing introductory page and docs index. Regenerated catalog, traceability and manifest title; generator logic unchanged.
3. Independent `review_adr013` found no critical/high issues. Corrected unknown-outcome wording to include retry-limit ambiguity and linked subagents to practical deep-research guidance plus accurately labeled authority rules.
4. Final self-review changed nothing. Final ADR/catalog/citation/link checks passed; all rows PASS.

## Results

- Final documentation test: 3 runs / 1,698 assertions. Requirements manifest test: 11 runs / 3,266 assertions. All passed.
- ADR validation: 59 records. Evidence verification: 441 citations. Catalog current. New files mode 644; whitespace passed.
- Independent reviewer checked interrupt/resume, routing values, request deduplication, child-authority narrowing, effect receipts and stops against enforcing sources/ADRs. No blocking gaps remained.
- No runtime, model-quality or learning-study evidence claimed. Full CI not rerun for prose; the prior compiler limitation remains. Historical audit verdicts unchanged; only the current manifest's ADR-013 title changed.
- No commit or push during the initial edit turn. Unrelated AGENTS.md, docs/README.md and docs/templates edits remain untouched.

## Lesson

A public-concept guide explains meaning and when concepts matter; an API inventory records names.
Neither a numeric target nor a passing inventory test proves that the product is easy to learn.

## Delivery

2026-10-02: owner requested commit. Fresh `precommit_adr013` review found no blocking findings.
Current ADR validation, evidence verification, catalog and documentation checks passed again;
whitespace passed. Commit scope is the ADR/concepts/index/derived-title package and this record.
No push requested. Unrelated AGENTS.md, docs/README.md and docs/templates edits excluded.
