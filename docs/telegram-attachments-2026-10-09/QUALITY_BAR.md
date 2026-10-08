# Telegram attachments — quality bar

**Task:** documents, PDFs, images and voice messages on the Telegram channel, each read its own way ·
**Owner:** Ghassan · **Size:** L · **Set:** 2026-10-09 (before the change)
**Plan:** [`PLAN.md`](PLAN.md) · **Governing ADRs / invariants:** ADR-016, ADR-041, ADR-042, ADR-048,
ADR-052, ADR-058, ADR-059 · **Branch:** enable-attachments-in-telegram

Status values: `PASS` (evidence named) · `FAIL` · `OPEN` · `BLOCKED` · `WAIVED` (owner only).

## 0. Outcome and fence

**Outcome:** a paired Telegram user who sends a text file, a PDF, an image or a voice note gets an answer
built from its content (text read, PDF text layer read, image text transcribed, voice transcribed and
answered as their words), and every attachment the bot cannot read gets one plain reply saying why —
with the bot token only in the gateway and every model or provider call journaled.

**Done when:** every row is PASS (or WAIVED by the owner), the review log has no open critical or high
finding, and the last loop iteration changed nothing.

**Not in scope (→ `FUTURE_PLAN.md`):** extracted content in later turns' history; scanned-PDF OCR; docx,
xlsx, pptx; a separate vision model; voice replies; attachment retention; albums (media groups) as one
request; groups.

**Owner decisions:** OD1–OD4 taken under the request (PLAN §6); O1 (transcription endpoint) and O2
(retention) open.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | `Telegram::Normalizer#normalize`, `Comms::InboundEnvelope`, `Comms::Admission.decide`, `Comms::Transport` (+`fetch_attachment`), `Telegram::Client` (+`download`), `Gateway::Admission#route_admission`/`#admit_request`, `CommsStore#admit_and_enqueue` (`attachment:` beside `research:`), `SessionGraph::WORK_SCALAR_CHANNELS`, `SessionWork#opened`, `SessionEffects#converse` (images), `EpisodeModelTransport` (+`transcribe`), `ModelClientFactory.build` (transcription model), `ChildEnvironments.worker_env` |
| 1.2 | What already does part of it | `Tamoz::SQLite::ArtifactStore` (verified, tenant-scoped bytes — reused, not rebuilt); `Telegram::Client#read_bounded` (bounded stream); `SessionEffects#converse` (digest-only journaling); `research:` payload key → channel (precedent); `PromptPack` (prompts as files); `ExperienceSim` harness and `script/telegram_chat_eval` (evaluation) |
| 1.3 | Blast radius | enola `impact_analysis` per phase, recorded in the loop log |
| 1.4 | Baseline | enola `set_baseline` pinned 2026-10-09 before any edit. Known-red at HEAD (detached worktree `HEAD` f2580d6a, 2026-10-09): `rake ci` → `stream:proto:check` fails `Bad CPU type in executable` (x86_64 `protoc` on arm64); every test file before it passed (334 files) |

## A. Safety and authority — each test seen to fail when its guard is removed

| # | Property | Check | Phase | Status |
|---|---|---|---|---|
| A1 | The worker never holds the bot token or a Telegram handle: the payload carries only `{kind, digest, size_bytes, media_type, name, duration_s}` | gateway test: payload keys exact, no `file_id`/`/file/bot` in it; mutation: put `file_id` in the payload | P1 | PASS — `comms_gateway_test` `test_an_admitted_attachment_is_retained…`; mutation (add `file_id` to the payload) killed |
| A2 | A stranger's or a group's attachment is never downloaded | gateway test (no fetch on the fake transport); mutation: fetch before admission | P1 | PASS — `test_a_strangers_attachment_is_never_downloaded`; mutation (fetch in `admit` before admission) killed |
| A3 | Downloads are bounded: announced size over the limit refused before any fetch; Telegram "file is too big" → too large; a body past the cap abandoned; 60 s deadline | client/transport tests; mutation: drop each check | P1 | PASS — gateway `test_refused_attachments…`, `test_an_image_over_its_own_limit…`; transport `…outgrows_its_limit`, `…too_big_refusal…`, `…past_its_deadline…`; four mutations killed |
| A4 | `file_path` cannot leave the file endpoint | transport test; mutation: drop the pattern | P1 | PASS — `test_a_file_path_cannot_leave_the_file_endpoint`; mutation killed |
| A5 | Stored bytes are verified: binary bytes (NUL, invalid UTF-8) round-trip; tampered rows refused | artifact store test | P1 | PASS — `sqlite_artifact_store_test` binary round-trip (NUL, 0xFF) and tampered-row refusal |
| A6 | Every vision read and transcription goes through `EffectDispatcher.run`; a replay returns the receipt without calling the provider | session tests with counting providers; mutation: call outside the dispatcher | P3, P4 | OPEN |
| A7 | Document, image and audio content is framed material, placed before the task; an injected instruction creates nothing, asks no approval, leaks no marker | plumbing (opening entries) + real `injection` scenario | P2, P5 | OPEN |
| A7b | Only an own, non-forwarded voice note becomes `:task`; `audio` and forwarded voice are material | normalizer + session tests; mutation: treat audio as own voice | P1, P4 | P1 part PASS (normalizer: forwarded voice and audio files are `audio`; mutation killed); P4 part OPEN |
| A8 | Secrets scrubbing applies to attachment text | session test: a token-shaped secret in a document reaches the model scrubbed | P2 | OPEN |
| A9 | Gem boundaries: the session reads bytes only through its `artifact_store`; the gateway only through `adapter.bind_artifact_store`; boundary tests green | `test/memory_boundary_test.rb` + review | P1–P2 | PASS (gateway side) — retains through `adapter.bind_artifact_store`, tenant verified against `WorkerRuntime#build_session` by the P1 reviewer; worker side in P2 |
| A10 | One bad attachment never stalls or kills the gateway: every fetch/store error class for one update → recorded disposition, one reply, offset advances; auth/throttle/poller conflict stay pass-level | gateway test per error class (`TransientTransportError`, `ValidationError`, `ResponseTooLargeError`, `SocketError`, `Errno::ENOSPC`, `ArtifactStoreError`); mutation: narrow the rescue | P1 | PASS — `test_every_fetch_or_store_failure_is_isolated_to_its_own_update` (5 error classes, offset advances, next update admitted), `test_a_throttled_download_stays_pass_level…`; mutations (narrow rescue, drop pass-level re-raise) killed |
| A11 | A redelivered update is not fetched again and gets no second reply | gateway test; mutation: drop the anchor check | P1 | PASS — `test_a_redelivered_attachment_is_not_fetched_again_and_gets_no_second_reply`; mutation killed |
| A12 | The poller lease is renewed after each download | gateway test (lease expiry moves past a slow download) | P1 | PASS — `test_the_poller_lease_is_renewed_after_each_download` (before and after), `test_a_lease_lost_during_a_download_stops_the_pass…`; mutation killed |
| A13 | A hostile PDF cannot crash or hang the worker: `pdftotext` runs in its own process group with a CPU limit, 20 s wall clock (group killed) and bounded output; missing tool and failures typed | tests with fake `pdftotext` executables (slow, failing, flooding, missing); mutation: drop the deadline / the output bound | P2 | OPEN |

## B. Function — scripted/fixture providers prove plumbing only

| # | Property | Check | Phase | Status |
|---|---|---|---|---|
| B1 | Document, photo (largest), voice, audio, forwarded voice, image document normalize to bounded attachments; sticker/video/video_note/animation stay `unsupported` | normalizer tests | P1 | PASS — `telegram_normalizer_test` (17 runs): document, photo, voice, audio, forwarded voice, image document, sticker/video/video_note/animation, long name cut |
| B2 | A text update normalizes to the same digest as HEAD | digest pinned from HEAD f2580d6a | P1 | PASS — digest pinned from f2580d6a (`test_a_text_update_digest_is_unchanged…`); mutation killed |
| B3 | Authorized attachment → `:request`; unsupported → the reply naming what works; caption is the text | admission tests | P1 | PASS — `comms_admission_test` attachment request / stranger / group / unsupported reply |
| B4 | Fetch → retain → enqueue with `attachment`; the label is the task; redelivery enqueues once | gateway test (fake transport, sqlite store) | P1 | PASS — `test_an_admitted_attachment_is_retained…`, redelivery test |
| B5 | Oversize, too long, download failure, no store each end in one typed refusal and a recorded disposition | gateway tests | P1 | PASS — `test_refused_attachments_get_one_reply…` (too large, download failed, voice too long) |
| B5b | `READABLE_KINDS` gate: a kind not yet readable gets the unsupported reply and is not fetched | gateway test | P1 | PASS — `test_a_kind_this_bot_cannot_read_yet…`; mutation killed. P1 ships `READABLE_KINDS = []` |
| B6 | Text and PDF text reach the work step inside the framing; cap note honest ("pages read p of P") | session tests (scripted model reads its messages) | P2 | OPEN |
| B7 | No text layer, binary non-PDF, missing/mismatched bytes → failure note, not a crash; trace outcome recorded | session tests | P2 | OPEN |
| B8 | Image: magic-byte allow-list, ≤ 5 MB, one `converse` with an image part; refusal → failure note | session tests | P3 | OPEN |
| B9 | Voice: one transcription call; own voice → `:task` before the memory brief; unconfigured / empty → note | kernel test vs local fake server; session tests | P4 | OPEN |
| B10 | `:wait` → `LeaseLostError`; `:failed`/`:unknown` → failure note; `/cancel` mid-call → CANCELLED | session tests | P3–P4 | OPEN |
| B11 | The eval's fake Bot API serves `getFile` and file bytes, refusing unknown ids as Telegram does | eval support test | P5 | OPEN |
| B12 | End to end in-process (`ExperienceSim`, scripted model): a document sent on Telegram reaches the model's messages | experience harness test | P2 | OPEN |

## C. Evaluation — real model; thresholds set here before any run

Thresholds: every attachment check passes in **two consecutive** runs of the attachment scenarios, each
on a fresh runtime; the full suite passes once at the end. n = one conversation per scenario per run — a
works/does-not-work bar, not a rate. Model: `zai` / `glm-5.3-flash` (coding-plan endpoint).

| # | Property | Check | Phase | Status |
|---|---|---|---|---|
| C1 | Controls discriminate offline: the scenario checks fail on a build that drops the material from the opening | run the attachment scenarios with that mutation (scripted echo provider) | P2 | OPEN |
| C2 | Fixtures are data: files under `test/fixtures/telegram_attachments/`, expected facts in one JSON, digest-pinned | fixture + digest test | P2 | OPEN |
| C3 | `document`, `arabic_document`, `injection` pass ×2 | `script/telegram_chat_eval --only …` report paths | P2/P5 | OPEN |
| C3b | `pdf`, `scanned_pdf` pass ×2 | report paths | P2/P5 | OPEN (BLOCKED on O3 expected) |
| C4 | `image_ocr` passes ×2 | report paths | P3/P5 | OPEN |
| C5 | `voice` passes ×2 | report paths | P4/P5 | OPEN (BLOCKED on O1 expected) |
| C6 | `unsupported`, `oversize` pass; the existing 91 checks still pass (full suite once) | report path | P5 | OPEN |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/<file>.rb` per file, listed in the loop log | OPEN |
| D2 | `rake ci` | output, every phase | OPEN |
| D3 | `rake ci_full` both locales — P2 (durable payload, packaging of a new dependency) and P6 | output | OPEN |
| D4 | `bundle exec rubocop -a` on every touched file | output | OPEN |
| D5 | enola `diff_snapshot` vs the pinned baseline: no new cycle, layer violation or unintended coupling; `enola check` green | output per phase | OPEN |
| D6 | No new runtime gem (pdf-reader rejected on licences, see PLAN §2); `test/dependency_review_test.rb` green | output | OPEN |

**Known-red at HEAD:** `rake ci` → `stream:proto:check` (`Bad CPU type in executable`: x86_64 `protoc`
on arm64), proven in a detached worktree at f2580d6a; all 334 test files before it passed. Not chased.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest design: the existing artifact store; vision reuses `converse`; no effect for deterministic decoding; no new gem; no ffmpeg | review per phase | OPEN |
| E2 | No compatibility shim or alias (ADR-059): `parser_version` bumps, no reader for the old shape | diff review | OPEN |
| E3 | Comments per AGENTS.md | review | OPEN |
| E4 | New files 644, fixtures committed, no scratch files | `git ls-files -s`, `git status` | OPEN |
| E5 | No new gem; graph version rule followed for the new `attachment` channel | diff | OPEN |
| E6 | Prompt text in `gems/tamoz-harness/prompts/`, scenario facts in fixture JSON — no domain literal in Ruby | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The final report separates plumbing from real-model results, names BLOCKED rows | review | OPEN |
| F2 | PLAN, README "What works today", the Telegram guide and `docs/telegram-chat/GOAL.md` (R4 changes) match what was built | review | OPEN |
| F3 | ADR-041/042 (transport contract grows `fetch_attachment`; the gateway downloads) and ADR-048 (transcription endpoint) are true after the change; `rake adr:validate adr:verify` | output | OPEN |
| F4 | Lessons recorded in `.agent/rules/` or AGENTS.md in the change that taught them | review | OPEN |

## Review log

| Package | Findings (critical / high / medium / low) | Resolution | Commit |
|---|---|---|---|
| P0 plan — architecture lens | 0 / 3 / 6 / 3 | all folded into PLAN revision 2 (`REVIEW.md`) | P0 |
| P0 plan — correctness lens | 1 / 5 / 7 / 3 | all folded into PLAN revision 2 (`REVIEW.md`) | P0 |
| P1 inbound diff — correctness + architecture | 0 / 1 / 1 / 9 | H1 long file name stalled `poll` → labels cut, never refused (test); M1 rescue narrowed to fetch+store; L1 download 40 s deadline + 15 s read timeout + lease renewed before and after; L2 lease-lost test; L3/L4 client error typing; L5 image limit reply; L7 dead test line; L9 ADR-041/042 updated. L6 (`fetch` on `file_unique_id`) kept, consistent with the normalizer's other required fields; L8 (a stranger's attachment starts pairing like text) recorded in PLAN §3.5. Reported, not fixed (pre-existing at HEAD): one malformed update in a batch (e.g. text over 8192 bytes) stalls `poll` | P1 |

## Loop log

| Iteration | Date | What changed | Rows moved (to PASS / to FAIL) | Still open | Next |
|---|---|---|---|---|---|
| 0 | 2026-10-09 | Plan and bar written; baseline pinned; HEAD gates proven | — | all | P0 reviews |
| 1 | 2026-10-09 | Both plan reviews folded in (revision 2): artifact store reused, per-update failure isolation, phase gate, audio as material, no ffmpeg, PDF isolation | — | all | P1 |
| 2 | 2026-10-09 | P1 built: envelope, normalizer, admission, transport `fetch_attachment` + client download, migration 24, store contract v3 (`inbound_observed?`), gateway fetch → retain → enqueue, `attachment` channel; 14 mutations killed | A1–A5, A10–A12, B1–B5b → PASS | P2+ rows | P1 review |
| 3 | 2026-10-09 | P1 review fixes (H1, M1, L1–L5, L7, L9); touched suites green; `rake ci` all 335 test files pass (only known-red `stream:proto:check`); `quality:architecture` and `enola check` PASS; enola diff 0 regressions | no row moved back | P2+ rows | commit P1, then P2 |

## Final report (paste into the PR body)

- Outcome: met / not met, in one sentence.
- Rows: PASS n · FAIL n · BLOCKED n (each named) · WAIVED n (by whom).
- Commands run, with results; known-red gates with their HEAD proof.
- What is a real-model result and what is plumbing.
- Owner decisions still open.
