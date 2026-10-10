# Telegram eval leaves no process or temp dir behind — quality bar

**Task:** each Telegram eval run terminates and reaps every child it started and removes its temp dir, on success
and on failure · **Owner:** ghassan · **Size:** S · **Set:** 2026-10-10 (before the change)
**Governing rules:** ADR-024 (no real model in tests), `.agent/rules/testing.md` (never pay real time) ·
**Branch:** claude/clever-neumann-278a87

## 0. Outcome and fence

**Outcome:** after `TelegramChatEval#shutdown` (called from every run's `ensure`) no process the run started is
alive — including `tamoz start`'s own worker and gateway when `start` does not stop on TERM — and the run's
`tamoz-telegram-eval*` directory is gone; a run whose construction fails leaves no directory either.

**Root cause (observed 2026-10-10):** `tamoz start` stops its children one after another, each with an 8 s grace
(`CLIChildProcesses#stop_child`); the eval gave `start` 8 s before KILL, so a slow stop left the worker orphaned to
PID 1. `@root` (`Dir.mktmpdir`) was never removed.

**Not in scope:** cleaning dirs left by earlier runs (delete by hand); changing `tamoz start`'s own shutdown. Children
run in their own process group, so a `kill -9` of the eval or a terminal hangup no longer reaches them (it never
cleaned the dir either); an error raised by `shutdown` or `write_report` in `run`'s `ensure` can mask the block's
error — noted, not built (owner rule: no rare cases).

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `TelegramChatEval#spawn_child` / `#stop_child` / `#shutdown` (`test/support/telegram_chat_eval.rb`); the attachment and chat scripts already call `shutdown` in `ensure`. |
| 1.2 | Existing pattern | `TalkChatEval` spawns `start` with `pgroup: true` and signals the group; `ProcessGroupProbe#group_alive?` for the check. |
| 1.3 | Blast radius | `TelegramChatEval` is used only by `script/telegram_chat_eval`, `script/telegram_attachment_eval`, `TelegramChatScenarios`. |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | A run that ends normally leaves no child process (start and its worker) and no temp dir | `test/telegram_chat_eval_cleanup_test.rb` — success case; mutation: drop `pgroup`/group KILL | PASS — success case passes; KILL-leader-only mutation → 2 failures (group survived) |
| B2 | A run whose scenario raises leaves none either, and the error still reaches the caller | same file — failure case | PASS — failure case: error propagates (`assert_raises`), report written, nothing left |
| B3 | A `start` that ignores TERM is KILLed with its whole group after the grace, which is injected (test pays no grace) | same file; grace 0 | PASS — stub `start` and worker both trap TERM; grace 0; killed with the group |
| B4 | A run whose construction (provision) raises removes its temp dir | same file — provision-failure case | PASS — provision-failure case; mutation (no cleanup in `initialize`) → 1 failure |

## D. Gates

| # | Check | Status |
|---|---|---|
| D1 | new test file passes, under 2.5 s locally | PASS — 3 runs, 12 assertions, 0.23 s |
| D2 | `bundle exec rubocop -a` on changed files | PASS — remaining offenses in the changed files exist at HEAD |
| D3 | each new test seen to fail with its guard removed | PASS — mutations: group KILL → leader KILL (2 F), drop `rm_rf` (3 F), drop `initialize` cleanup (1 F) |

## E. Simplicity

| # | Check | Status |
|---|---|---|
| E1 | No new class; the fix lives in the existing spawn/stop/shutdown methods | PASS — no new class; `TelegramChatEval.run` + `signal`/`reap` helpers |
| E2 | Test needs no real model and no network beyond the local fake | PASS — stub children are `ruby -e`; only the local fake Bot API |

## F. Honesty

| # | Check | Status |
|---|---|---|
| F1 | Report states this is a plumbing test; no live eval was run | PASS — stated in the report |

## Review log

| Reviewer | Findings | Resolution |
|---|---|---|
| fresh subagent, 2026-10-10 | 0 critical/high. M1: a second Ctrl-C during the grace skipped the group KILL. M2: test stubs could leak if the test failed. L: B4 overclaimed "stops the fake"; dead `@logs \|\|=`; ensure-masking; no SIGHUP; grace coupled to `start`'s 8 s × 2 | M1: group KILL + reap in `stop_child`'s `ensure`. M2: teardown KILLs the stub group. B4 reworded; `\|\|=` reverted; grace comment states the coupling; masking + SIGHUP noted in "Not in scope" |

## Loop log

| Iteration | Changed | Rows still failing |
|---|---|---|
| 1 | process-group spawn, group KILL, `rm_rf` in `shutdown`'s ensure, `initialize` cleanup, `.run`, test | none (`rake ci`: 361 test files pass; `stream:proto:check` fails identically at HEAD — x86_64 `protoc`, EBADARCH) |
| 2 | review fixes (M1, M2, lows) | none |
| 3 | nothing | none |
