# Documentation refresh (2026-11-04) — quality bar

**Task:** bring the curated documentation in line with the code at `origin/main` (30f4a83f) · **Owner:** ghassan · **Size:** S · **Set:** 2026-11-04 (before the edits)
**Governing ADRs / invariants:** ADR-055 (stream split), ADR-059 · **Branch:** `docs-refresh`

## 0. Outcome and fence

**Outcome:** every checkable claim in `README.md`, `CHANGELOG.md`, `documentation/` and the touched gem READMEs about gem counts, the episode worker's RPCs and flags, the evals, and the Unreleased changes matches the source; the three doc gates pass.

**Not in scope:** dated plans, audits and reviews under `docs/` (a working archive, not rewritten); `docs/QUALITY_PROGRAM_STATE.md` (its checkpoint is 2026-08-26; refreshing it needs the global reek and coverage runs).

## Rows

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Gem counts match `gems/` | `ls -d gems/tamoz-* \| wc -l` = every count in `documentation/` | PASS |
| B2 | `streaming.md` and the stream README describe `DraftPlaybookRule`, its handshake feature and `--draft-model-policy` | read against `runtime-v1.proto`, `draft_runner.rb`, `bin/tamoz-stream-worker` | PASS |
| B3 | CHANGELOG Unreleased covers the main user-visible changes 2026-10-05 → 2026-11-03 (not every commit) | read against `git log` | PASS |
| B4 | The evaluation guide names the rule-proposal scorecard and its real-model script, labelled as real-model evidence | read against `script/rule_proposal_eval` | PASS |
| B5 | Generated records are fresh | `rake adr:catalog adr:graph adr:trace` leaves no further diff | PASS |
| D1 | `rake docs:check adr:validate adr:verify` pass | run this iteration | PASS |
| D2 | `test/documentation_surface_test.rb` passes | run this iteration | PASS |
| F1 | Real-model numbers are quoted with their limits (one sample per case, no confidence bound) | read | PASS |

## Review log

| Reviewer | Findings | Resolution |
|---|---|---|
| fresh subagent | 0 critical / 1 high / 3 medium / 4 low | stale gem counts in four more files fixed (B1 re-graded); "9 of 40" softened because the plan's per-case table sums to 6 (owner to reconcile); discrimination wording hedged and decline miss added; attachments added to CHANGELOG; `talk setup` named; retry wording tightened; controls listed in full. Not done: Telegram-memory/MCP-in-chat changelog items (unverified), `comms.md` line 3 and V1 non-goals (pre-existing) |

## Loop log

| Iteration | What changed | Rows moved | Still open |
|---|---|---|---|
| 1 | edits written | — | — |
