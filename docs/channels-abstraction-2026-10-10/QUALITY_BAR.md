# Channels as one abstraction — quality bar

**Task:** all channel code lives in its adapter gem; everything else holds interfaces · **Owner:** Ghassan ·
**Size:** L · **Set:** 2026-10-10 (before the change; revised with plan revision 6 after C0–C1)
**Plan:** [`PLAN.md`](PLAN.md) · **Governing ADRs / invariants:** 014, 041, 042, 052, 059, 061, 062 ·
**Branch:** `improve-channels`

Status values: `PASS` (evidence named) · `FAIL` · `OPEN` · `BLOCKED` · `WAIVED` (owner, named and dated).

## 0. Outcome and fence

**Outcome:** every Telegram and talk code path lives in `tamoz-telegram` / `tamoz-talk` behind `Comms::Transport`,
`Comms::Channel` and `Comms::ChannelSetup`; three tests prove it — names (containment), dependencies, and a
test-only third channel that works end to end with only its own code and one injected registry entry; Telegram
and talk keep every behavior test green; the only test changes are PLAN §5's listed renames, moves and deletions.

**Done when:** every row is PASS or WAIVED, the review log has no open critical/high finding, and the last loop
iteration changed nothing. A plan review round that finds a high finding is followed by another round.

**Not in scope:** PLAN §9 / [`FUTURE_PLAN.md`](FUTURE_PLAN.md). No upgrade path, no row carried (ADR-059).

**Owner decisions:** PLAN §7 — accepted 2026-10-10; OD-J is the owner's action.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seam extended | `Comms::Transport` (unchanged); new `Comms::Channel` and `Comms::ChannelSetup` beside it; `Gateway`/`DeliveryDrainer` unchanged in role except `Gateway#serve_loop(on_started:)`; the CLI composition root iterates the registry |
| 1.2 | What already does it | `Talk::Hub` (connection lifecycle), `build_transport`/`comms_client_factory` (connect), the four per-kind CLI modules and doctor bodies (setup) — moved, not rewritten |
| 1.3 | Blast radius | PLAN §3 (grep-exact, checked by four reviewers; enola misses module-function calls); `tamoz-core` `RequestIdentity` (C3); `tamoz-sqlite` comms tables (C3) |
| 1.4 | Baseline | `set_baseline` before C0; known-red gates proven at HEAD in a detached worktree |

## A. Safety and authority

| # | Property | Check (mutation) | Status |
|---|---|---|---|
| A1 | The worker's environment holds no channel variable of any enabled, disabled or registry-only kind, even when a model credential is named like a channel token | `child_environments` test whose fixture names a disabled kind's and a registry-only kind's token; mutations: denylist from enabled entries only; denylist before the model merge | OPEN |
| A2 | A gateway's environment is exactly: the standard variables, `TAMOZ_RUNTIME_DIR`, `child_runtime_env`, its kind's `gateway_env`, and — if speaking — the voice keys; `start` refuses a voice key equal to the chat key by name or value | `child_environments_test` asserting the exact key set; mutations: a setup whose `gateway_env` returns `env` whole; every role handed to the gateway; the equality refusal dropped | OPEN |
| A3 | Setup methods and `connect` receive only `env.slice(*env_names)` | spy setup; mutation: pass the whole environment | OPEN |
| A4 | A `credential_ref` naming a variable outside the kind's `env_names` (e.g. the chat key) is refused, kind-blind, by `build_descriptor` | CLI test; mutation: skip the check | OPEN |
| A5 | Two surfaces on one Telegram bot share one `stream_id` and cannot both hold the lease; a `stream_id` must start with its kind, so a talk surface cannot take a Telegram stream | `comms_gateway_test`, descriptor test; mutations: key the lease by `surface_id`; drop the prefix rule | OPEN |
| A6 | `authenticate` returning another `stream_id` stops the gateway as `auth_failed` (exact string compare) | gateway test; mutation: compare after `to_i` / skip | OPEN |
| A7 | Party ids of another kind are refused; non-`chat` spaces are refused groups; negative ids parse; `os`/`cli` are reserved kind names | `comms_parties_test`, `comms_admission_test`, `comms_decision_record_test`; mutation: accept any space | OPEN |
| A8 | `/cmd@otherbot` is not a command; `/cmd@ownbot` is | Telegram normalizer + `comms_seams_test`; mutation: strip any suffix | OPEN |
| A9 | An unknown kind is refused by `channel add`, `start`, `serve`, `doctor`, `service` (ADR-014) | CLI test; mutation: fall back to a constant lookup | OPEN |
| A10 | `rendering.speech` refused on a kind that cannot speak; a non-loopback talk host without `allow_hosts` refused by `comms serve`, not only `start` | `validate!` tests; mutation: skip `validate!` in `build_descriptor` | OPEN |
| A11 | `channel add` of any kind refuses a runtime folder inside the workspace, and an `--env-file` with group/other bits | CLI tests for both kinds; mutation: run the workspace check only for talk | OPEN |
| A12 | Approvals unchanged: deny-only, evidence-gated; a decision's actor and source name the same kind (`telegram_user` with source `talk` refused, in Ruby and SQL) | `comms_evidence_gated_approval_test`, `comms_decision_record_test`, `sqlite_comms_store_test`; mutation: drop the pairing check | OPEN |
| A14 | The Telegram API origin is accepted only as a loopback `http://` origin | `Telegram::Channel` test; mutation: accept any origin | OPEN |
| A15 | A setup touches only its `state_dir` (0700, created by the CLI); the talk token lives there | CLI test; mutation: pass the runtime root | OPEN |
| A16 | `start` refuses a model credential named like a channel variable | CLI test; mutation: drop the refusal | OPEN |
| A13 | Neither adapter requires beyond `tamoz/core`, `tamoz/comms` and the standard library, nor names `Tamoz::Agent`/`Tamoz::SQLite` | `talk_boundary_test`, new `telegram_boundary_test`; mutation: add `require 'tamoz/agent'` | OPEN |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Every transport passes the shared conformance suite (Telegram, talk, loopback), no skips | `test/support/transport_conformance.rb`; mutation: break a transport's cursor or size check | OPEN |
| B2 | Telegram and talk end-to-end behavior unchanged (plumbing, fixture transports); the only test diffs are PLAN §5's listed renames, moves and deletions | the named tests; `git diff --word-diff` on each changed test file reviewed against the list | OPEN |
| B3 | Talk restart replays from its durable cursor; a delivered approval card still binds | `talk_gateway_test` restart cases | OPEN |
| B4 | The new migration recreates the comms tables empty on a fresh schema and on a version-25 database, and touches no other table | migration test (row counts of memory/checkpoint tables unchanged) | OPEN |
| B5 | A missing adapter gem is a named `MissingAdapterError` at every entry point | CLI test | OPEN |
| B6 | Voice still works on talk: Heard notice, echo guard, spoken replies, driven by `rendering.speech` | `talk_gateway_test#test_a_heard_notice_*`, `talk_hub_test`, `talk_speaker_test` | OPEN |
| B7 | `comms serve` starts a surface's connection and drainer only once the lease is held: a second run is `:poller_busy`, exits 1 and claims no outbox row | serve test; mutation: start the drainer before the lease | OPEN |
| B8 | A third kind needs only its own code: the loopback channel, added through `CLI.new(channel_kinds:)`, runs `channel add` and `start`'s checks (C2b) and a full gateway pass, admit → enqueue → deliver (C3) | `channel_loopback_test` | OPEN |
| B8b | The same pass works in a subprocess with both adapter gems' `lib` off the load path, and no adapter file is in `$LOADED_FEATURES` | `channel_loopback_test` subprocess case; mutation: a stray `require 'tamoz/telegram'` in the CLI | OPEN |
| B11 | `channel add telegram` confirms Telegram's backlog after pairing, so no older update is answered later | `cli_channel_telegram_test` with three queued updates; mutation: confirm only to the pairing message | OPEN |
| B12 | `channel add talk --host NAME` records `settings.host`, and the talk gateway listens there | `cli_channel_talk_test` | OPEN |
| B9 | A config with a removed key (`expected_bot_id`, `talk:`) fails loudly, naming the key | `runtime_directory_config_test` | OPEN |
| B10 | Real-model smoke after §6 on the live runtime (evidence only, not a gate): one Telegram text turn and one talk voice turn | reported as real-model plumbing, not a quality claim | OPEN |

## C. Evaluation

| # | Property | Check | Status |
|---|---|---|---|
| C1 | `script/telegram_attachment_eval` and `script/talk_eval` run before C2a and after C3 on the same real model; both results reported; BLOCKED or SHORT is reported, never a pass; safety scenarios pass every run | eval reports in `docs/channels-abstraction-2026-10-10/` | OPEN |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/<file>.rb` | OPEN |
| D2 | `rake ci` | output | OPEN |
| D3 | `rake ci_full` both locales (schema + packaging) | output | OPEN |
| D4 | RuboCop autocorrect on touched files | `bundle exec rubocop -a <files>` | OPEN |
| D5 | enola `diff_snapshot` vs baseline: no cycle; `tamoz-comms` gains no dependency | enola | OPEN |
| D6 | Each gem installs with only its declared dependencies | isolated install in `ci_full` | OPEN |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Containment: exact per-file counts holding only PLAN §3.7's frozen counts; unit cases prove compound names count | `channel_kind_containment_test` | OPEN |
| E2 | Dependencies: no `require`/constant reference to an adapter outside it and the registry; no gemspec depends on an adapter | `channel_dependency_test` | OPEN |
| E3 | Every interface method has a named caller (PLAN §4.2/4.3 tables); a `Connection` is four methods | review against the code | OPEN |
| E4 | Setups moved from the CLI modules, then simplified; no logic duplicated between CLI and adapter; the CLI has no per-kind file | diff review | OPEN |
| E5 | Nothing kept for compatibility: no `expected_bot_id`, `bot_id` in the comms contract, `tg.`, `transport.mode`, `TAMOZ_TALK_HOST`, `TAMOZ_TELEGRAM_SURFACE`, `start --host`, `--bootstrap`, `comms_client_factory:`; no row-carrying code | grep | OPEN |
| E6 | No new gem; no new runtime dependency | gemspec diff | OPEN |
| E7 | Comments per AGENTS.md; files 644 | review, `git ls-files -s` | OPEN |
| E8 | Net growth of `gems/*/lib` is at most 300 lines (the interfaces, two `Channel` classes, the registry; moved code nets zero) | `git diff --stat <plan commit>..HEAD -- 'gems/*/lib'` | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Report separates plumbing tests from the B10 real-model smoke | review | OPEN |
| F2 | READMEs (`tamoz-comms`, `tamoz-telegram`, `tamoz-talk`), `documentation/guides/adding-a-channel.md` and this plan match the code; the guide's steps are the loopback test's | review | OPEN |
| F3 | ADR-041, 042, 062 (and 014 Relates) true after the change; `rake adr:validate adr:verify` | ADR tooling | OPEN |
| F4 | Lesson recorded in `.agent/rules/`: "channel code lives in its adapter gem; three tests say where" | review | OPEN |

## Review log

| Package | Findings (c / h / m / l) | Resolution | Commit |
|---|---|---|---|
| Plan rev 1 — architecture | 0 / 4 / 6 / 4 | resolved in rev 2 ([`REVIEW.md`](REVIEW.md)) | — |
| Plan rev 1 — simplicity/safety | 0 / 3 / 8 / 3 | resolved in rev 2 | — |
| Plan rev 3 — architecture/interfaces | 0 / 2 / 6 / 7 | resolved in rev 4 | — |
| Plan rev 3 — safety/simplicity | 0 / 3 / 5 / 3 | resolved in rev 4 | — |
| Plan rev 5 — architecture | 0 / 3 / 8 / 6 | resolved in rev 6 | — |
| Plan rev 5 — safety | 0 / 4 / 5 / 7 | resolved in rev 6 | — |
| C0–C1 code | 0 / 1 / 2 / 4 | high (redelivery property) and both mediums fixed before commit | `a1c8c207` |

## Loop log

| Iteration | Rows changed | Notes |
|---|---|---|
| 0 (plan) | — | Bar set before code; revised with plan revs 3–6 |
| 1 | E1, E2, B1 started | C0–C1 committed; rows stay OPEN until the outcome they measure is reached |
