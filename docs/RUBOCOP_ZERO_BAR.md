# RuboCop zero — quality bar

**Task:** Reduce whole-repo `bundle exec rubocop` offenses toward zero through real fixes · **Owner:** ghassan · **Size:** L · **Set:** 2026-11-04 (before the change)
**Plan:** four packages in order — (1) safe autocorrect, (2) unsafe corrections read one by one, (3) manual non-Metrics offenses, (4) `Metrics/*` table for the owner (no refactor without the owner) · **Governing ADRs / invariants:** none loosened; `docs/CODING_STANDARD.md` §1 · **Branch:** ft/rubocop-zero-85e1d9 (base `0a2e485e` = origin/main)

Status values: `PASS` (evidence named) · `FAIL` · `OPEN` · `BLOCKED` · `WAIVED` (owner only).

**Measure command:** `bundle exec rubocop --config .rubocop.yml` — the explicit `--config` is required in this worktree: without it RuboCop merges the parent checkout's `AllCops/Exclude` (`.claude/**/*`) and inspects 0 files.
**Start (measured here at `0a2e485e`):** 4599 offenses, 1392 files inspected, 3724 autocorrectable.

## 0. Outcome and fence

**Outcome:** the RuboCop summary line is lower than 4599 for every package, with every correction behavior-preserving and every gate below unchanged from HEAD; zero is claimed only if RuboCop prints it.

**Done when:** every row is PASS (or WAIVED by the owner), the review log has no open critical or high finding, and the last loop iteration changed nothing.

**Not in scope:** adding RuboCop to CI; `.rubocop_todo.yml` additions; limit raises in `.rubocop.yml`; cop disables without a site reason; weakening tests; generated files (`gen/`); `AGENTS.md` and branch `agents-md-optimize`; untracked `PROFILE.md`, `outreach/`; `Metrics/*` refactors until the owner decides; public-method renames (`Naming/PredicateMethod`) until the owner approves.

**Owner decisions needed:** Metrics scope (step 4); any cross-gem rename.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | RuboCop config as committed (`.rubocop.yml`, `.rubocop_todo.yml`); no new code path. |
| 1.2 | What already does part of this | The `rubocop -a` workflow in `AGENTS.md`; the todo file records debt per file. |
| 1.3 | Blast radius | Source-text digests and packaging inputs: `test/packaging_test.rb`, `script/capture_phase2_receipt`, `script/generate_requirements_manifest`, `.agent/rules/testing.md`. Checked per package by running those tests. |
| 1.4 | Baseline / known-red at HEAD | Known-red: `stream:proto:check` (`Errno::EBADARCH`) — proven by running it; other reds proven in a detached worktree of `0a2e485e`. |

## A. Safety and authority

| # | Property | Check | Status |
|---|---|---|---|
| A1 | No behavior change from autocorrect | Package 1 gates + digest/packaging tests green; `git diff --stat` reviewed by a fresh subagent | OPEN |
| A2 | No unsafe correction applied in bulk; each read | Package 2 diff review lists every one | OPEN |
| A3 | No gem boundary, effect-journal, policy or approval code changed except by syntax-neutral corrections | diff review of `gems/*/lib` hunks | OPEN |
| A4 | No pinned wire digest / `BENCHMARK_PROTOCOL.json` change | `git diff --stat` shows neither file; digest tests green | OPEN |

## B. Function

Plumbing evidence only (no model involved).

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Every test file that passed at HEAD passes after each package | `rake test_fast` (and `ci_full` below) | OPEN |
| B2 | Scripts with tests still run | their tests under `test/` | OPEN |
| B3 | Test names that feed `script/generate_requirements_manifest` unchanged | `git diff` grep for renamed `def test_` | OPEN |
| B4 | Generated/manifest outputs unchanged | `script/generate_requirements_manifest --check` if present; requirements tests | OPEN |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched tests that rely on source text (digest, packaging, source audit) | `ruby -Itest test/<file>.rb`, one per command | OPEN |
| D2 | `bundle exec rake design:validate adr:validate adr:verify syntax test_fast quality:architecture` | output | OPEN |
| D3 | `rake ci_full` in `LANG=C LC_ALL=C` and `en_US.UTF-8`, background | output | OPEN |
| D4 | RuboCop summary line recorded after each package | `bundle exec rubocop --config .rubocop.yml` | OPEN |
| D5 | enola `diff_snapshot` vs baseline: no new cycle/layer/coupling | enola output | OPEN |
| D6 | `.rubocop.yml` / `.rubocop_todo.yml` only lose or keep entries, never gain | `git diff origin/main -- .rubocop.yml .rubocop_todo.yml` | OPEN |

**Known-red at HEAD:** `stream:proto:check` — x86-only grpc-tools on this Mac — `Errno::EBADARCH` expected.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest fix per offense; no new machinery | review | OPEN |
| E2 | No shim or alias (ADR-059) | diff review | OPEN |
| E3 | No new comments; an inline `rubocop:disable` has a site reason | `git diff | grep rubocop:disable` | OPEN |
| E4 | File modes unchanged; no scratch files | `git diff --summary`, `git status` | OPEN |
| E6 | No domain literal moved into Ruby (ADR-058) | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Report lists remaining offenses by cop with the exact RuboCop summary line; zero claimed only if printed | report | OPEN |
| F2 | `docs/CODING_STANDARD.md` §1 / docs unchanged unless a fact in them became false | review | OPEN |
| F3 | ADRs untouched or still true (`rake adr:validate adr:verify`) | tooling | OPEN |
| F4 | Every process started has stopped | `pgrep -fl` | OPEN |

## Review log

| Package | Findings (critical / high / medium / low) | Resolution | Commit |
|---|---|---|---|
| | | | |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 1 | 2026-11-04 | bar written | — | all | package 1 |
