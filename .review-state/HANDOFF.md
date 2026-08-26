# HANDOFF — Clean-code review loop, extended queue (ranks 201–515)

Written 2026-08-25 ~19:51 CEST so a FRESH SESSION can resume without re-deriving anything.
The first 200-rank loop is COMPLETE and committed (see FLAGS.md + reports/001-200.md).
This file covers the extension loop over the remaining production files.

## Objective
Same five owner principles (intent-naming, short/single-purpose, one abstraction level,
public DSL reads, step-down to concrete) applied to every remaining production Ruby file
under gems/*/lib. Per-file gates: syntax, uncached rubocop parity (offense count never
increases, nothing suppressed), focused Minitest ONE FILE PER COMMAND, periodic cohort
gates (`rake ci` + enola). Atomic commit per file via verify_and_commit.sh.

## Where we are (at save time)
- Bar: `[████████████████░░░░░░░░░] 260/515`
- state.tsv tally: 216 committed · 37 clean · 4 exempt · 3 skipped (pre-existing)
- Queue rows 201-515 all present and well-formed (rank \t lines \t path).
- Ranks DONE this session: 201-250 fully terminal (reports + commits/clean/exempt marks).
- Ranks 251-260 (wave T6) status at FINAL save (19:53 CEST):
    252 CANDIDATES-ONLY -> marked clean; 253 CLEAN -> marked clean;
    260 COMMITTED-CANDIDATES -> committed by orchestrator at save time (verify row in
       state.tsv says committed);
    254 COMMITTED-CANDIDATES -> committed by orchestrator at save time;
    259 COMMITTED-CANDIDATES -> committed by orchestrator at save time;
    251 COMMITTED-CANDIDATES -> committed by orchestrator at save time;
    256 COMMITTED-CANDIDATES -> committed by orchestrator at save time;
    258 COMMITTED-CANDIDATES -> committed by orchestrator at save time (was mid-flight at
       first snapshot; finished normally);
    257 COMMITTED-CANDIDATES -> committed by orchestrator at save time;
    255 no report yet -> check reports/255.md + git status on resume.
  A resuming session must resolve ALL of 251-260 to terminal state before wave T7.
- Remaining after that: ranks 261-515 (~255 files, all <123 lines).

## Protocol (unchanged, proven)
1. Pick next 10 pending ranks from queue.tsv (ordered by size desc).
2. Launch fused combined-pass subagents. Prompt template:
   "Read .review-state/brief_combined.md FIRST and execute exactly — it is your complete
   brief. Bindings: RANK=<n>; OWNED FILE=<path>; REPORT=.review-state/reports/<n>.md;
   LIVENESS LOG=/tmp/tamoz-agents/combined-<n>.log. Repo root: /Users/ghassan/my-projects/tamoz."
   Add per-file EXTRA RAILS when authority-critical (approval/evaluator, grant_intersector,
   authority_validator, secure_file/database_file/path_resolver security posture, error
   hierarchies = renames forbidden, tamoz-sqlite boundary rail + extra gate
   test/sqlite_boundary_source_audit_test.rb).
3. Pace polls with `sleep 420` between checks; do not busy-poll.
4. Commit only verified work: `.review-state/verify_and_commit.sh <rank>` re-checks
   ownership + syntax + uncached rubocop parity before committing.
   For CLEAN/EXEMPT/CANDIDATES-ONLY: update state.tsv col3 directly.
5. New FLAGS go to .review-state/FLAGS.md (numbered `<n>/<rank>. <text>`).
6. Cohort gate every ~40 commits: background job `rake ci` + enola advisory check.
   KNOWN RED (not ours): DocumentationTest#test_local_markdown_links_resolve — parallel
   session's docs/gem-boundary-audit-2026-08-26*/01-current-inventory.md broken link to
   ../../gems/tamoz-stream/lib/tamoz/stream.rb:14. Gate passes iff this is the ONLY failure.
   Also: transient reds can be sibling mid-write loads — re-run solo before believing red.
7. SERIAL_TESTS-excluded lane (e.g. evals harness files): skip direct tests, rely on
   syntax + rubocop parity + pure-rename discipline, say so explicitly.

## Hard-won rails (do not rediscover)
- RuboCop default cache LIES under sandbox → always `--cache false`.
- If an agent dies mid-edit: diff may be ORPHANED/BROKEN (report can claim more than the
  tree holds). Revert file to HEAD and relaunch fresh (rank 205 precedent).
- If agent died post-edit pre-report but diff is small/self-contained: self-verify gates,
  write the report stub marked "orchestrator-completed", commit (rank 209 precedent).
- Rename candidates must grep THE FILE ITSELF for every occurrence — rank 207 missed :137,
  caught later by rank 215's agent via agent_profile_transition_test (fixed af81312).
- Rename greps must exclude .worktrees copies and generated .enola facts (false callers).
- Never touch: pinned bytes/messages/refusals, EffectDispatcher keys/receipts, twin seams
  (map_outcome), approval verdicts/evidence, Baselines.public_send strategy names (wire
  surface), endless (...) methods in tamoz-sqlite (boundary audit rail), declarative
  corpora (3 recorded exemptions), episode_graph.rb wiring (exempt, DSL eval model).

## Artifacts map
- .review-state/queue.tsv / state.tsv / bar.sh — ledger + progress render.
- .review-state/brief_combined.md — standing agent brief (carries all rails).
- .review-state/verify_and_commit.sh <rank> — gate + commit + state update.
- .review-state/reports/<rank>.md — per-file verdict record (fixed format).
- .review-state/FLAGS.md — 68 numbered owner decisions incl. latent parse_review bug,
  twin-store rename, dead APIs, vocabulary sweeps, doc-link watch.
- .review-state/agents.txt — rank → subagent id log (ids stale across sessions; use
  list_agents/job_list only if same session).
- Branch verification-again; tail commits so far start at 9b1056c (rank 209) … 157d487
  (rank 250); fix commit af81312 (check_spec_validator regression repair).

## Suggested resume sequence
1. Read this file + `bash .review-state/bar.sh`.
2. Resolve ranks 251-260 per protocol §"Where we are".
3. Continue waves of 10 (261-270, 271-280, …) with cohort gate #8 around rank ~290.
4. When queue exhausted: final sweep = uncached rubocop repo-wide count vs 976 baseline,
   rake ci (expect only the known doc-link red), enola advisory; then wrap-up report.
