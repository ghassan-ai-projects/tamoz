# Clean functions — quality bar

**Task:** refactor production Ruby so every function is short, does one thing, and reads top-down ·
**Owner:** Ghassan · **Size:** L · **Set:** 2026-10-03 (before the change)
**Governing rules:** `docs/CODING_STANDARD.md` §4 (methods ≤ 20 lines, cyclomatic/perceived ≤ 8),
`AGENTS.md` (simple over complicated; comments) · **Branch:** `code-improvement`
**Companion bar:** [`ARCHITECTURE_BAR.md`](ARCHITECTURE_BAR.md) · **Module analysis:** [`MODULE_MAP.md`](MODULE_MAP.md)

## 0. Outcome and fence

**Outcome:** every production method is at most 20 lines with cyclomatic and perceived complexity
at most 8, and no production file is excused from those cops in `.rubocop_todo.yml`.

Production Ruby is `gems/*/lib`, `gems/*.rb`, `apps/`, `bin/`, `script/`
(`docs/CODING_STANDARD.md` scope).

**The principles each refactored method is held to:**

1. The name states the intent.
2. It is short and does one thing.
3. It stays at one level of abstraction.
4. Public, top-level methods read like a small domain language.
5. Each method calls methods one level below it; the code steps down until what is left is small
   and concrete.
6. At most 20 lines (owner, 2026-10-03: keep the existing 20-line rule).

**Done when:** every row is PASS, the review log has no open critical or high finding, and the loop
log's last iteration changed nothing.

**Not in scope:** tests (owner, 2026-10-03: "no need to work on tests now") — test files are not
refactored; they run unchanged as the behavior proof. `Metrics/AbcSize` and
`Metrics/ParameterLists` are reported, not required. Cross-gem renames (see `MODULE_MAP.md` D1, D2).

**Owner decisions needed:** none for this bar.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | None — behavior-preserving extract-method refactors inside existing classes. |
| 1.2 | What already does this | RuboCop ceilings in `.rubocop.yml`; per-file debt in `.rubocop_todo.yml`. The bar adds no new tool: `metrics.rubocop.yml` here runs the same cops without the debt list. |
| 1.3 | Blast radius | Per method: private helpers only; public signatures unchanged (`test/public_api_test.rb`). |
| 1.4 | Baseline | enola baseline pinned 2026-10-03 at `c2887afa`. Known-red at HEAD listed under D. |

**Starting measure (HEAD `c2887afa`):** `Metrics/MethodLength` 306 · `CyclomaticComplexity` 176 ·
`PerceivedComplexity` 162 offenses in production Ruby (tracked only: `AbcSize` 360, `ParameterLists`
178).

## A. Safety — behavior preserved

| # | Property | Check | Status |
|---|---|---|---|
| A1 | No behavior change: every existing test passes unchanged | `rake ci` → `test_parallel … all passed`; test files untouched (`git diff --stat -- test/` empty) | OPEN |
| A2 | Durable bytes unchanged: checkpoints, journal keys, wire frames, prompt headers | pinned-digest tests inside `rake ci`; `rake ci_full` (both locales) after any round touching `tamoz-sqlite`, `tamoz-graph`, `tamoz-mcp`, or packaging | OPEN |
| A3 | No authority path is reordered: an extracted guard still runs before the effect it guards | reviewer reads each touched `enforce_*`/`verify_*`/effect method against HEAD | OPEN |
| A4 | Public surface unchanged | `test/public_api_test.rb` inside `rake ci`; `docs/public-api.json` not in the diff | OPEN |

## B. Function — the refactor delivers the outcome

| # | Property | Check | Status |
|---|---|---|---|
| B1 | No production method over 20 lines | `bundle exec rubocop -c docs/code-improvement-2026-10-03/metrics.rubocop.yml --only Metrics/MethodLength gems apps bin script` → 0 offenses | FAIL (306) |
| B2 | No production method over cyclomatic/perceived 8 | same command, `--only Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity` → 0 | FAIL (176 / 162) |
| B3 | The debt list excuses no production file for these cops | `awk '/^Metrics\/(MethodLength\|CyclomaticComplexity\|PerceivedComplexity):/,/^$/' .rubocop_todo.yml \| grep -E "'(gems\|apps\|bin\|script)"` → empty | FAIL |
| B4 | Principles 1–5 hold in every refactored method: intent names, one level of abstraction, top-level reads as domain language, step-down order | reviewer subagent per round; findings in the review log | OPEN |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Everyday gate | `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec rake ci` — all steps except the known-red one | OPEN |
| D2 | `rake ci_full`, both locales, after durability/MCP rounds | output | OPEN |
| D3 | RuboCop: no new offense of any cop in a touched file | `bundle exec rubocop <files>` vs `git show HEAD:<file>` | OPEN |
| D4 | enola: no new cycle, layer violation, or cross-gem coupling | `diff_snapshot` vs the pinned baseline; `rake quality:architecture` | OPEN |

**Known-red at HEAD `c2887afa`:**
- `stream:proto:check` — `grpc_tools_ruby_protoc` ships an x86_64 `protoc`; this arm64 machine has
  no Rosetta (`Errno::EBADARCH`). Environment, not code; every other `rake ci` step passed.
- `bundle exec rubocop` (whole repo) — 4,809 offenses in 156 files at HEAD (files never added to the
  debt list). This bar only requires no new offense in touched files and the B rows.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Extracted methods are private, named for intent; no new class created just to hold a split | review | OPEN |
| E2 | No shim, alias, or compatibility wrapper | diff review | OPEN |
| E3 | No new comments (`AGENTS.md` §Comments); a comment moves with the line it explains | review | OPEN |
| E4 | No scratch files; modes unchanged | `git status`, `git ls-files -s` | OPEN |
| E6 | No domain literal added to Ruby | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The report says these are refactors proven by the existing suite; no real-model run is claimed | report review | OPEN |
| F3 | No ADR changes: the 20-line rule already lives in `CODING_STANDARD.md`; no decided rule moves | `rake adr:validate adr:verify` | OPEN |
| F4 | Lessons recorded in `.agent/rules/` in the round that taught them | review | OPEN |

## Review log

| Round | Findings (C / H / M / L) | Resolution | Commit |
|---|---|---|---|

## Loop log

| Round | Date | What changed | B1 / B2 (MethodLength / Cyclo / Perceived) | Next |
|---|---|---|---|---|
| 0 | 2026-10-03 | Bars set, baseline pinned | 306 / 176 / 162 | smallest gems first |
