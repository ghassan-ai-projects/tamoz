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
| A1 | The worker's environment holds no channel variable of any enabled, disabled or registry-only kind, even when a model credential is named like a channel token | `child_environments` test whose fixture names a disabled kind's and a registry-only kind's token; mutations: denylist from enabled entries only; denylist before the model merge | PASS — `child_environments_test` (disabled/registry-only names, model key named like one), `cli_start_test#test_the_worker_never_gets_a_variable_a_disabled_channel_names`; both mutations fail them |
| A2 | A gateway's environment is exactly: the standard variables, `TAMOZ_RUNTIME_DIR`, `child_runtime_env`, its kind's `gateway_env`, and — if speaking — the voice keys; `start` refuses a voice key equal to the chat key by name or value | `child_environments_test` asserting the exact key set; mutations: a setup whose `gateway_env` returns `env` whole; every role handed to the gateway; the equality refusal dropped | PASS — `child_environments_test` exact key sets; refusal of an undeclared or model key; mutations fail |
| A3 | Setup methods and `connect` receive only `env.slice(*env_names)` | spy setup; mutation: pass the whole environment | PASS — `channel_kinds_test#test_a_setup_sees_only_the_variables_it_declares` (add and start); both slice mutations fail it |
| A4 | A `credential_ref` naming a variable outside the kind's `env_names` (e.g. the chat key) is refused, kind-blind, by `build_descriptor` | CLI test; mutation: skip the check | PASS — `channel_kinds_test#test_a_credential_the_kind_does_not_declare_is_refused`; mutation fails it |
| A5 | Two surfaces on one Telegram bot share one `stream_id` and cannot both hold the lease; a `stream_id` must start with its kind, so a talk surface cannot take a Telegram stream | `comms_gateway_test`, descriptor test; mutations: key the lease by `surface_id`; drop the prefix rule | PASS — `comms_gateway_test#test_two_surfaces_on_one_bot_share_one_stream_and_one_lease`, `comms_values_test` (a talk surface with a Telegram stream refused); lease-by-surface and prefix mutations fail them |
| A6 | `authenticate` returning another `stream_id` stops the gateway as `auth_failed` (exact string compare) | gateway test; mutation: compare after `to_i` / skip | PASS — `comms_gateway_test#test_start_rejects_a_transport_identity_mismatch` (`telegram:bot:99`); the `to_i` mutation fails it |
| A7 | Party ids of another kind are refused; non-`chat` spaces are refused groups; negative ids parse; `os`/`cli` are reserved kind names | `comms_parties_test`, `comms_admission_test`, `comms_decision_record_test`; mutation: accept any space | PASS — `comms_parties_test` (kind mismatch, group spaces, a negative supergroup id refused as a group, `cli:`/`os:` ids unparsed), `comms_admission_test` |
| A8 | `/cmd@otherbot` is not a command; `/cmd@ownbot` is | Telegram normalizer + `comms_seams_test`; mutation: strip any suffix | PASS — `telegram_normalizer_test#test_a_command_addressed_to_this_bot_drops_the_suffix_and_any_other_bot_keeps_it`, `comms_seams_test`; the strip-any mutation fails it |
| A9 | An unknown kind is refused by `channel add`, `start`, `serve`, `doctor`, `service` (ADR-014) | CLI test; mutation: fall back to a constant lookup | PASS — `channel_kinds_test#test_a_kind_the_registry_does_not_know_is_refused_everywhere` |
| A10 | `rendering.speech` refused on a kind that cannot speak; a non-loopback talk host without `allow_hosts` refused by `comms serve`, not only `start` | `validate!` tests; mutation: skip `validate!` in `build_descriptor` | PASS — `channel_kinds_test` (Telegram speech; talk host via `comms serve`); skipping `validate!` fails both |
| A11 | `channel add` of any kind refuses a runtime folder inside the workspace, and an `--env-file` with group/other bits | CLI tests for both kinds; mutation: run the workspace check only for talk | PASS — `channel_kinds_test#test_adding_any_channel_to_a_runtime_inside_the_workspace_is_refused`; talk-only mutation fails it |
| A12 | Approvals unchanged: deny-only, evidence-gated; a decision's actor and source name the same kind (`telegram_user` with source `talk` refused, in Ruby and SQL) | `comms_evidence_gated_approval_test`, `comms_decision_record_test`, `sqlite_comms_store_test`; mutation: drop the pairing check | PASS — `comms_decision_record_test#test_actor_and_source_name_one_kind`, `sqlite_channels_migration_test#test_a_decision_names_one_kind_on_both_sides`; the unpaired mutation fails it |
| A14 | The Telegram API origin is accepted only as a loopback `http://` origin | `Telegram::Channel` test; mutation: accept any origin | PASS — `tamoz_telegram_transport_test#test_the_bot_api_origin_is_telegram_or_a_loopback_stand_in` |
| A15 | A setup touches only its `state_dir` (0700, created by the CLI); the talk token lives there | CLI test; mutation: pass the runtime root | PASS — `cli_channel_talk_test#test_the_listen_address_is_the_channels_own_setting` (0700), token tests at `channels/talk/token`; surface ids are plain names (`runtime_directory_config_test#test_a_surface_id_is_a_plain_name`) |
| A16 | `start` refuses a model credential named like a channel variable | CLI test; mutation: drop the refusal | PASS — `channel_kinds_test#test_a_model_key_named_like_a_channel_variable_is_refused`; mutation fails it |
| A13 | Neither adapter requires beyond `tamoz/core`, `tamoz/comms` and the standard library, nor names `Tamoz::Agent`/`Tamoz::SQLite` | `talk_boundary_test`, new `telegram_boundary_test`; mutation: add `require 'tamoz/agent'` | PASS — `talk_boundary_test`, `telegram_boundary_test` |

## B. Function

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Every transport passes the shared conformance suite (Telegram, talk, loopback), no skips | `test/support/transport_conformance.rb`; mutation: break a transport's cursor or size check | PASS — C1, `a1c8c207` |
| B2 | Telegram and talk end-to-end behavior unchanged (plumbing, fixture transports); the only test diffs are PLAN §5's listed renames, moves and deletions | the named tests; `git diff --word-diff` on each changed test file reviewed against the list | PASS — every Telegram/talk behaviour test green; final whole-branch review of `git diff --word-diff fc594acc..HEAD -- test/` found one weakened assertion (the response cap), restored through `Channel#connect`; every other diff is a listed rename, move or removed feature (PLAN §5) |
| B3 | Talk restart replays from its durable cursor; a delivered approval card still binds | `talk_gateway_test` restart cases | PASS — `talk_gateway_test` restart cases green after the hub moved behind `Talk::Channel` |
| B4 | The new migration recreates the comms tables empty on a fresh schema and on a version-25 database, and touches no other table | migration test (row counts of memory/checkpoint tables unchanged) | PASS — `sqlite_channels_migration_test` (v25 → 26: comms tables empty, other schema and a `tamoz_threads` row kept; fresh schema via every adapter test); `sqlite_raw_oracle_test` pinned to 26 |
| B5 | A missing adapter gem is a named `MissingAdapterError` at every entry point | CLI test | PASS — `channel_kinds_test#test_a_missing_adapter_is_named_at_every_entry_point` |
| B6 | Voice still works on talk: Heard notice, echo guard, spoken replies, driven by `rendering.speech` | `talk_gateway_test#test_a_heard_notice_*`, `talk_hub_test`, `talk_speaker_test` | PASS — `talk_gateway_test`, `talk_hub_test`, `talk_speaker_test`, `chat_attachment_test` (speech now from the descriptor) |
| B7 | `comms serve` starts a surface's connection and drainer only once the lease is held: a second run is `:poller_busy`, exits 1 and claims no outbox row | serve test; mutation: start the drainer before the lease | PASS — `comms_cli_test#test_a_second_serve_cannot_take_the_lease_so_it_neither_listens_nor_delivers`; drainer-before-lease mutation fails it |
| B8 | A third kind needs only its own code: the loopback channel, added through `CLI.new(channel_kinds:)`, runs `channel add` and `start`'s checks (C2b) and a full gateway pass, admit → enqueue → deliver (C3) | `channel_loopback_test` | PASS — `channel_kinds_test#test_a_new_kind_is_added_and_started_with_only_its_own_code`, `#test_a_new_kind_admits_and_delivers_through_the_shared_gateway` |
| B8b | The same pass works in a subprocess with both adapter gems' `lib` off the load path, and no adapter file is in `$LOADED_FEATURES` | `channel_loopback_test` subprocess case; mutation: a stray `require 'tamoz/telegram'` in the CLI | PASS — `channel_kinds_test#test_the_cli_and_core_run_a_new_kind_without_either_adapter_gem` (child with a bare environment, no adapter lib on the load path); a hard adapter `require` in the CLI fails it |
| B11 | `channel add telegram` confirms Telegram's backlog after pairing, so no older update is answered later | `cli_channel_telegram_test` with three queued updates; mutation: confirm only to the pairing message | PASS — `cli_channel_telegram_test#test_pairing_confirms_every_update_so_none_is_answered_later`; confirm-once mutation fails it |
| B12 | `channel add talk --host NAME` records `settings.host`, and the talk gateway listens there | `cli_channel_talk_test` | PASS — `cli_channel_talk_test#test_the_listen_address_is_the_channels_own_setting` |
| B9 | A config with a removed key (`expected_bot_id`, `talk:`) fails loudly, naming the key | `runtime_directory_config_test` | PASS — `runtime_directory_config_test#test_a_removed_channel_key_is_refused_by_name` |
| B10 | Real-model smoke after §6 on the live runtime (evidence only, not a gate): one Telegram text turn and one talk voice turn | reported as real-model plumbing, not a quality claim | BLOCKED — no funded chat model until 2026-10-13, and §6 is the owner's runbook; not run, not claimed |

## C. Evaluation

| # | Property | Check | Status |
|---|---|---|---|
| C1 | `script/telegram_attachment_eval` and `script/talk_eval` run before C2a and after C3 on the same real model; both results reported; BLOCKED or SHORT is reported, never a pass; safety scenarios pass every run | eval reports in `docs/channels-abstraction-2026-10-10/` | PARTIAL — after-change `telegram_attachment_eval --runs 5` on zai/glm-5.3-flash (Z.ai coding endpoint) at `3e1db7f3`: 16/16 scenarios PASS, every safety scenario 5/5, `receipt_photo` 4/5 (one reply missed 27.85) ([report](telegram-attachment-eval-glm-5.3-flash.md)). Real-model result. With 5 runs a 5/5 lower bound is 0.566, so the verdicts rest on the rate. Not run: the pre-change baseline and `talk_eval` |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/<file>.rb` | PASS — every touched test file run alone, green |
| D2 | `rake ci` | output | PASS except `stream:proto:check`, BLOCKED here: grpc-tools ships an x86_64 `protoc` and this Mac has no Rosetta; the proto is untouched. `design:validate`, `adr:*`, `syntax`, `test_fast` (412 runs), `quality:architecture` green |
| D3 | `rake ci_full` both locales (schema + packaging) | output | PASS for this change — `test_slow` and `test_fast` in the C locale: every failure is identical at `fc594acc` (MCP order-dependent case, flagged as a task; talk fixtures read as US-ASCII) or passes 3/3 alone (a two-process lease race under load) |
| D4 | RuboCop autocorrect on touched files | `bundle exec rubocop -a <files>` | PASS — no RuboCop offense in `gems/` that `fc594acc` did not already have |
| D5 | enola `diff_snapshot` vs baseline: no cycle; `tamoz-comms` gains no dependency | enola | PASS — enola diff vs the pinned baseline: no cycle, no layer violation; `tamoz-comms` gained no dependency; the two "dead code" candidates are error classes raised from the adapter gems |
| D6 | Each gem installs with only its declared dependencies | isolated install in `ci_full` | PASS — `packaging_test` (isolated installs) green in `test_slow` |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Containment: exact per-file counts holding only PLAN §3.7's frozen counts; unit cases prove compound names count | `channel_kind_containment_test` | PASS — only the five frozen files remain counted (`channel_kind_containment_test`) |
| E2 | Dependencies: no `require`/constant reference to an adapter outside it and the registry; no gemspec depends on an adapter | `channel_dependency_test` | PASS — only the registry file names an adapter, two lines (`channel_dependency_test`) |
| E3 | Every interface method has a named caller (PLAN §4.2/4.3 tables); a `Connection` is four methods | review against the code | PASS — final review traced a caller for every `Channel`, `Connection` and `ChannelSetup` method |
| E4 | Setups moved from the CLI modules, then simplified; no logic duplicated between CLI and adapter; the CLI has no per-kind file | diff review | PASS — final review: the four CLI modules are gone, their logic lives once in the adapters; no kind branch in the CLI |
| E5 | Nothing kept for compatibility: no `expected_bot_id`, `bot_id` in the comms contract, `tg.`, `transport.mode`, `TAMOZ_TALK_HOST`, `TAMOZ_TELEGRAM_SURFACE`, `start --host`, `--bootstrap`, `comms_client_factory:`; no row-carrying code | grep | PASS — grep of `gems`, `bin`, `script`: only the frozen migrations and the oracle's history name the removed fields |
| E6 | No new gem; no new runtime dependency | gemspec diff | PASS — no gemspec, Gemfile or dependency change |
| E7 | Comments per AGENTS.md; files 644 | review, `git ls-files -s` | PASS — new and rewritten comments trimmed to one or two lines of why (final review); files 644 |
| E8 | Net growth of `gems/*/lib` is at most 300 lines (the interfaces, two `Channel` classes, the registry; moved code nets zero) | `git diff --stat <plan commit>..HEAD -- 'gems/*/lib'` | FAIL as written — `gems/*/lib` +490: code +248 (within 300), migration 26's recreated schema SQL +242, which the row did not foresee. Owner: waive, or re-scope the row to code |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Report separates plumbing tests from the B10 real-model smoke | review | OPEN |
| F2 | READMEs (`tamoz-comms`, `tamoz-telegram`, `tamoz-talk`), `documentation/guides/adding-a-channel.md` and this plan match the code; the guide's steps are the loopback test's | review | PASS — READMEs of `tamoz-comms`, `tamoz-telegram`, `tamoz-talk`, the root README gem map, `documentation/guides/adding-a-channel.md` (steps checked against the loopback kind; the measuring tests read the registry), Telegram/talk guides, `reference/cli.md`, `config.md`, `public-api.md`, `design/comms.md` |
| F3 | ADR-041, 042, 062 (and 014 Relates) true after the change; `rake adr:validate adr:verify` | ADR tooling | PASS — ADR-041, 042, 061, 062 (History lines, owner-marked), ADR-014 Relates; `adr:validate` and `adr:verify` (583 citations) green; catalog regenerated |
| F4 | Lesson recorded in `.agent/rules/`: "channel code lives in its adapter gem; two tests say where" | review | PASS — `.agent/rules/channels.md` (kind literals, word-splitting, child bundles), indexed in `.agent/README.md` |

## G. Size constraints (owner, 2026-10-10: "a must")

Set before the round. **Scope:** every `gems/*/lib` file this branch adds or modifies
(`git diff --name-only --diff-filter=AM main...HEAD -- 'gems/*/lib/**/*.rb'`, plus files split out of them).
Out of scope: `script/tamoz_sqlite_oracle` (the branch changed a version pin only; its ~130 offenses are their own task).

| # | Row | Check | Status |
|---|---|---|---|
| G1 | Every scoped file passes `Metrics/*` at the `.rubocop.yml` ceilings (method ≤ 20, class/module ≤ 250, ABC ≤ 20, cyclomatic/perceived ≤ 8, parameters ≤ 5 counting keywords, nesting ≤ 3, block ≤ 25) | `rubocop --only Metrics --ignore-disable-comments` with those ceilings | PASS — 82 scoped files, zero offenses with disables ignored (`bar.sh`) |
| G2 | No `rubocop:disable Metrics/*` in a scoped file, and no `.rubocop_todo.yml` `Metrics/*` entry for one | grep; the TODO parse | PASS — no `Metrics` disable comments; 58 `.rubocop_todo.yml` exclusions for scoped files removed and the files pass every cop |
| G3 | Every scoped file is ≤ 250 lines | `wc -l` | PASS — largest scoped file 229 lines; `migrator.rb` 1,873 → 149 (SQL moved to `migrations/0027.sql`), SQLite comms store 1,341 → 164 |
| G4 | Splits extract a responsibility (a collaborator or a value), never a concern that only relocates methods (CODING_STANDARD §2, §6) | review | PASS — splits are collaborators (`CommsInbound`, `CommsPolling`, `CommsStatus`, …), rule modules, or values (`Comms::Lease`, `Turn`, `Resume`, `Data` records); size-round review: 0 critical / 0 high |
| G5 | Behavior unchanged: `rake ci`, `rubocop`, `quality:reek`, `enola check` green | the gates | PASS for what this change owns — `rake ci` tests green (two TIME-cap overruns under eval load re-timed alone: 2.3 s and 3.0 s, cap 6.5 s); `enola check` PASS, no structural regression; requirements audit 538 pass / same 14 pre-existing gaps. `rubocop` and `quality:reek` are red at HEAD already (rubocop 4,721 offenses at HEAD → 4,644 now); reek smells in the touched gems rose 2,162 → 2,241 because split classes lost class-wide `:reek:` suppressions — reported, not chased |
| G6 | `config migrate` and schema 1 are gone; the callback-ack `NameError` is fixed with case 13 green | tests | PASS — `f203bf54`, `6feedb75` |

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
| C2 code (interfaces review) | 0 / 1 / 2 / 4 | `add` takes `existing:`; origin rule in `Client`; default bodies; all fixed | C2 |
| Whole branch | 0 / 0 / 4 / 6 | response-cap assertion restored through `connect`; listed test changes; a kind's credential must be its own token; LoadError only for the adapter itself; doctor writes nothing; greeting after the backlog; comments trimmed; E8 to the owner | final |
| C4 records | 0 / 1 / 5 / 7 | measuring tests read the registry (a third line needs no edit); ADR-041/042/062 wording and History; design/comms.md, public-api.md, config.md, README gem map, guide limits | C4 |
| C3 code | 0 / 0 / 4 / 8 | A7 cases (negative ids, reserved kinds), B4 row survival, config message, Telegram `bot_username` type, test/comment/dead-code fixes; docs to C4 | C3 |
| Size round (G1–G6) | 0 / 0 / mediums and lows below | applied: stale doc versions, simpler migrator, duplicate `refuse`, controls stub, one `DEFAULT_NAMESPACE`, requires, `getutc`; noted for the owner: kwrest + `Data` bundles, duck-typed `Turn`/`Lease` in the SQLite store (cross-gem), narrower answers rescue | `3e1db7f3` |
| C2 code (bar review) | 0 / 0 / 3 / 8 | surface-id rule + test; A1 CLI-level test; busy-surface message; origin refusal named; `http://` only; messages, comments, help banners; `bot_username` move recorded for C3 | C2 |

## Loop log

| Iteration | Rows changed | Notes |
|---|---|---|
| 0 (plan) | — | Bar set before code; revised with plan revs 3–6 |
| 1 | E1, E2, B1 started | C0–C1 committed; rows stay OPEN until the outcome they measure is reached |
| 5 | B2, B9, D1–D6, E3–E7 → PASS; E8 → FAIL (owner); B10 → BLOCKED | Whole-branch review fixes; final gate in both locales; nothing left to change without the owner or a funded model |
| 4 | F2–F4 → PASS | C4 records; `test_slow`: one MCP case errors at seeds 1–2 and passes at 3 — identical at `fc594acc` (pre-change), flagged as its own task |
| 3 | A5–A8, A12, B4, B8, B8b, E1, E2 → PASS | C3: one party grammar, string stream ids, migration 26; `test_fast` green (one load-noise over-cap re-run clean; HEAD clean); `quality:architecture` green |
| 2 | A1–A4, A9–A11, A13–A16, B1, B3, B5–B7, B11, B12 → PASS; C1 → BLOCKED | C2: all channel code in the adapter gems; containment counts outside core = 0; `rake ci` tests 407/407 green; `stream:proto:check` BLOCKED here (no Rosetta for grpc-tools' x86_64 protoc; untouched by this change); `quality:architecture` green |
