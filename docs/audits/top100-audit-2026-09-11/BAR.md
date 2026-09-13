# Top-100 audit — 2026-09-11 — the bar

Scope: the 100 largest hand-maintained Ruby files in the repo (`gems/*/lib`, `test/`,
`apps/`, `bin/`, `script*/`), ranked by line count on 2026-09-11. Generated/fixture/schema
files are classified per `docs/CODE_QUALITY.md`, not held to the production standard.

Every file is checked against every applicable row. No file is exempt by reputation.

| ID | Row | Fail means |
|---|---|---|
| SIZE | Size & complexity | File >~250 lines AND mixing responsibilities (growth is a signal to extract, §2). Method >30 lines, >5 params, boolean params, nesting >3, cyclomatic >8. |
| PLACE | Placement & responsibility | Policy + persistence + orchestration + rendering mixed; runtime concern in CLI/entry files; a feature a caller could build from existing public API (§6.2). |
| DUP | Duplication & vocabulary | Copy-paste blocks; a second spelling for an existing concept (§3.1: render_/parse_, encode_/decode_, validate_/verify_/assert_/enforce_, build_/normalize_/resolve_, with_\* yields). |
| DEAD | Dead code & speculative generality | Unused methods/constants/branches (grep-proven); abstraction with one consumer and no isolated responsibility; banned shapes (Service/Manager/Utils, DI containers, metaprogrammed registries). |
| STATE | Values & state | String-keyed hashes where immutable `Data.define` values belong; hidden globals/memoized constants; mutable default args; bare `@ivar` exposure to collaborators. |
| ERR | Errors & contracts | Swallowed errors; `rescue Exception` that continues; domain error raised far from its boundary; error identity drift. |
| B9 | Domain knowledge is data | Catalogs, operator prompts, intent types, risk classes, compensation maps, watch rules, fixture responses as Ruby literals. Must be `test/fixtures/domains/*.json` via `DomainLoader`. Declarative data corpora in `test/support` pass as data only if they carry no policy/logic. |
| FX | Effects & durability | Raw model/tool call inside a graph node bypassing `EffectDispatcher.run` / `SessionEffects#model_call`; byte-level contract (digest/wire) fragile under edit. |
| AUTH | Authority & approval | Hardcoded verdict/approval/bypass outside `gems/tamoz-approval/policy/*.yaml`. |
| NAME | Naming | Predicate without `?`, `get_`/`set_`, `with_*` that does not yield, misleading name. |
| DOC | Comments & docs | Narration comments restating code; public class/method without contract; doc claim contradicted by the code. |
| TEST | Tests only (§9) | Probing private implementation; failure paths missing; subprocess tests dependent on ambient gem home; real LLM in tests; setups that bury the behavior under test. A long test file is not itself a violation if the cases are genuine. |

## Severity

- **critical** — a defect or an invariant/boundary violation (B9, FX, AUTH, ERR).
- **major** — refactor warranted (misplacement, duplication, size with mixed responsibility, dead surface).
- **minor** — polish (naming, comment noise, doc gap).

## Verdict

`IMPROVE` if ≥1 critical/major, or ≥3 minor. Otherwise `PASS` (minors still listed).

## Rules of evidence

- Every finding cites `file:line`. Dead-code claims carry grep proof.
- No speculative findings, no style nitpicks outside the bar, no padding.
- Findings name the issue and the seam that should own it — not a rewrite plan.
- Audit files are written only for `IMPROVE` files; `PASS` files live only in `INDEX.md`.

## Resume protocol

`INDEX.md` is the single source of truth: one row per file, checkbox unticked until the
file's verdict is recorded (audit doc linked for `IMPROVE`). A fresh agent resumes by
auditing the first unticked row's file against this bar.
