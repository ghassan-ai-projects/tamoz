# Talk with Tamoz by voice — quality bar

**Task:** a browser talk channel: speak to Tamoz, see what it heard, hear and read its answer, approve by
button · **Owner:** Ghassan · **Size:** L · **Set:** 2026-10-09 (before any code)
**Plan:** [`PLAN.md`](PLAN.md) (revision 2) · **Eval:** [`EVAL.md`](EVAL.md) · **Governing ADRs /
invariants:** ADR-016, ADR-041, ADR-042, ADR-048, ADR-049, ADR-052, ADR-053, ADR-057, ADR-058, ADR-059;
plan invariants I1–I10 · **Branch:** `add-audio-support`

Status values: `PASS` (evidence named) · `FAIL` · `OPEN` · `BLOCKED` (reason; never a pass) · `WAIVED`
(owner only, named and dated).

## 0. Outcome and fence

**Outcome:** with `tamoz talk setup` and `tamoz talk start`, the operator opens the printed link in a browser
and has a spoken conversation with Tamoz. Speech is transcribed by the TRANSCRIPTION model and shown as
"Heard: «…»". The answer arrives as text and is spoken by the VOICE model. Stop, Status, typing and the
Approve and Deny buttons work, and everything joins one durable conversation. A spoken "yes" decides
nothing, audio is never stored, no key reaches the browser, and Telegram is byte-identical.

**Done when:** every row is PASS (or WAIVED by the owner), the review log has no open critical or high
finding, and the loop log's last iteration changed nothing.

**Not in scope:** [`FUTURE_PLAN.md`](FUTURE_PLAN.md) F1–F13.

**Owner decisions:** OD1–OD6 taken (PLAN §2); OD6 (2026-10-09) accepts the effect-journal exemption for
speech output and the ADR-042 amendment. **Open:** owner recordings for the eval (EVAL §3.5, optional).

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | PLAN §3 table: `Comms::Transport`, `Gateway#serve_once`, `Gateway::Attachments`, `WorkAttachment`, `SessionEffects#transcribe`, `EpisodeModelTransport`, `ModelClientFactory`, `ChildEnvironments`, `OutboxDeliverySink`, `Gateway::Callbacks`, `CLICommsShared`, `CLITelegramCommands` |
| 1.2 | What already does part of it | PLAN §5.4 reuse table |
| 1.3 | Blast radius | enola `impact_analysis` per phase, recorded in the loop log |
| 1.4 | Baseline | enola `set_baseline` pinned 2026-10-09 before any edit. Known red at HEAD `1e6ee1ea`, proven in a detached worktree: `rake ci` → `stream:proto:check` fails with `Bad CPU type in executable` (x86_64 `protoc` on arm64); all 342 test files before it passed |

## A. Safety and authority — each test seen to fail when its guard is removed

| # | Property | Check (test; mutation) | Phase | Status |
|---|---|---|---|---|
| A1 | I1: no spoken or typed word decides an approval; a decision needs a callback bound to an active prompt of this conversation | `talk_gateway_test`: transcript or text containing `approve:<ref>` decides nothing (mutation: route text kind to `resolve_callback`); stale, consumed, other-conversation and wrong-message-id talk decisions refused — the guards are the existing `Gateway::Callbacks` ones, whose mutations are each run once on the talk test (drop the conversation binding, drop the CAS, drop the receipt match) | P4/P6 | OPEN |
| A2 | I3: audio never stored — held until confirmation then freed; a failed pass after fetch can fetch again; nothing written by the hub or speaker | `talk_inbox_test` (mutation: free on fetch); `talk_speaker_test` intercepts `File.open`/`File.write`/`IO.copy_stream` during a speak and a prefetch (mutation: write the mp3 to disk) | P4 | OPEN |
| A3 | I9: no admitted-and-told update lost, none admitted twice: restart between receipt and admission; dies after admitting before confirming (the resend is a duplicate, POST 200, one turn); fetch then failed pass; clock regression; truncated batch; arrival during poll; resend dedup | `talk_inbox_test` + `talk_gateway_test` with a real SQLite store; mutations: confirm unreturned entries, `next_offset` from last assigned, no inbox dedup, skip `inbound_observed?` | P4 | OPEN |
| A4 | I8: Telegram byte-identical — normalizer digest, descriptor `definition_digest`, `DecisionRecord` id, `Binding#wire`, thread ids at generation 0 and 1 pinned from `1e6ee1ea`, captured in a detached worktree at that commit before any edit | `comms_parties_test`; mutation: change the Telegram prefix order or thread domain | P2 | OPEN |
| A5 | Party kind must equal surface kind; a talk id on a Telegram surface (and the reverse) is refused; only bindable prefixes bind | `comms_parties_test`, `comms_admission_test`; mutation: drop the kind check | P2 | OPEN |
| A6 | I5: the spawned talk gateway's environment is exactly the standard set + `TAMOZ_TALK_TOKEN` + the VOICE role's variables; the worker never gets the token; `talk start` refuses the chat key as the VOICE key; role credential names are validated (pattern, not `_API_BASE`, not gateway-only/forbidden) | `child_environments_test`, `talk_cli_test` (reads the spawned child's env), `model_client_factory_test`; mutations: pass the chat key, skip validation | P1/P6 | OPEN |
| A7 | HTTP edge: every `/v1/*` route refuses a missing or wrong token (401, body unread); foreign `Host` 421; no CORS headers, `OPTIONS` 404; CSP and `nosniff` on assets; `no-store` on `/v1/*`; non-loopback bind refused without `--allow-host` | `talk_server_test`; mutation per guard | P4 | OPEN |
| A8 | Hostile input: slowloris drip hits the deadline; bare LF, folded header, 65 headers, oversized head, oversized/duplicate/non-digit `Content-Length`, `Transfer-Encoding` → 400 without reading the body; connection cap holds | `talk_http_test`; mutation per guard | P4 | OPEN |
| A9 | The token (sent as the `Authorization` header) is never written to the server log or any HTTP response; it compares by digest | `talk_server_test#test_the_token_is_never_logged` (mutation: log the request head); `test_the_token_compare_is_by_digest` (mutation: `==` on raw strings is detected by a length-differing probe through a spy on the comparator) | P4 | OPEN |
| A10 | I10: a transcript that is the previous answer's projection heard back is framed as material, never the task; ordinary speech stays the task | `work_attachment_echo_test` pins: a true echo, 3 words (not an echo), 4 words, 79% and 80% overlap, out-of-order words, an ordinary transcript; mutations: drop the guard; frame every transcript as echo | P3 | OPEN |
| A11 | I7: transcription stays journaled (existing tests green); `#speak` is called only by the CLI's synthesizer callable | existing `WorkLoopAttachmentCrashTest` voice case; `talk_boundary_test` scans `gems/` for `.speak(` call sites (mutation: add a second caller) | P1/P4 | OPEN |
| A12 | Gem boundary: `tamoz-talk` requires only `tamoz-core`, `tamoz-comms` and stdlib; no `tamoz-talk` file names the SQLite store or `tamoz/agent` | `talk_boundary_test` (+ `memory_boundary_test` green) | P4 | OPEN |
| A13 | Rendering safety: only `render.mjs` touches message text, through `textContent`; a reply containing `<script>`/`<img onerror>` renders inert | `render.test.mjs` with a DOM stub whose `innerHTML` setter throws (mutation: `innerHTML`); B14 shows the same reply inert in a real browser | P5 | OPEN |
| A14 | The Heard notice is talk-only, unjournaled, keyed by request id (two same-word requests → two notices; replay → none new) and best-effort | `outbox_delivery_sink_test`, `work_attachment_notice_test`; mutations: no identity key, journaled, notices on for telegram | P3 | OPEN |
| A15 | I2: `/v1/speech/<id>` serves only a delivered message of a spoken kind; a control id, an unknown id or a never-delivered id is 404 | `talk_speaker_test#test_speech_is_only_a_delivered_spoken_kind`; mutation: serve any id or kind | P4 | OPEN |
| A16 | I6: talk text, voice, commands and decisions share one thread id per generation; `/new` rotates it | `talk_gateway_test#test_text_voice_and_commands_share_one_thread`; mutation: give voice its own thread | P4/P6 | OPEN |
| A17 | Limits hold: inbox 256 updates / 8 MB → 429; per-route caps → 413; a non-16 kHz-mono-16-bit WAV → 415; > 60 s audio → 413; event log keeps 500; speech cache keeps 32 | `talk_inbox_test`, `talk_server_test`, `talk_event_log_test`, `talk_speaker_test`; one mutation per cap | P4 | OPEN |
| A18 | Message ids are never reused after a restart, so a card from before a restart can never match a prompt delivered after it | `talk_event_log_test#test_ids_after_a_restart_are_above_every_earlier_id`, `talk_gateway_test` (old card vs new prompt refused); mutation: start ids at 1 | P4 | OPEN |
| A19 | The trace route exists only with `TAMOZ_TALK_TRACE=1` and the token | `talk_server_test`; mutation: always mount it | P4 | OPEN |
| A20 | OD6 is recorded: ADR-016 and ADR-042 amended with the threat row; the gateway env for talk carries only the VOICE credential | F3 + A6 | P8 | OPEN |

## B. Function — fixture providers prove plumbing only

| # | Property | Check | Phase | Status |
|---|---|---|---|---|
| B1 | `TAMOZ_<ROLE>_CREDENTIAL` selects the key variable for TRANSCRIPTION, VISION and VOICE; unset keeps today's behavior | `model_client_factory_test`, `cli_attachment_models_test`, `child_environments_test` | P1 | PASS — 2026-10-09: 27 runs green; mutations killed (drop `credential_name` from the worker env; drop the denylist; drop the profile-role refusal); a pasted key is never echoed |
| B2 | `EpisodeModelTransport#speak`: request shape, digest, bounded read (2 MB), content-type and mp3-sync checks, 10 s timeout, typed errors | `model_speech_test` (real socket server), `cli_attachment_models_test` (VOICE built with 10 s) | P1 | PASS — 2026-10-09: 7 runs; mutations killed (no byte bound; no mp3 check; no content-type check); unreachable → `EffectUnknownError`; real call through the new code: 33 KB mp3 in 1.28 s, round trip exact |
| B3 | Migration 25 copies every decision row and column; `talk_user`/`talk` accepted; ordinals and checksums contiguous | `sqlite_migration_test` (seeded rows survive), migrator pin test | P2 | OPEN |
| B4 | `build_descriptor` carries `kind`; a talk descriptor validates; `tk.` thread ids | `comms_descriptor_test`, `comms_parties_test` | P2 | OPEN |
| B5 | `Talk::Normalizer`: text, command, callback (with `callback_query_id`), voice (duration from WAV header); digest binds update id + audio digest; resend = duplicate, changed resend = conflict; `update_id` ≥ 2^53 refused | `talk_normalizer_test` | P4 | OPEN |
| B6 | One hub per surface: a delivery made through the drainer's transport appears in the server's event stream; `--once`/doctor/list never bind | `talk_hub_test`, `talk_cli_test` | P4/P6 | OPEN |
| B7 | Event log: epoch reset on restart and on cursor out of range; `working` outside the log; seeding restores the last 50 messages and every live approval card with its original message id, and Approve on a seeded card binds | `talk_event_log_test`, `talk_gateway_test` (restart with pending approval) | P4 | OPEN |
| B8 | `SpeechProjection` goldens: code, diff, table, inline code, path, digest, timestamp, link, long answer cut, multi-part first only, approval, failed/stopped/blocked verbatim, control → nil | `talk_speech_projection_test` | P4 | OPEN |
| B9 | Speaker: prefetch only with a speech-on page connected; single flight (two GETs → one call); cache key includes text digest; no VOICE → 404; provider failure → 502 | `talk_speaker_test` | P4 | OPEN |
| B10 | Client units: VAD start/end/hang-over/voiced-ratio/peak gates, PTT tail, half-duplex gating, WAV encoder (header, 16 kHz mono), retry keeps `update_id`, Heard pairing by order, token read from the fragment then `replaceState`, "voice unavailable" on a 502, `503` during stop is resent | `node --test` via `talk_client_js_test`; without node the Ruby test skips visibly and this row is **BLOCKED**, never PASS | P5 | OPEN |
| B11 | `tamoz talk setup` writes channel, profile (shared writer), 0600 token; `--rotate-token`, `--allow-host`; re-run bumps revision | `talk_cli_test` | P6 | OPEN |
| B12 | `tamoz talk start` names a failing chat, TRANSCRIPTION or VOICE role before spawning; spawns gateway + worker; prints the link once with the authority warning; port-in-use is a named error; `comms doctor` reports port, token mode and roles; waiting POSTs get 503 on stop | `talk_cli_test` with fake providers | P6 | OPEN |
| B15 | Two `start` commands on one runtime: either two workers are shown safe (one request is claimed by exactly one worker) or `talk start` refuses and names the other | `talk_cli_test` with two live worker processes on one runtime | P6 | OPEN |
| B13 | End to end with fakes: a WAV utterance through the real gateway, store and worker (fake STT/chat/TTS) → Heard notice → answer → speech bytes; a text message; Stop; an approval round trip by button | `talk_end_to_end_test` (plumbing) | P6 | OPEN |
| B14 | The page in a real browser (the in-app pane, no microphone claim): loads with CSP and no console errors; Start; history; approval card with `role=alertdialog` and focus; `aria-live` state line; 44 px targets; a reply with `<img src=x onerror=…>` inert; text send; light/dark; 360 px. Fallback when the pane is unavailable: the L3 headless Chrome canary | in-app browser check with screenshots | P5/P6 | OPEN |

## C. Evaluation — real models; protocol in [`EVAL.md`](EVAL.md)

| # | Property | Check | Status |
|---|---|---|---|
| C0 | Providers answer with the chosen models (P0) | `EVIDENCE.md` | PASS — 2026-10-09 real calls: `openai/gpt-4o-mini-transcribe` exact in 0.78 s; `hexgrad/kokoro-82m` mp3 in 0.57 s first byte, round trip exact |
| C1 | Heard WER (clean: median ≤ 0.05 and ≥ 90% ≤ 0.15; noisy reported) | `script/talk_eval` report | OPEN |
| C2 | Critical slots ≥ 95% exact (clean) | report | OPEN |
| C3 | Answer correct ≥ 80% per scenario, 5 runs | report | OPEN |
| C4 | Spoken reply round trip WER ≤ 0.2, nothing unspeakable spoken, ≥ 90% | report | OPEN |
| C5 | Safety 20/20 each: `approval_by_voice`, `injection_by_voice`, `nothing_kept`, `stop_by_button`, `self_echo`, `no_key_in_responses` | report | OPEN |
| C6 | Latency per stage p50/p90 and voice overhead reported | report | OPEN |
| C7 | Text/voice parity ≥ 80% | report | OPEN |
| C8 | Controls discriminate (oracle, null, wrong audio, unrelated TTS, no-answer, approve-by-voice client) | `talk_eval_controls_test` (offline) | OPEN |
| C9 | Endpointing offline: premature cut ≤ 5% at 1.0 s pause, false trigger ≤ 2%, false barge-in ≤ 2% | `node --test` endpointing eval | OPEN |
| C10 | Multi-turn follow-up and spoken correction ≥ 80% | report | OPEN |
| C11 | Cost per spoken turn reported | report | OPEN |
| C12 | Browser canary (EVAL §8): headless Chrome with fake capture, 3 scenarios × 3 runs; `talkTrace` marks in order; barge-in stop ≤ 150 ms after the click | canary report (BLOCKED reasons in EVAL §8) | OPEN |
| C13 | Scenario content and corpus are data and pinned; graders are tested: normalizer goldens for every pipeline step, WER, slots, the retention and key scans (with their false-positive negative) | `talk_fixtures_test`, `talk_checks_test` | OPEN |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Every touched or new test file, one per command | `ruby -Itest test/<file>.rb` | OPEN |
| D2 | `rake ci`'s sub-tasks run one by one because `stream:proto:check` (known red) stops the chain: `design:validate adr:validate adr:verify syntax test_fast quality:architecture` | output per task; `stream:proto:check` BLOCKED-by-known-red with the HEAD proof | OPEN |
| D3 | `rake ci_full`'s remaining tasks (`test`, `test_slow`) in both locales — durability and packaging slice (migration, new gem) | output | OPEN |
| D4 | `bundle exec rubocop -a` on every touched Ruby file | output | OPEN |
| D5 | enola `diff_snapshot` vs the 1.4 baseline: no new cycle, layer violation or unintended coupling; `tamoz-talk` reached only through the CLI | enola output | OPEN |
| D6 | New files mode 644 (scripts 755); `packaging_test` builds `tamoz-talk` | `git ls-files -s`, `rake test_slow` | OPEN |
| D7 | `TEST_WEIGHTS` refreshed so `rake ci` keeps its budget | `rake test_profile` (the budget check inside `rake ci` cannot run past the known red) | OPEN |
| D8 | `enola check` (the everyday gate's third leg) | output | OPEN |
| D9 | Whole-tree `rubocop` count not above HEAD's (autocorrect only on touched files) | counts at HEAD (detached worktree) and after | OPEN |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest design for the outcome; nothing from the future plan built | review against PLAN §5.3 | OPEN |
| E2 | No shim, alias or legacy reader (ADR-059) | diff review | OPEN |
| E3 | Comments per AGENTS.md (none by default; one-or-two-line why) | review | OPEN |
| E4 | No scratch files in the repo | `git status` | OPEN |
| E5 | One new gem (`tamoz-talk`) with its dependency boundary; README gem map updated; changed graph nodes bump `version:` | diff | OPEN |
| E6 | No domain literal in Ruby: scenarios, spoken texts, slots, echo-guard words are data | review | OPEN |
| E7 | Client JS: no dependencies, no CDN, no inline script, ES modules | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The final report separates plumbing from real-model results, states the synthetic-corpus limit, and claims nothing not run | review | OPEN |
| F2 | PLAN, README, guide (`documentation/guides/talk.md`) match what was built; deviations recorded | review | OPEN |
| F3 | ADR-061 (talk channel), ADR-042 amendment with threat row and History, ADR-048 speech endpoint, ADR-016 exemption marked pending owner; `rake adr:validate adr:verify` | ADR tooling | OPEN |
| F4 | Lessons in AGENTS.md or `.agent/rules/` in the change that taught them | review | OPEN |
| F5 | The owner is told plainly: the two open decisions (§4.6), the model swap, the bot-token exposure in this session | final report | OPEN |

## Review log

| Package | Reviewer | Lens | Findings (c / h / m / l) | Resolution | Commit |
|---|---|---|---|---|---|
| P1 role credentials + `speak` | Sonnet 5.5, fresh | correctness + test discrimination, security | 0 / 0 / 5 / 8 | All fixed: unknown-outcome mapping shared with `post_request`; 10 s VOICE timeout; no echo of a pasted key; content-type, unreachable, model-digest and profile-role tests; denylist simplified to `STANDARD` + `TAMOZ_*`; `NAME` deferred to P6; comments removed; blank voice refused | P1 commit |
| Bar + EVAL rev 1 | Sonnet 5.5, fresh | coverage, discrimination, pre-registration, consistency, feasibility | 0 / 8 / 18 / 6 | All 32 resolved: EVAL revision 2 (thresholds table, ordered normalizer, one adversary per grader, preconditions and INVALID, validated retention scan, distinct inputs, unit of analysis, fixture policy, C9 gates, canary layout) and bar rows A15–A20, B15, C13, D8, D9 plus rewritten A1–A3, A9–A11, A13, A14, B10, B12, B14, C12, D2, D3, D7; OD6 asked and taken | docs commit |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 0 | 2026-10-09 | Bar set before code | C0 PASS | all others | E0 + P1 + P2 |
| 1 | 2026-10-09 | P1 built, reviewed, fixed | B1, B2 → PASS | all others | P2 (in progress), E0 |
