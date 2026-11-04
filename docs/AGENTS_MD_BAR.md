# AGENTS.md optimization — quality bar

**Task:** make `AGENTS.md` smaller, truer and easier to act on, without losing a rule · **Owner:** Ghassan · **Size:** M · **Set:** 2026-11-04 (before the change)
**Plan:** this file · **Governing ADRs / invariants:** ADR-052 (it cites this file), `.agent/rules/adr.md` · **Branch:** `agents-md-optimize`

Status values: `PASS` (evidence named) · `FAIL` (what is wrong) · `OPEN` (not built) ·
`BLOCKED` (cannot be done here; reason named; never counted as a pass) · `WAIVED` (owner decision,
named and dated; never by the author).

## 0. Outcome and fence

**Outcome (one sentence):** every line of `AGENTS.md` is an owner rule, applies to most tasks, or routes to where
the detail lives, every command and name in it is true at HEAD, and no owner rule is lost or weakened.

**Done when:** every row below is PASS (or WAIVED by the owner), the three-lens review has no open critical
or high finding and all three approve, and the loop log's last iteration changed nothing.

**Not in scope:** changing any owner rule's meaning, except G6 and G7; hooks, CI or new gates (see Future plan).

**Owner decisions needed:** none open; see "Owner instruction".

## 1. Seam — understand before you build

| # | Question | Answer |
|---|---|---|
| 1.1 | Which seam does this extend? | `AGENTS.md`; `.agent/rules/*` as the home for detail; `test/` for one guard |
| 1.2 | What already does part of this? | `documentation_tree_test` checks links, but its `ROOT_MD` omits `AGENTS.md` by design: that test also bans internal paths in public docs |
| 1.3 | Blast radius | Read by `tamoz code --guidance` (`Harness::Instructions`, cut at 16,384 bytes) and by every agent; cited by `quality-bar-template.md` E3/F4, ADR-052, `domain_loader.rb`, `benchmark_families.rb`; none depends on a section name |
| 1.4 | Baseline, known-red | `set_baseline` pinned on this branch; known-red below |

## Anthropic's guidance applied (read 2026-11-04)

| Guidance | Source | What it changed here |
|---|---|---|
| Target under 200 lines; longer files cost context and adherence | [memory](https://code.claude.com/docs/en/memory.md) | Budget pinned in a test |
| Keep a line only if the agent could not find it, or would not look; exclude layout overviews | [best practices](https://code.claude.com/docs/en/best-practices.md) | Attachment detail and enola prose moved or cut |
| Keep exact commands; a pass/fail command is the most useful line | best practices | Commands moved to the top, each one run |
| Instructions are advisory; what must always hold belongs in a hook or deny rule | memory | Future plan, not built |
| Imports do not save context; rules with `paths:` do | memory | `.claude/` is gitignored and Claude-only, so a routing table does this for every agent |
| AGENTS.md is read natively from v2.1.277 when no CLAUDE.md or CLAUDE.local.md exists | memory | No `CLAUDE.md` bridge added |
| Emphasis tends to make an agent over-apply a rule | best practices | No new emphasis; owner-date stamps dropped |
| Nearest nested AGENTS.md wins | [agents.md](https://agents.md) | Not adopted: rules follow subjects that cross gems |

## A. Safety and authority

| # | Property | Check | Status |
|---|---|---|---|
| A1 | Every owner rule keeps its meaning; none is weaker | Disposition table below; reviewer 1 compares old and new line by line | PASS — reviewer 1, rounds 1–6 |
| A2 | The attachment privacy rule stays where it cannot be missed | One line in Owner rules, detail in `channels.md` | PASS — owner rule plus ADR-064; reviewer 1 |
| A3 | Nothing newly promoted loosens authority | Additions table below; reviewer 1 | PASS — reviewer 1; the additions tighten or correct |

### Disposition of the old file

| Old section | Now |
|---|---|
| Intro, read-this table | Intro kept; table became a trigger-keyed routing table |
| Quality bar loop 1–4 | Kept, shortened; "Report in plain terms" merged into step 4 |
| All owner rules | Kept with their ADRs and seams, grouped; dates dropped |
| Clean house, record a lesson | Kept |
| Tests, lint, gates | Became Commands and Gates; bare `enola check` replaced |
| Channel attachments | Privacy rule stays as an owner rule; the rest moved to `.agent/rules/channels.md`; the eval rule generalized |
| Comments | Kept, condensed |
| enola block | Condensed inside its markers; the claim that a hook is installed became conditional |

### Additions (promoted from elsewhere or generalized)

| Line | Source |
|---|---|
| This file wins over guides; a conflict with an ADR, invariant or policy goes to the owner | New; owner instruction |
| Lint leftovers go to a small-model subagent | Owner, 2026-10-10 (Claude memory only until now) |
| Medium and low edge cases are noted, not built | Owner, 2026-10-10 (Claude memory only until now) |
| Second homes for a migration, ADR, verb, API entry, renamed test | `.agent/rules/testing.md`; PR #73 and migration 24 |
| Migrations named under `ci_full` | Same evidence |
| Stop what you started | Owner's global file, Claude-only until now |
| `.env`: mixed format, only some scripts read it, never print | A 2026-09-26 eval lost 232 episodes to this |
| Graph-node version bump in `subgraphs.md`, routed from the table | ADR-019 and template E5, which S bars can skip |
| `rake` stops at the first red prerequisite | `Rakefile:546`: a red `stream:proto:check` skips enola |
| Generalized real-model eval rule, under Working practice | The Telegram rule, which stays hard in `channels.md`; owner instruction |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Every command in the file runs as written | Each run this iteration; see loop log | PASS with limits — `ruby -Itest`, `rubocop -a`, `rake ci` gates and `ci_full` ran; the last two did not finish green, see D2 and D3 |
| B2 | Every path, link and named class exists | `test/agents_md_test.rb`; mutations: a bad link and a bad seam must each go red | PASS — `agents_md_test` 3 runs, 0 failures; five mutations each went red earlier in this change; the test has not changed since |
| B3 | Smaller by a measurable amount, tail not at risk | `wc` before (155 lines, 10,612 bytes) and after, on the final text; `Instructions` cuts at 16,384 bytes | PASS — 155 → 124 lines, 10,612 → 9,282 bytes, under the 16,384-byte cut |
| B4 | A fresh agent can find the right rule for a real task | Reviewer 2 walks five tasks through the file | PASS — reviewer 2 |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `agents_md_test`, `documentation_test`, `documentation_tree_test`, `harness_instructions_test` | PASS — `agents_md`, `documentation`, `documentation_tree`, `harness_instructions`, `requirements_manifest`, all in a clean worktree; `documentation_test` fails in the main checkout only on the owner's untracked `outreach/` |
| D2 | Everyday gate | `rake ci` gates by name, `rubocop`; see known-red | PASS — `rake ci` exit 0 on commit `144ed439` in a clean worktree, 37.4s at load average about 6, with the enola baseline pinned at `origin/main`. Earlier failures came at load average 48–90 from other work on this Mac |
| D3 | `ci_full` | Required: committed evidence regenerated and ADRs added; both locales | BLOCKED by known-red at HEAD — UTF-8 on `144ed439`: `test` lane 3,468 runs, 0 failures; 44 of 45 slow and serial files pass; `benchmark_holdout_test` fails identically at clean HEAD and stops `rake`, so the rest were run by name. `m2_evidence_test` needs `bundle exec`, also at `origin/main`. `LANG=C`, not re-run on the commit: 18 errors in Talk and rule-promotion tests on near-final text, identical at clean HEAD, so its slow lane never ran |
| D4 | RuboCop autocorrect on touched Ruby | `bundle exec rubocop -a test/agents_md_test.rb` | PASS — touched Ruby: no offenses |
| D5 | enola | `diff_snapshot` against 1.4 | PASS — MCP `diff_snapshot` (0.4.25): 0 regressions. The `proto-check-arm64` session started from this one upgraded the CLI to 0.4.39, so `enola check` declined the old baseline (exit 3); re-pinned on the changed tree, so the CLI gate grades nothing about this change |

**Known-red at HEAD (proven in a detached worktree, 2026-11-04):** `benchmark_holdout_test` under UTF-8 (protocol SHA pin); 18 errors under `LANG=C` in `talk_checks`, `talk_eval_controls`, `talk_fixtures`, `rule_promotion_authority`. `stream:proto:check` was red earlier for lack of Rosetta; it passes on this commit.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | The simplest design; the one new test earns its place | Reviewer 3 | PASS — reviewer 3 |
| E2 | No shim or alias | Diff | PASS — diff |
| E3 | Comments per `AGENTS.md` | Diff | PASS — one-line class doc only |
| E4 | Modes 644; no scratch files; `PROFILE.md` and `outreach/` untouched | `git ls-files -s`, `git status` | PASS — modes 644; `PROFILE.md` and `outreach/` untouched |
| E5 | No new gem | Diff | PASS — diff |
| E6 | No domain literal in Ruby | Diff | PASS — diff |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The report claims nothing it did not run; this is a docs change with no real-model result | Report | PASS — no real-model run was made or claimed |
| F2 | No moved fact is left only in the old place; `.agent/README.md` still indexes the rules | Reviewer 1 | PASS — reviewer 1 |
| F3 | ADRs still true: `rake adr:validate adr:verify` | Output | PASS — `adr:validate`, 617 citations in `adr:verify`; semantic review recorded in `docs/adr-review-2026-09-29/adr-063-064-review.md` |
| F4 | The contradiction in `testing.md` rewritten in this change | Diff | PASS — `testing.md`, and `coding-standard.md` §1 and §11 |

## Owner instruction, 2026-11-04

"fix all issues you raised, specially the contraction and mentioning any files in docs should be removed or updated to documentation folder". This section was written after the first moves had started, so it does not meet the set-before-the-change rule.

| # | Issue | Fix | Check | Status |
|---|---|---|---|---|
| G1 | `AGENTS.md` and `.agent/rules` name files in `docs/` | Four standards moved to `documentation/governance/`; invariants route to `documentation/architecture/invariants.md`; citations and the probe's path removed | `grep docs/` on those files; `agents_md_test`, `documentation_test`, `documentation_tree_test` | PASS — reviewers approved; checks in A, D and F |
| G2 | `coding-standard.md` comments rule contradicts `AGENTS.md` | Standard rewritten to the owner rule; `.reek.yml` wording follows | Reviewer | PASS — reviewers approved; checks in A, D and F |
| G3 | `coding-standard.md` claims CI and local gates match | Rewritten to what runs where | Reviewer against `ci.yml` and `Rakefile` | PASS — reviewers approved; checks in A, D and F |
| G4 | `QUALITY_PROGRAM_STATE.md` stale; `QUALITY_PROGRAM.md` stale line | Retired with a banner, kept as history; line fixed | Diff | PASS — reviewers approved; checks in A, D and F |
| G5 | Two rules with no ADR | ADR-063, ADR-064, and the lease rule recorded in ADR-016; catalog, evidence, manifest and audit regenerated | `adr:validate`, `adr:verify`, evidence tests, reviewer against code | PASS — reviewers approved; checks in A, D and F |
| G6 | A typo fix needs a snapshot and a reviewer | Doc-only row in the template | Reviewer | PASS — reviewers approved; checks in A, D and F |
| G7 | "Effect mutations bind to the active lease" overstated | `AGENTS.md` now says a new effect attempt binds; `completed` and `unknown` are recorded after lease loss | `effect_reconciler.rb`, `agent_session_effect_test` | PASS — reviewers approved; checks in A, D and F |

**Still in `docs/`, on purpose:** task bars and plans (`docs/README.md` policy), and the authoritative design package `docs/design-v0.1/`, which `rake design:validate` and 58 files use. Dated archive files keep their old backticked paths; only broken links were fixed.

**Answers taken from "fix all issues you raised":** CI gap: correct the standard now, add RuboCop to CI once it reaches zero. Comments: `AGENTS.md` stands. State file: retire. ADRs: write both. Precedence line and generalized eval rule: keep. Doc-only row: add, with exclusions.

**Not done, needs the owner:** enabling a GitHub rule against force-pushes on `main` (the branch is unprotected today). **Depends on another session:** adding RuboCop to CI waits until `rubocop-zero` reaches zero. **Cannot be done as asked:** enola on CI, which needs a binary and a pinned baseline CI does not have; `coding-standard.md` records only that it skips.

## Future plan (not built)

- **Enforce what is advisory.** Anthropic's guidance puts must-always rules in hooks. The cheapest first step is a GitHub branch rule against force-pushes, because `.claude/` is gitignored and a hook there would not reach other clones. Tests: a force-push is refused. Open: which branches.

`enola install` restores the long block (about 20 more lines); re-condense after it. The 150-line budget allows for that.

## Review log

| Package | Findings (critical / high / medium / low) | Resolution | Commit |
|---|---|---|---|
| Round 1: rules and truth | 0 / 2 / 5 / 1 | `.env` and precedence rewritten; pointers and qualifiers restored; eval rule moved and listed as a decision | |
| Round 1: agent effectiveness | 0 / 3 / 5 / 0 | Fixed, except recording the funded provider: account state that rots | |
| Round 1: simplicity | 0 / 1 / 5 / 0 | Budget, regexes and cuts applied | |
| Round 2: rules and truth | 0 / 0 / 0 / 1 | Approved; low fixed afterwards in `subgraphs.md`, not re-read by this reviewer | |
| Rounds 2–3: agent effectiveness | 0 / 0 / 1 / 0 | `subgraphs.md` wording fixed; approved | |
| Rounds 2–3: simplicity | 0 / 0 / 1 / 0 | `subgraphs.md` wording and rewraps applied; approved | |
| Round 4: rules and truth | 0 / 1 / 6 / 1 | ADR-063 corrected against the code; fixed | |
| Round 4: agent effectiveness | 0 / 1 / 3 / 0 | Doc-only exclusions added; fixed | |
| Round 4: simplicity | 0 / 1 / 4 / 0 | D3 corrected; lease rule moved; probe restored; fixed | |
| Round 5: simplicity | 0 / 0 / 0 / 4 | Approved; bar wording fixed; `relationships.md` omitting ADR-063 and ADR-064 is how `adr:graph` works today (18 nodes before and after) | |
| Round 5: rules and truth | 0 / 0 / 2 / 0 | Worker cache wording and ADR-016 start and resolve rows fixed | |
| Round 5: agent effectiveness | 0 / 0 / 1 / 0 | Probe wording restored | |
| Round 6: rules and truth, agent effectiveness | 0 / 0 / 0 / 0 | Both approved; reviewer 3 approved in round 5 | |

## Loop log

| Iteration | Date | What changed | Rows moved (to PASS / to FAIL) | Still open | Next |
|---|---|---|---|---|---|
| 1 | 2026-11-04 | Rewrite, moved attachment detail, guard test, `testing.md` contradiction | none | all | Three-lens review |
| 2 | 2026-11-04 | Round 1 findings applied | none | all | Re-review |
| 3 | 2026-11-04 | `subgraphs.md` wording, rewraps | A1–A3, B4, E1, F2 | B1, D1–D5 | Final gates |
| 4 | 2026-11-04 | Nothing but grading | B2, B3, D1–D5, E2–E6, F1, F3, F4 to PASS; B1 to BLOCKED | none | Owner: commit |
| 5 | 2026-11-04 | Owner instruction: G1–G7 | none | all | Review |
| 6 | 2026-11-04 | Round 4 findings: ADR-063 rewritten, lease rule to ADR-016, doc-only exclusions, probe moved back | none | all | Re-review |
| 7 | 2026-11-04 | Rounds 5–6: cache wording, ADR-016 rows, memory probe wording, bar wording; all three approved | A1–A3, B4, E1, F2, G1–G7 | gates | Final gates |
| 8 | 2026-11-04 | Nothing but grading | B1–B3, D1, D4, D5, E2–E6, F1, F3, F4 to PASS; D2, D3 to BLOCKED | D2, D3 need a quiet machine and the known-red fixes | Owner |
| 9 | 2026-11-04 | Nothing but grading | none | D2, D3 | `rake ci` re-run at load average 52–90 (other work on this Mac): failed again on `sqlite_selector_control_test` and file-time caps. Change touches no production code. Re-run on a quiet machine |
| 10 | 2026-11-04 | Nothing but grading, on the commit, in a clean worktree | D2 to PASS | D3, red only on known-red at HEAD | Owner: fix the known-red |
