# Plan reviews — architecture and correctness (2026-10-09)

Two fresh subagents reviewed `PLAN.md` revision 1 against the code, one per lens. Totals: architecture
0 critical · 3 high · 6 medium · 3 low; correctness 1 critical · 5 high · 7 medium · 3 low. Every finding
is resolved in revision 2 of the plan or the bar; none was declined.

## Architecture lens

| # | Finding | Resolution |
|---|---|---|
| H1 | A new `Core::AttachmentStore` duplicates `Tamoz::SQLite::ArtifactStore` (sha256, tenant-scoped, rehash on retain and resolve), which both processes already hold; a file store also needs new constructor wiring in two cross-gem seams | Dropped the new store (and its already-written file). Gateway retains through `adapter.bind_artifact_store(tenant: "profile:<id>")`; the worker resolves through its session's `artifact_store`. `MAX_ARTIFACT_BYTES` 4 → 20 MB (OD5); binary round-trip test |
| H2 | A failed download stalls polling for the whole surface; downloads inline can outlast the poller lease; a redelivered update is fetched again | Per-update failure isolation, 60 s download deadline, lease renewal after each download, anchor check before fetch (PLAN §3.2, bar A10–A12) |
| H3 | Phase order leaves broken commits: a payload key without its channel fails in the worker; admitting attachments before anything reads them | Channel declared in P1 with the payload key; `READABLE_KINDS` phase gate admits a kind only in the phase that reads it |
| M1 | Graph version: no bump needed but say what breaks; channel exists only in the work graph | Stated in PLAN §3.3 (paused threads across the upgrade; attachments need the work route) |
| M2 | Nesting the vision `converse` effect inside a `read_attachment` effect | One journal entry per kind: `converse` for images, `transcribe` for voice; text/PDF decoding is deterministic, not an effect |
| M3 | Transcription settings never reach the worker (`unsetenv_others`, worker env allowlist); no session slot for a second model | P4 lists `ChildEnvironments.worker_env`, `ModelClientFactory.worker_environment`, `SessionOptions`, `WorkerRuntime#build_session`; `transcribe` refused in witness-gateway mode |
| M4 | ffmpeg only because Z.ai refused OGG; OpenAI/Groq accept OGG | Bytes sent as received; no ffmpeg (OD4). P4 stays (owner asked for voice); its real row is BLOCKED on O1 |
| M5 | `pdf-reader` is not installed under Ruby 3.3.11; dependency closure and licences understated | §2 corrected; required only in the PDF branch; D6 includes a licence review |
| M6 | Transcript placement: `@memory.brief(task)` runs before the opening; dedup at `work_context.rb:83` compares against `task` | `WorkAttachment` runs first in `opened`; own voice sets `:task` |
| L1 | Extraction inside intake is sound; keep it a small helper | `WorkAttachment` called from `opened` |
| L2 | Context-engine entry kinds are closed | Uses `user` |
| L3 | A 20 MB image is a ~27 MB request; add `fetch_attachment` to the conformance suite | Images ≤ 5 MB; contract test extended |

## Correctness lens

| # | Finding | Resolution |
|---|---|---|
| C1 | Any raised error during download blocks the bot: `CommsError` makes the pass transient and replays forever; non-`Comms` errors kill the gateway and recur on restart | Every fetch/store error for one update → recorded disposition + one reply; only auth, throttle and poller conflict stay pass-level; a test per error class that the offset advances (bar A10) |
| H1 | Redelivery downloads again and a failure then sends a false "send again" while the request runs | Anchor check before fetch; bar B4 asserts no second fetch and no reply |
| H2 | A hostile PDF (malformed, decompression bomb, page walk) crashes the worker in a resume loop | PDF read in a forked child with CPU limit, 20 s wall clock, 200 pages; every reader error typed (bar A13). On macOS `RLIMIT_AS` is not enforced; a memory bomb kills only the child |
| H3 | Forwarded voice notes and audio files are not the user's words; as `:task` they would pass the `remember` quote and `read_url` user-URL checks | Kind `audio` for audio files and forwarded voice notes, framed as material; only own `voice` becomes the task (bar A7b) |
| H4 | A transcript only in the opening entry leaves `:task` as the label for memory recall, `remember`, `read_url` | Own voice sets `:task` before the memory brief; empty transcript → "heard nothing" note |
| H5 | Telegram 400 "file is too big" maps to transient; `file_size` is optional; the 10 MB JSON cap would cut 10–20 MB files | "file is too big" → too large; the download has its own 20 MB cap; tests for absent `file_size` |
| M1 | ffmpeg on hostile input (playlist SSRF) | ffmpeg removed |
| M2 | Map effect outcomes: `:wait`, `:unknown`, `:failed`, cancellation | PLAN §3.5 rows; bar B10 |
| M3 | Pinned material vs the window; image formats; HEIC | Cap `min(24k chars, 25% of window)`; magic-byte allow-list PNG/JPEG/WebP/GIF |
| M4 | Downloads in the poll pass delay replies and outlast the lease | 60 s deadline + lease renewal; one owner bot, so no per-pass budget (recorded as a future refinement if a burst appears) |
| M5 | Eval weak points: injection passes by ignoring the document; `scanned_pdf` check cannot fail; history leaks across runs; digit forms | Injection fixture carries a required code word and a tool-exfiltration marker; `scanned_pdf` asserts the trace outcome; fresh runtime per run; digit normalization |
| M6 | Albums become N turns; GIFs carry a `document` field | Album behavior stated (§3.5); `animation` checked before `document` |
| M7 | Arabic PDFs come out in presentation forms / visual order | NFKC on PDF text; Arabic fixtures; the limit is stated in the report |
| L1 | A file name in `:task` counts as user-typed text for `read_url` | No file name in `:task`; the name appears only inside the framed material |
| L2 | "first N of M characters" is not knowable for a PDF | "pages read p of P" |
| L3 | No total store cap while retention is deferred | A store failure (disk full) is isolated per update (C1); retention stays in `FUTURE_PLAN.md` §3 |

Confirmed by the correctness reviewer: attachment fields in the digest only when present keep text
digests byte-identical; `parser_version` is not part of dedup; an empty task raises in `TurnContext`, so
the label keeps the task non-empty; payload channels are fresh per execution, so an attachment cannot
leak into the next turn.
