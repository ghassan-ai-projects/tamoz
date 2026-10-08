# <Task name> — quality bar

<!--
  HOW TO USE
  1. Copy to the task's folder as QUALITY_BAR.md (or docs/<TASK>_BAR.md for a one-file task) BEFORE
     writing code. A bar written after the change grades what was built, not what was needed.
  2. Pick the size (S / M / L). Delete the sections the size table below marks "—".
  3. Every row names the check that proves it. A row is PASS only because that check ran this time;
     prose, a file that exists, or "it should work" is never PASS.
  4. Run the loop at the bottom until no row is FAIL or OPEN. Commit a package only when its rows pass.
  Delete this comment in the real bar.
-->

**Task:** <one line> · **Owner:** <name> · **Size:** S | M | L · **Set:** YYYY-MM-DD (before the change)
**Plan:** <link> · **Governing ADRs / invariants:** <ADR-NNN, clause N> · **Branch:** <name>

Status values: `PASS` (evidence named) · `FAIL` (what is wrong) · `OPEN` (not built) ·
`BLOCKED` (cannot be done here; reason named; never counted as a pass) · `WAIVED` (owner decision,
named and dated; never by the author).

## Which sections a task needs

| Section | S — fix, small doc or config | M — feature slice | L — multi-package, safety-bearing, or eval |
|---|---|---|---|
| 0 Outcome and fence | required | required | required |
| 1 Seam | required | required | required |
| A Safety and authority | when it touches authority, effects, data, or a boundary | required | required |
| B Function | required | required | required |
| C Evaluation | — | when behavior quality is claimed | required when a claim about the agent is made |
| D Gates | required | required | required |
| E Simplicity and standards | E1–E4 | required | required |
| F Honesty and records | F1, F3 | required | required |
| Review log | one reviewer before commit | one per package | one per package, lens pairs |
| Loop log | required | required | required |

## 0. Outcome and fence

**Outcome (one sentence):** <the property that will be true when this is done, stated so a check can
fail>.

**Done when:** every row below is PASS (or WAIVED by the owner), the review log has no open critical
or high finding, and the loop log's last iteration changed nothing.

**Not in scope:** <what this task will not do, and where it goes instead>.

**Owner decisions needed before or during the work:** <list, or "none">.

## 1. Seam — understand before you build

| # | Question | Answer (with file:line or enola result) |
|---|---|---|
| 1.1 | Which existing seam does this extend? Name the class, method, or facade. | |
| 1.2 | What already does part of this? (an effect, a loop, a store, a model call) A new class duplicating it is a defect. | |
| 1.3 | Blast radius: `impact_analysis` on what you will touch. | |
| 1.4 | Baseline pinned (`set_baseline`) and known-red gates proven at HEAD in a detached worktree (`git worktree add --detach <dir> HEAD`) — never `git stash`. | |

## A. Safety and authority — one discriminating test per property

Each test must be **seen to fail** when the property is removed (mutate the guard, watch the test go
red, restore). A test that cannot fail proves nothing.

| # | Property (what must be refused or must hold) | Check (test name; mutation) | Status |
|---|---|---|---|
| A1 | <e.g. a model-supplied value cannot set its own risk / evidence / scope> | `test/<file>.rb` — `test_<name>`; mutation: <drop which check> | OPEN |
| A2 | <non-deterministic or external call goes through `EffectDispatcher.run`; replay returns the receipt> | | OPEN |
| A3 | <a crash between <step> and <step> repeats nothing already done> | | OPEN |
| A4 | <no gem reaches past another's facade; boundary test covers the new seam> | | OPEN |
| A5 | <approval verdicts come only from `gems/tamoz-approval/policy/*.yaml`> | | OPEN |
| A6 | <secrets: a `Tamoz::Secret` never reaches the new surface> | | OPEN |

## B. Function — the capability works end to end

Scripted or fixture providers here prove **plumbing**, never intelligence. Say so in the row.

| # | Property | Check | Status |
|---|---|---|---|
| B1 | <happy path through the real graph / CLI / worker> | | OPEN |
| B2 | <each error path ends typed, not as a crash or a silent success> | | OPEN |
| B3 | <bytes that must not change, pinned from HEAD (prompt header, frame, wire)> | digest pinned from `<sha>` | OPEN |
| B4 | <idempotent redelivery / resume> | | OPEN |

## C. Evaluation — only when a claim about agent behavior is made

Thresholds are written **here, before the run**. A real-provider run is the only evidence of behavior;
report its n, seeds, interval, and model. A failed or invalid run is recorded, not dropped.

| # | Property | Check | Status |
|---|---|---|---|
| C1 | Controls discriminate offline: oracle passes, null fails, adversary is caught by the right gate | control gate test | OPEN |
| C2 | Corpus and domain content are data (`test/fixtures/domains/*.json`), digest-pinned | fixture + digest test | OPEN |
| C3 | <metric> ≥ <threshold> on <n> runs, <seeds>, with interval; development set vs holdout named | run report path | OPEN |

## D. Gates

Name every command and its result. A gate red before the change is listed under known-red with the
HEAD proof; it is not yours to chase, and it is not a pass.

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/<file>.rb` | OPEN |
| D2 | `rake ci` (ADR, design, syntax, `test_fast`, architecture) | output | OPEN |
| D3 | `rake ci_full`, both locales — only for durability, MCP, packaging, evidence slices | output | OPEN |
| D4 | RuboCop autocorrect ran on every touched file; leftovers are not hand-fixed | `bundle exec rubocop -a <files>` | OPEN |
| D5 | enola: `diff_snapshot` vs the 1.4 baseline — no new cycle, layer violation, or unintended coupling | enola output | OPEN |

**Known-red at HEAD:** <gate — one-line reason — how it was proven at HEAD>.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | The simplest design that delivers the outcome; no machinery for a case that cannot happen | review | OPEN |
| E2 | No compatibility shim, legacy-row reader, or alias (pre-1.0, ADR-059) | diff review | OPEN |
| E3 | Comments follow `AGENTS.md`: none by default, one or two lines of "why" at most | review | OPEN |
| E4 | New files mode 644 (scripts 755); no scratch files left in the repo | `git ls-files -s`, `git status` | OPEN |
| E5 | No new gem unless it needs its own dependency boundary (ADR-052); changed graph nodes bump `version:` | diff | OPEN |
| E6 | No domain literal in Ruby (ADR-058) | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The final report separates plumbing tests from real-model results and claims nothing it did not run | review of the report | OPEN |
| F2 | Plan, README, and design docs match what was built; deviations recorded | review | OPEN |
| F3 | Every affected ADR is true after the change: rule, `Implementation:`, Verification rows (`rake adr:validate adr:verify`); an authority loosening has a History line | ADR tooling + review | OPEN |
| F4 | Lessons are recorded in `AGENTS.md` or `.agent/rules/` in the change that taught them | review | OPEN |

## Review log

A reviewer other than the author reads the diff against this bar before each commit. Give the
reviewer this bar, the diff range, and the accepted deviations; forbid `git stash`/checkout.

| Package | Findings (critical / high / medium / low) | Resolution | Commit |
|---|---|---|---|
| | | | |

## Loop log

One row per iteration: grade every row, fix what fails, re-grade. Stop when an iteration changes
nothing and no row is FAIL or OPEN. If the same row fails three iterations running, stop and bring it
to the owner instead of looping.

| Iteration | Date | What changed | Rows moved (to PASS / to FAIL) | Still open | Next |
|---|---|---|---|---|---|
| 1 | | | | | |

## Final report (paste into the PR body)

- Outcome: met / not met, in one sentence.
- Rows: PASS n · FAIL n · BLOCKED n (each named) · WAIVED n (by whom).
- Commands run, with results; known-red gates with their HEAD proof.
- What is a real-model result and what is plumbing.
- Owner decisions still open.
