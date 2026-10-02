# ADR-014 extension clarification — quality bar

**Owner:** Codex · **Size:** S · **Set:** 2026-10-02, before edits

## Outcome and seam

Explain skills, external MCP tools and released in-process adapters plainly. Distinguish writing
code with existing approved tools from loading/registering it as a runtime extension. Preserve
current authority/contract rules and third-party admission conditions; no future mechanism built.
Only ADR-014 and this record change. No runtime/interface change. Owner authorized commit, push
and PR delivery on 2026-10-02.
Existing seams: sealed Capability::Registry, Toolbox create/patch/check operations, MCP admission.

| Row | Property | Check | Status |
|---|---|---|---|
| B1 | Skills/MCP/adapters, release path and no automatic runtime registration clear | Owning-source and semantic review | PASS |
| B2 | Code-writing capability distinguished from authority; host isolation claims scoped | Existing closed-world/tool tests and independent review | PASS |
| D1 | ADR/citation/catalog/documentation valid | Existing focused checks | PASS |
| E1 | Simple existing Tier F sections; scoped diff, mode/whitespace correct | Diff/status review | PASS |
| F1 | Accepted safety intent and future admission bar preserved; no model/full-CI claim | Independent review and results record | PASS |

No new test mirrors prose. Existing tests cover mechanisms, not a real-model code-generation
result. Full CI retains the previously proven compiler limitation.

## Loop

1. Bar set before edits; checks OPEN.
2. Rewrote skill/MCP/adapter paths, added the code-writing example, scoped process/credential claims and removed the blanket contract-gem-release cost.
3. Fresh `review_adr014` reviewer found no blocking findings. Applied its optional current-turn wording to match catalog epochs. Final self-review required no further changes; all rows PASS.

## Results

- Closed capability tests: 3 runs / 14 assertions. Focused approved patch and configured-check tests: 2 runs / 22 assertions. All passed; deterministic mechanics, not real-model code-generation evidence.
- ADR validator: 59 records; evidence verifier: 441 citations; catalog current. Documentation: 3 runs / 1,698 assertions. All passed.
- Independent review confirmed registry, Toolbox, inert skills and ADR-030 consistency. No third-party or generated-code activation mechanism implemented; current safety intent retained.
- Only ADR-014 and this record belong to the change. Metadata and sections unchanged; no catalog regeneration needed. New record mode 644, whitespace passed. No runtime/interface change during the edit turn; unrelated local files untouched.
- Full CI not rerun for prose; the previously proven compiler limitation remains. No real-model result claimed.

## Lesson

Writing code does not enable a runtime extension. An external process boundary separates memory
spaces but does not itself limit that process's filesystem, network or credential access.

## Delivery

2026-10-02: owner authorized commit, push and PR. Fresh `precommit_adr014` review passed with no
blocking findings. ADR validation, evidence verification, catalog and documentation checks passed
again; whitespace passed. Commit scope is ADR-014 and this record. Existing PR #64 already tracks
the branch, so delivery updates that PR rather than creating a duplicate. Unrelated AGENTS.md,
docs/README.md and docs/templates edits are excluded.
