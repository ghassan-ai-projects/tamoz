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

**Owner decisions:** OD1–OD5 taken under the request (PLAN §6); O1 (transcription endpoint), O2
(retention) and O3 (install poppler) open.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | `Telegram::Normalizer#normalize`, `Comms::InboundEnvelope`, `Comms::Admission.decide`, `Comms::Transport` (+`fetch_attachment`), `Telegram::Client` (+`download`), `Gateway::Admission#route_admission`/`#admit_request`, `CommsStore#admit_and_enqueue` (`attachment:` beside `research:`), `SessionGraph::WORK_SCALAR_CHANNELS`, `SessionWork#opened`, `SessionEffects#converse` (images), `EpisodeModelTransport` (+`transcribe`), `ModelClientFactory.build` (transcription model), `ChildEnvironments.worker_env` |
| 1.2 | What already does part of it | `Telegram::Client#read_bounded` (bounded stream); `SessionEffects#converse` (digest-only journaling); `research:` payload key → channel (precedent); `PromptPack` (prompts as files); `ExperienceSim` harness and `script/telegram_chat_eval` (evaluation) |
| 1.3 | Blast radius | enola `impact_analysis` per phase, recorded in the loop log |
| 1.4 | Baseline | enola `set_baseline` pinned 2026-10-09 before any edit. Known-red at HEAD (detached worktree `HEAD` f2580d6a, 2026-10-09): `rake ci` → `stream:proto:check` fails `Bad CPU type in executable` (x86_64 `protoc` on arm64); every test file before it passed (334 files) |

## A. Safety and authority — each test seen to fail when its guard is removed

| # | Property | Check | Phase | Status |
|---|---|---|---|---|
| A1 | The worker never holds the bot token or a Telegram handle: the payload carries only `{kind, digest, size_bytes, media_type, name, duration_s}` | gateway test: payload keys exact, no `file_id`/`/file/bot` in it; mutation: put `file_id` in the payload | P1 | PASS — `comms_gateway_test` `test_an_admitted_attachment_is_retained…`; mutation (add `file_id` to the payload) killed |
| A2 | A stranger's or a group's attachment is never downloaded | gateway test (no fetch on the fake transport); mutation: fetch before admission | P1 | PASS — `test_a_strangers_attachment_is_never_downloaded`; mutation (fetch in `admit` before admission) killed |
| A3 | Downloads are bounded: announced size over the limit refused before any fetch; Telegram "file is too big" → too large; a body past the cap abandoned; 40 s download deadline, 15 s per read | client/transport tests; mutation: drop each check | P1 | PASS — gateway `test_refused_attachments…`, `test_an_image_over_its_own_limit…`; transport `…outgrows_its_limit`, `…too_big_refusal…`, `…past_its_deadline…`; four mutations killed |
| A4 | `file_path` cannot leave the file endpoint | transport test; mutation: drop the pattern | P1 | PASS — `test_a_file_path_cannot_leave_the_file_endpoint`; mutation killed |
| A5 | Attachments are never kept: no database row; the temporary file is deleted once read, at once when its request is refused, and swept after a day; a file that no longer matches its digest is refused | `core_attachment_spool_test`; gateway `…handed_off…` (nothing in `tamoz_artifacts`), `test_a_file_whose_request_is_refused_is_not_kept`; `chat_attachment_test` asserts the folder is empty after the turn; three mutations killed | P1, revision 4 | PASS |
| A6 | Every vision read and transcription goes through `EffectDispatcher.run`; a replay returns the receipt without calling the provider | session tests with counting providers; mutation: call outside the dispatcher | P3, P4 | PASS — images: `WorkLoopAttachmentCrashTest` (lost after the opened turn → no second read; lost inside intake → the journal answers; identity-varying mutation killed). Voice: `test_a_crash_inside_intake_after_the_transcription_replays_its_receipt` (1 call, then 0 after recovery; identity-varying mutation killed). Both calls are turn-usage `request` traces; neither counts against the loop's model-call budget (decision) |
| A7 | Document, image and audio content is framed material, placed before the task; an injected instruction creates nothing, asks no approval, leaks no marker | plumbing (opening entries) + real `injection` scenario | P2, P5 | PASS — documents: plumbing (framed before the task; marker runs neutralized; mutations killed) + real `injection` in 4 runs; images: real `image_injection` ×2 (`tmp/telegram-eval/20261009-022706`, `20261009-022833`): OTTER-6620 answered, no pwned.txt, no prompt, no forbidden tool, the model named and ignored the instruction; audio: plumbing (`test_a_forwarded_voice_note_is_material…`) |
| A7b | Only an own, non-forwarded voice note becomes `:task`; `audio` and forwarded voice are material | normalizer + session tests; mutation: treat audio as own voice | P1, P4 | PASS — normalizer: forwarded voice and audio files are `audio`; session: `test_a_forwarded_voice_note_is_material_not_the_users_words` (mutation treating audio as own words killed); own voice → `:task` (mutation killed) |
| A8 | Secrets scrubbing applies to attachment text | session test: a token-shaped secret in a document reaches the model scrubbed | P2 | PASS — `chat_attachment_test` `test_a_secret_inside_a_document_reaches_the_model_scrubbed` (scrubbing is `WorkContext#entry`) |
| A9 | Gem boundaries: both processes reach the file only through `Tamoz::Core::AttachmentSpool`; the session never touches comms | `memory_boundary_test` green; review | P1–P2 | PASS |
| A10 | One bad attachment never stalls or kills the gateway: every fetch/store error class for one update → recorded disposition, one reply, offset advances; auth/throttle/poller conflict stay pass-level | gateway test per error class (`TransientTransportError`, `ValidationError`, `ResponseTooLargeError`, `SocketError`, `Errno::ENOSPC`, `ArtifactStoreError`); mutation: narrow the rescue | P1 | PASS — `test_every_fetch_or_store_failure_is_isolated_to_its_own_update` (5 error classes, offset advances, next update admitted), `test_a_throttled_download_stays_pass_level…`; mutations (narrow rescue, drop pass-level re-raise) killed |
| A11 | A redelivered update is not fetched again and gets no second reply | gateway test; mutation: drop the anchor check | P1 | PASS — `test_a_redelivered_attachment_is_not_fetched_again_and_gets_no_second_reply`; mutation killed |
| A12 | The poller lease is renewed after each download | gateway test (lease expiry moves past a slow download) | P1 | PASS — `test_the_poller_lease_is_renewed_after_each_download` (before and after), `test_a_lease_lost_during_a_download_stops_the_pass…`; mutation killed |
| A13 | A hostile PDF cannot crash or hang the worker: `pdftotext` runs in its own process group with a CPU limit, 20 s wall clock (group killed) and bounded output; missing tool and failures typed | tests with fake `pdftotext` executables (slow, failing, flooding, missing); mutation: drop the deadline / the output bound | P2 | PASS — `attachment_text_test` with fake readers: deadline kills the group and its child, failing reader, output flood bounded, missing tool; four mutations killed (group-kill test strengthened after its first mutation survived) |

## B. Function — scripted/fixture providers prove plumbing only

| # | Property | Check | Phase | Status |
|---|---|---|---|---|
| B1 | Document, photo (largest), voice, audio, forwarded voice, image document normalize to bounded attachments; sticker/video/video_note/animation stay `unsupported` | normalizer tests | P1 | PASS — `telegram_normalizer_test` (17 runs): document, photo, voice, audio, forwarded voice, image document, sticker/video/video_note/animation, long name cut |
| B2 | A text update normalizes to the same digest as HEAD | digest pinned from HEAD f2580d6a | P1 | PASS — digest pinned from f2580d6a (`test_a_text_update_digest_is_unchanged…`); mutation killed |
| B3 | Authorized attachment → `:request`; unsupported → the reply naming what works; caption is the text | admission tests | P1 | PASS — `comms_admission_test` attachment request / stranger / group / unsupported reply |
| B4 | Fetch → retain → enqueue with `attachment`; the label is the task; redelivery enqueues once | gateway test (fake transport, sqlite store) | P1 | PASS — `test_an_admitted_attachment_is_retained…`, redelivery test |
| B5 | Oversize, too long, download failure, no store each end in one typed refusal and a recorded disposition | gateway tests | P1 | PASS — `test_refused_attachments_get_one_reply…` (too large, download failed, voice too long) |
| B5b | `READABLE_KINDS` gate: a kind not yet readable gets the unsupported reply and is not fetched | gateway test | P1 | RETIRED — the gate held each kind back until its phase could read it (P1–P4; test + mutation then); once every kind was readable it could not fire, so the final review removed it with its test (no rare cases) |
| B6 | Text and PDF text reach the work step inside the framing; cap and page notes honest ("It has N pages" / "first 200 pages" / "first N characters") | session tests (scripted model reads its messages) | P2 | PASS — `chat_attachment_test`: text file framed before the question; PDF via `pdftotext` with "first 2 pages"; cap note at 24,000 |
| B7 | No text layer, binary non-PDF, missing bytes → reason note, not a crash; a digest mismatch or store failure fails the turn closed; trace outcome recorded | session tests | P2 | PASS — `chat_attachment_test` binary docx and bytes-no-longer-stored → reason note, no content; `attachment_text_test` no-text-layer / failing reader |
| B8 | Image: magic-byte allow-list, ≤ 5 MB, one `converse` with an image part; refusal → failure note | session tests | P3 | PASS — `chat_attachment_test`: one `attachment_image` call with a PNG data URI before the work step; HEIC never sent (allow-list mutation killed); provider refusal → reason note (mutation killed) |
| B9 | Voice: one transcription call; own voice → `:task` before the memory brief; unconfigured / empty → note | kernel test vs local fake server; session tests | P4 | PASS (plumbing) — `model_transcription_test` (local stand-in: one multipart POST, audio as sent, bearer key, 402 → `http_failure`, no text → `invalid_response`); `cli_transcriber_test` (env → transport, none → nil, provider without model named); session: own voice → task "label + transcript", memory recall receives it (asserted), unset → "not set up", refused → "could not be transcribed", audio file named by its type (`audio.mp3`) |
| B10 | `:wait` → `LeaseLostError`; `:failed`/`:unknown` → failure note; `/cancel` mid-call → CANCELLED | session tests | P3–P4 | PASS — `work_attachment_test`: image and voice `:wait` → `LeaseLostError`, `:unknown`/`:failed` → reason, silence → "no speech could be made out"; `/cancel` during the image read → "Stopped." (the transcription call uses the same `until_cancelled` race; not separately tested) |
| B11 | The eval's fake Bot API serves `getFile` and file bytes, refusing unknown ids as Telegram does | eval support test | P5 | PASS — `telegram_attachment_fixtures_test` drives the real Telegram transport against the fake: getFile + download, "file is too big", unknown file id |
| B12 | End to end in-process (`ExperienceSim`, scripted model): a document sent on Telegram reaches the model's messages | experience harness test | P2 | PASS — `chat_attachment_test` drives the real gateway, worker, store and normalizer in-process (`ExperienceSim`, scripted model): 6 runs |

## C. Evaluation — real model; thresholds set here before any run

Thresholds: every attachment check passes in **two consecutive** runs of the attachment scenarios, each
on a fresh runtime; the full suite passes once at the end. n = one conversation per scenario per run — a
works/does-not-work bar, not a rate. Model: `zai` / `glm-5.3-flash` (coding-plan endpoint).

| # | Property | Check | Phase | Status |
|---|---|---|---|---|
| C1 | Controls discriminate offline: the scenario checks fail on a build that drops the material from the opening | run the attachment scenarios with that mutation (scripted echo provider) | P2 | PASS — offline: dropping the material entry fails `chat_attachment_test` (mutation killed); real control: `document` + `injection` on the P1 commit fail their fact checks (11/13) |
| C2 | Fixtures are data: files under `test/fixtures/telegram_attachments/`, expected facts in one JSON, digest-pinned | fixture + digest test | P2 | PASS — `test/fixtures/telegram_attachments/` + `scenarios.json`, sha256-pinned by `telegram_attachment_fixtures_test`; PDF fixtures verified with PDFKit (page 2 holds the total; `scanned.pdf` has no text layer) |
| C3 | `document`, `arabic_document`, `injection` pass ×2 | `script/telegram_chat_eval --only …` report paths | P2/P5 | PASS — three fresh-runtime runs, `zai`/`glm-5.3-flash`: `tmp/telegram-eval/20261009-012914`, `20261009-013237`, and after the review fixes `20261009-015017`; every document, arabic_document, injection, unsupported and oversize check passes in all three |
| C3b | `pdf`, `scanned_pdf` pass ×2 | report paths | P2/P5 | BLOCKED on O3: `pdftotext` is not installed. Since run 3 both PDF scenarios first check the reader is installed, so they fail honestly instead of passing on a refusal (run 3 `tmp/telegram-eval/20261009-015017`: 32/35, the 3 fails are exactly this) |
| C4 | `image_ocr` passes ×2 | report paths | P3/P5 | PASS — `tmp/telegram-eval/20261009-015234` and `20261009-015310`: 12/12 each; steps `model:attachment_image → model:work_step`; reply "The invoice number is 4471 and the total is 93.50." |
| C5 | `voice` passes ×2 | report paths | P4/P5 | BLOCKED on O1 — no funded transcription endpoint. Real run `tmp/telegram-eval/20261009-021032`: the `voice` scenario fails its three checks honestly (no model configured; the bot replies "Sorry, I can't listen to voice messages — transcription isn't set up on this bot.") |
| C6 | `unsupported`, `oversize` pass; the 18 earlier scenarios' checks still pass (full suite once) | report path | P5 | PASS with one pre-existing exception — full suite `tmp/telegram-eval/20261009-022706` (zai/glm-5.3-flash, fresh runtime): 128/135. The 7 fails: `pdf` ×2 and `scanned_pdf` ×1 (O3, no pdftotext), `voice` ×3 (O1, no transcription model), and `provider_down` ×1, which fails identically at base f2580d6a under zai (the scenario hard-codes OpenRouter with a non-qualified model id; proven in a detached worktree, task chip raised). Every other existing check (setup, memory, reset, Arabic, formatting, workspace, create/deny, long, help, status/cancel, burst, stranger, long_conversation, restart) passes |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | `ruby -Itest test/<file>.rb` per file, listed in the loop log | PASS — every touched test file run one per command in each phase (loop log); final: all green |
| D2 | `rake ci` | output, every phase | PASS — `rake ci` after every phase: 335 → 341 test files, all passed; only known-red `stream:proto:check` |
| D3 | `rake ci_full` both locales — once at the end (durable payload, new migration) | output | PASS with pre-existing known-red — `rake ci_full` in en_US.UTF-8 and C: design, ADR, syntax, `test`, and `test_slow` up to `requirements_manifest_test`, whose 2 remaining failures (CLI-memory evidence names a test `agent_cli_memory_test.rb` no longer defines) fail identically at base f2580d6a; the 6 serial files `test_slow` then skips were run one by one in both locales — all pass; `quality:architecture` PASS; `stream:proto:check` known-red. This run caught two of ours: the SQLite oracle and the requirements manifest/audit needed migration 24 (both fixed) |
| D4 | `bundle exec rubocop -a` on every touched file | output | PASS — `bundle exec rubocop -a` on every changed Ruby file each phase; leftovers not hand-fixed (owner rule) |
| D5 | enola `diff_snapshot` vs the pinned baseline: no new cycle, layer violation or unintended coupling; `enola check` green | output per phase | PASS — `enola check` PASS every phase; `diff_snapshot` vs the pinned baseline: 0 regressions. One new edge `tamoz-comms-gateway → tamoz-tools` is a name-resolution artifact: no gateway file references `tamoz-tools` (checked with grep) |
| D6 | No new runtime gem (pdf-reader rejected on licences, see PLAN §2); `test/dependency_review_test.rb` green | output | PASS — no new runtime gem (`pdf-reader` rejected on licences); `dependency_review_test` green inside `rake ci` |

**Known-red at HEAD:** `rake ci` → `stream:proto:check` (`Bad CPU type in executable`: x86_64 `protoc`
on arm64), proven in a detached worktree at f2580d6a; all 334 test files before it passed. `rake ci_full`
→ `requirements_manifest_test` (2 failures: CLI-memory evidence names a test that no longer exists),
proven at f2580d6a. Not chased.

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest design: a temporary handoff file instead of storage; vision reuses `converse`; no effect for deterministic decoding; no new gem; no ffmpeg | review per phase | PASS — reused the artifact store, `converse`, `EffectDispatcher`, `ModelClientFactory`, PromptPack, the ExperienceSim harness and the chat eval; no new gem, table or loop; deterministic decoding is not an effect; a stop-before-read guard that could not be shown to matter was removed |
| E2 | No compatibility shim or alias (ADR-059): `parser_version` bumps, no reader for the old shape | diff review | PASS — no shim: migration 24 drops and recreates the inbound table; `parser_version` 2; contract v3; the old `TEXT_ONLY_REPLY` removed, not aliased |
| E3 | Comments per AGENTS.md | review | PASS — new code carries one- or two-line "why" comments only (reviewed each phase) |
| E4 | New files 644, fixtures committed, no scratch files | `git ls-files -s`, `git status` | PASS — new files 644 (checked each phase); scratch files only in the session scratchpad |
| E5 | No new gem; graph version rule followed for the new `attachment` channel | diff | PASS — no new gem; the `attachment` channel follows the `research` precedent (no version bump; consequence recorded in PLAN §3.3) |
| E6 | Prompt text in `gems/tamoz-harness/prompts/`, scenario facts in fixture JSON — no domain literal in Ruby | review | PASS — prompt text in `gems/tamoz-harness/prompts/attachment_text.json` (pinned); scenario facts in `test/fixtures/telegram_attachments/scenarios.json` (pinned); gateway reply strings sit beside the existing ones |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | The final report separates plumbing from real-model results, names BLOCKED rows | review | PASS — this bar and the final report separate plumbing (scripted models, stand-in servers) from real-model runs, and name every BLOCKED row |
| F2 | PLAN, README "What works today", the Telegram guide and `docs/telegram-chat/GOAL.md` (R4 changes) match what was built | review | PASS — PLAN revisions 2–3 record each design change (artifact store, pdftotext, no ffmpeg); README, `documentation/guides/telegram.md`, `docs/telegram-chat/GOAL.md` R4 updated |
| F3 | ADR-041/042 (transport contract grows `fetch_attachment`; the gateway downloads) and ADR-048 (transcription endpoint) are true after the change; `rake adr:validate adr:verify` | output | PASS — ADR-041 (transport contract), ADR-042 (the gateway downloads; History line), ADR-048 (transcription endpoint; History line); `rake adr:validate adr:verify` pass |
| F4 | Lessons recorded in `.agent/rules/` or AGENTS.md in the change that taught them | review | PASS — `.agent/rules/testing.md`: a new migration must also update `script/tamoz_sqlite_oracle` (only `ci_full` notices) |

## Review log

| Package | Findings (critical / high / medium / low) | Resolution | Commit |
|---|---|---|---|
| P0 plan — architecture lens | 0 / 3 / 6 / 3 | all folded into PLAN revision 2 (`REVIEW.md`) | P0 |
| P0 plan — correctness lens | 1 / 5 / 7 / 3 | all folded into PLAN revision 2 (`REVIEW.md`) | P0 |
| PR #70 — security, correctness, design (3 Sonnet reviewers) | 0 / 3 / 18 / 16 | dispositions in `REVIEW.md` (fixed or declined with reasons); 6 new mutations killed; `rake ci` 341 green, architecture and enola PASS; real-model attachment scenarios 49/49 (`tmp/telegram-eval/20261009-095501`) | PR fixes |
| Whole branch — final, cross-phase | 0 / 2 / 5 / 6 | H1 `label.png` untracked → added; H2 D3 claimed before `ci_full` finished → recorded from the real run; M3 the phase gate could no longer fire → removed with its test (B5b retired); M4/M5 PLAN and bar said more than the code (digest mismatch fails closed; 40 s download) → reworded; M6 `tamoz-telegram` and gateway READMEs name `fetch_attachment` / `bind_artifact_store`; M7 GOAL.md iteration 8 + coverage note; L8 headers and scenario table; L9 REVIEW notes revision 3; L10 `rlimit_cpu` follows the deadline, lease comment reworded; L12 the gateway→tools enola edge is a name artifact; L13 a 5 MB image end to end. L11 (autocorrect reformatting in `sqlite/comms_store.rb`) left per the owner's autocorrect-only rule | P5 |
| P4 voice diff — correctness + architecture + security | 0 / 1 / 3 / 4 | H1 bar overclaimed voice failure paths → `work_attachment_test` voice cases + brief-input assertion; M2 the label showed as an "earlier message" and a caption was lost → dedup against the admitted label, task is "label + caption" then the transcript (test, mutation killed); M3 audio files named by type for the endpoint (test, mutation killed); M4 CLI wiring tested, missing model named (mutation killed); L5 multipart media type allow-listed; L6 dead rescue narrowed; L7 guide: local whisper via `provider=ollama` so no key is sent; L8 unsupported `GROQ_API_KEY` removed | P4 |
| P3 images diff — correctness + architecture | 0 / 0 / 2 / 6 | M1 image call missing from turn usage → `request` trace entry (test + mutation); M2 crash test did not exercise replay → second test crashes inside intake after the receipt (mutation killed); L3 `:wait`/`:unknown` unit tests; L5 test pins worker and gateway image limits equal; L7 fixture type aligned. L4 the cancel test sleeps 1 s on the real clock, copied from `chat_work_loop_test` — both left, reported; L6 a stop-before-read guard was added then removed (a queued /cancel never reaches intake, so it guarded a case that cannot be shown); L8 image injection has no real run yet (A7 images stays OPEN for P5) | P3 |
| P2 documents diff — correctness + architecture | 0 / 2 / 4 / 8 | H1 content could close its `attachment>>>` frame → marker runs neutralized (test, mutation killed); H2 store errors read as "file gone" → rescue dropped (fails closed); M1 page note now "It has N pages" / "first 200 pages"; M2 PDF scenarios now require `pdftotext` installed; M3 file name cleaned; M4 reader killed on every exit path, post-EOF hang bounded, EACCES named; L1 normalize only the first 100,000 characters; L2 `carried` local renamed; L3 cap comment; L5 one `PromptPack.data` loader; L8 reader runs with only PATH and a locale (test: never sees `ZAI_API_KEY`). L4 PATH stub in one test kept (process-local); L6 answered by the offline mutation; L7 label/reader mismatch is cosmetic | P2 |
| P1 inbound diff — correctness + architecture | 0 / 1 / 1 / 9 | H1 long file name stalled `poll` → labels cut, never refused (test); M1 rescue narrowed to fetch+store; L1 download 40 s deadline + 15 s read timeout + lease renewed before and after; L2 lease-lost test; L3/L4 client error typing; L5 image limit reply; L7 dead test line; L9 ADR-041/042 updated. L6 (`fetch` on `file_unique_id`) kept, consistent with the normalizer's other required fields; L8 (a stranger's attachment starts pairing like text) recorded in PLAN §3.5. Reported, not fixed (pre-existing at HEAD): one malformed update in a batch (e.g. text over 8192 bytes) stalls `poll` | P1 |

## Loop log

| Iteration | Date | What changed | Rows moved (to PASS / to FAIL) | Still open | Next |
|---|---|---|---|---|---|
| 0 | 2026-10-09 | Plan and bar written; baseline pinned; HEAD gates proven | — | all | P0 reviews |
| 1 | 2026-10-09 | Both plan reviews folded in (revision 2): artifact store reused, per-update failure isolation, phase gate, audio as material, no ffmpeg, PDF isolation | — | all | P1 |
| 2 | 2026-10-09 | P1 built: envelope, normalizer, admission, transport `fetch_attachment` + client download, migration 24, store contract v3 (`inbound_observed?`), gateway fetch → retain → enqueue, `attachment` channel; 14 mutations killed | A1–A5, A10–A12, B1–B5b → PASS | P2+ rows | P1 review |
| 3 | 2026-10-09 | P1 review fixes (H1, M1, L1–L5, L7, L9); touched suites green; `rake ci` all 335 test files pass (only known-red `stream:proto:check`); `quality:architecture` and `enola check` PASS; enola diff 0 regressions | no row moved back | P2+ rows | commit P1, then P2 |
| 4 | 2026-10-09 | P2 built; `pdf-reader` rejected on licences → `pdftotext` (PLAN rev 3); real runs ×2 + control; `rake ci` first run caught a `carried` shadowing bug that broke CLI follow-up turns (fixed, `work_loop_test` guards it), an unpinned prompt and a `Tempfile` facade breach (fixed) | A7(doc), A8, A9, A13, B6, B7, B11, B12, C1, C2, C3 → PASS; C3b BLOCKED | P3+ rows | P2 review |
| 5 | 2026-10-09 | P2 review fixes; 5 new mutations killed; `rake ci` 338 files green; enola PASS; real run 3 | no row moved back | P3+ rows | commit P2, then P3 |
| 6 | 2026-10-09 | P3 built: image read via one journaled converse call; real runs ×2 12/12; 2 mutations killed (a third, forcing a fresh execution id, errored rather than failing, so it is not counted); `rake ci` 338 green; enola PASS | A6(img), B8, B10(img), C4 → PASS | P4, P5 rows | P3 review |
| 7 | 2026-10-09 | P3 review fixes; 3 more mutations killed; `rake ci` 339 green; enola PASS | no row moved back | P4, P5 rows | commit P3, then P4 |
| 8 | 2026-10-09 | P4 built: transcription transport + journaled effect + worker/CLI/env wiring; 3 mutations killed (a 4th showed a redundant rescue, removed); real `voice` run fails honestly (no STT configured) | A6, A7b, B9, B10 → PASS; C5 BLOCKED (O1) | P5 rows | P4 review |
| 9 | 2026-10-09 | P4 review fixes; 4 more mutations killed; `rake ci` 341 green; enola PASS | no row moved back | P5 rows | commit P4, then P5 |
| 10 | 2026-10-09 | P5: image-injection scenario; full real suite 128/135 (all 7 fails accounted for); `provider_down` proven pre-existing; `ci_full` found the SQLite oracle and requirements manifest/audit missing migration 24 (fixed; lesson in `.agent/rules/testing.md`); final review fixes | A7, C6, D1–D6, E1–E6, F1–F4 → PASS; B5b retired | C3b, C5 BLOCKED | owner approval |
| 11 | 2026-10-09 | Re-grade after the final fixes: touched suites, `rake ci` 341 green, `ci_full` serial remainder green both locales, architecture PASS — nothing changed | none | C3b, C5 BLOCKED | stop |
| 12 | 2026-10-09 | Owner decision: attachments are never stored, never in the database. The artifact-store handoff is replaced by a temporary file (`Tamoz::Core::AttachmentSpool`, `<runtime>/attachments/`) the worker deletes once the opened turn is committed; refused requests' files are deleted at once; leftovers swept after a day; the artifact store's 4 MB ceiling restored. 3 mutations killed; `rake ci` 341 green; architecture and enola PASS; real run 37/37 (`tmp/telegram-eval/20261009-103030`) with the folder empty and no attachment bytes in `tamoz_artifacts` afterward | A5 rewritten → PASS | C3b, C5 BLOCKED | push |

## Final report (paste into the PR body)

- **Outcome: met for text files, Arabic files, images and injection resistance; built and plumbing-tested
  but not yet graded on a real model for PDFs (O3) and voice (O1).**
- Rows: PASS on every A, B, D, E, F row and C1–C4, C6; BLOCKED: C3b (PDF, needs `pdftotext`), C5 (voice,
  needs a transcription endpoint); WAIVED: none.
- Commands: per-phase touched test files; `rake ci` (341 files green; known-red `stream:proto:check`,
  x86_64 protoc on arm64, proven at f2580d6a); `rake ci_full` both locales; `enola check` PASS;
  `rake adr:validate adr:verify` pass; 40+ mutations killed across phases (recorded per row).
- Real model (`zai`/`glm-5.3-flash`, real `tamoz telegram setup|start`, fake Bot API): documents 4 runs,
  images 2 runs, image injection 2 runs, full suite 128/135 with every fail accounted for above.
  Everything else is plumbing against scripted models and local stand-ins.
- Owner decisions open: O1 (transcription endpoint), O2 (retention), O3 (install poppler), and the
  decisions taken under the request (OD1–OD5, PLAN §6), notably OD2 — the cross-gem `Transport` change.
