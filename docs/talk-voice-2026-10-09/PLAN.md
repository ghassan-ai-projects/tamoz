# Talk with Tamoz by voice: plan (revision 2)

**Owner:** Ghassan · **Set:** 2026-10-09 · **Branch:** `add-audio-support` · **Size:** L
**Inputs:** research `agent-research-lab/voice-ai-tamoz-research-2026-10-01` (revision 3: docs 08, 15, 16),
handbook chapter `HDBK-022-real-time-audio-agents` · **Bar for this plan:** [`PLAN_BAR.md`](PLAN_BAR.md) ·
**Provider evidence:** [`EVIDENCE.md`](EVIDENCE.md) · **Bar for the result:** [`QUALITY_BAR.md`](QUALITY_BAR.md)
· **Eval:** [`EVAL.md`](EVAL.md) · **Deferred:** [`FUTURE_PLAN.md`](FUTURE_PLAN.md)

Revision 2 answers two independent reviews (security and durability; architecture, experience and eval).
Each finding and its resolution is in [`PLAN_BAR.md`](PLAN_BAR.md#review-log).

## 1. Outcome

The operator opens a talk page in a browser on their phone or desktop and holds a spoken conversation with
Tamoz. They speak, hands-free or push-to-talk. The page shows what Tamoz heard, then shows Tamoz's answer and
speaks a short form of it. They can interrupt the voice, type instead, press Stop or Status, and approve or
deny a change with a button on the page. Everything said joins one durable Tamoz conversation, with the same
memory, `/new`, `/status` and `/cancel` that Telegram has.

Hard properties:

- A spoken "yes" never approves anything.
- Audio is never stored.
- The browser never sees a provider key.
- Tamoz's own voice cannot re-enter as an instruction.
- Losing the speech never loses the answer, because text is the record.

## 2. Owner decisions (2026-10-09, in this session)

| # | Decision | Consequence |
|---|---|---|
| OD1 | **Browser talk app** is the product. Telegram is not the shape | A new comms surface kind `talk`, beside Telegram |
| OD2 | Replies are spoken by an OpenRouter speech model through `OPENROUTER_SPEECH_API_KEY`. After P0 the owner chose **`hexgrad/kokoro-82m`, voice `af_heart`** (`openai/gpt-4o-mini-tts` is not served) | Speech synthesis on the one model transport (ADR-048), made at presentation time (§4.6) |
| OD3 | **Approvals stay off voice.** Any change waits for an Approve button on the talk page (or Telegram, or `tamoz approve`). Device passkeys are deferred | The existing `chat_bound` callback path, unchanged |
| OD4 | **English only** in the eval | Arabic goes to the future plan |
| OD5 | Speech recognition: after P0 (qwen3-asr-1.7b took 16–22 s per clip), the owner chose **`openai/gpt-4o-mini-transcribe`** on OpenRouter (0.78 s, exact) | Role credentials (§4.1); `.env` is updated |
| OD6 | **Speech output runs in the talk gateway** (accepted 2026-10-09, after reading §4.6): the effect-journal exemption for presentation calls and the ADR-042 amendment are owner decisions | ADR-016 and ADR-042 are amended in P8 with the threat row; F10 and F11 stay as fallbacks |

Facts (`EVIDENCE.md`, measured 2026-10-09):

- OpenRouter serves `POST /api/v1/audio/transcriptions`, OpenAI-compatible multipart
  ([its STT guide](https://openrouter.ai/docs/guides/overview/multimodal/stt.md)).
- It serves `POST /api/v1/audio/speech`, as `mp3` or `pcm`
  ([its TTS guide](https://openrouter.ai/docs/guides/overview/multimodal/tts.md)).
- It has **no realtime speech API**, so research revision 3's sub-second talker cannot run on these keys.

This plan therefore builds the chained pipeline (speech → transcription → Tamoz → speech), whose turns take
seconds. The realtime lane is future plan F1.

## 3. What already exists (the seams this plan extends)

Mapped with enola (`explore`, `impact_analysis`) and by reading each file end to end. Line numbers are at
`1e6ee1ea`.

| Need | Existing seam | File |
|---|---|---|
| A channel with durable admission, dedup and offsets | `Comms::Transport` (authenticate, poll, deliver, fetch_attachment, signal), driven by `Gateway#serve_once`: renew → poll → admit each → persist offset (`gateway.rb:209-218`) | `tamoz-comms/lib/tamoz/comms/transport.rb`, `tamoz-comms-gateway/lib/tamoz/comms/gateway.rb` |
| Voice in, transcribed as the user's words | `Gateway::Attachments#admit_attachment` (`gateway_attachments.rb:19`) skips the fetch for a seen update (`:22`), fetches, puts the bytes in `Tamoz::Core::AttachmentSpool` under `raw_payload_hash` (`:78`), and admits. `WorkAttachment#speech` (`work_attachment.rb:65`) then runs the journaled `SessionEffects#transcribe` (`session_effects.rb:115`) → `EpisodeModelTransport#transcribe` (`:121`) | as named |
| A model per role | `TAMOZ_<ROLE>_PROVIDER/_MODEL/_API_BASE` → `CLIWorkerCommands#attachment_model` (`cli_worker_commands.rb:685`) → `ModelClientFactory.build`; `ChildEnvironments.attachment_model_env` (`child_environments.rb:47`) gives them to the worker only | as named |
| Approve or deny by button | `OutboxDeliverySink#push_approval_prompt` (`outbox_delivery_sink.rb:174`) → a delivery whose `markup` is `{reference, actions}` → callback `approve:<ref>` → `Gateway::Callbacks#resolve_callback` (`gateway_callbacks.rb:33`). It binds surface, revision, correspondent, conversation and prompt receipt (the delivered message id), and consumes the prompt once (CAS). Deny is unconditional | as named |
| Stop, status, new conversation, redirect | `Comms::Commands` parse; `Gateway::Commands` handle; stop goes through `Cancellation::Stops` | `gateway_commands.rb` |
| "Working" pulses | `DeliveryDrainer#pulse_typing` signals `:typing` every 4 s per working conversation (`delivery_drainer.rb:66`) | as named |
| Running the gateway and worker | `tamoz telegram start` (`cli_telegram_commands.rb:225`) spawns `comms serve --surface` and `worker` with exact environments. `comms serve` builds **two** transports per surface: one for the poller (`cli_comms_commands.rb:65`) and one for the drainer thread (`:205`) | as named |
| Real-model channel eval | `TelegramChatEval` (real `setup` and `start`, settle rules) and `script/telegram_attachment_eval` (runs, point rate, Wilson bound, BLOCKED and SHORT) | `test/support/telegram_chat_eval.rb`, `script/telegram_attachment_eval` |

Telegram-only literals a second kind must generalize:

- `SurfaceDescriptor::KINDS` (`surface_descriptor.rb:30`), and `build`'s `kind: 'telegram'` default (`:69`).
  `CLICommsShared#build_descriptor` never overrides it (`cli_comms_shared.rb:68-100`).
- The `telegram:` prefixes. `InboundEnvelope#validate_parties!` (`inbound_envelope.rb:146`) accepts the group
  prefixes so that admission can refuse them. `Binding` (`binding.rb:96`) and `Conversation`
  (`conversation.rb:71`) accept `telegram:chat:` only.
- The `tg.` thread prefix and `group_chat?` in `Admission` (`admission.rb:56,63`).
- `DecisionRecord::ACTOR_KINDS` and `SOURCES` (`decision_record.rb:42`), and their SQL `CHECK`s
  (`migrator.rb:754,756`).
- `CLICommsShared#build_transport` always builds the Telegram transport (`cli_comms_shared.rb:133`).
- `ChildEnvironments.gateway_env` hard-codes `TAMOZ_TELEGRAM_*` (`child_environments.rb:26-33`).

New work, because nothing like it exists: an HTTP server fit for a browser. `Tamoz::Core::RawHttp`
(`raw_http.rb:18-27`) discards the request line, has no head, header-count or body bound and no timeout,
and always answers `application/json`. It serves only `WitnessGateway`, a single-threaded internal endpoint
on an ephemeral port. Reusing it would be a false economy. `tamoz-talk` gets its own hardened parser (§4.4),
and `RawHttp` stays as it is.

## 4. Design

### 4.1 Role credentials, and speech output as a role

- **Naming a role's key.** `TAMOZ_<ROLE>_CREDENTIAL` names the **environment variable** that holds a
  role's key: a reference, never a value. It must match `/\A[A-Z][A-Z0-9_]*\z/`, and it is never the role's
  `_API_BASE`, nor a name in `ChildEnvironments::GATEWAY_ONLY` or `FORBIDDEN_EVERYWHERE`. Unset, it means
  the provider's usual variable, as today.
- **Plumbing.** `ModelClientFactory.build` and `.worker_environment` take an optional `credential_name:`,
  so the child receives exactly that variable.
- **The VOICE role.** It names the speech-output model: `TAMOZ_VOICE_PROVIDER`, `_MODEL`, `_API_BASE` and
  `_CREDENTIAL`, plus `TAMOZ_VOICE_NAME` (the provider's voice id). The voice name is required, because
  each speech model has its own voices (`EVIDENCE.md`).
- **The VOICE key is never the chat key.** `talk start` refuses when `TAMOZ_VOICE_CREDENTIAL` resolves to
  the chat provider's credential variable, so a presentation process never receives the reasoning key
  (§4.6).
- **`.env` changes.** It gets `TAMOZ_TRANSCRIPTION_PROVIDER=openrouter`,
  `…_MODEL=openai/gpt-4o-mini-transcribe` and `…_CREDENTIAL=OPENROUTER_SPEECH_API_KEY`. It also gets
  `TAMOZ_VOICE_PROVIDER=openrouter`, `…_MODEL=hexgrad/kokoro-82m`, `…_NAME=af_heart` and
  `…_CREDENTIAL=OPENROUTER_SPEECH_API_KEY`. The owner's `TAMOZ_SPEECH_MODEL` line is kept, commented,
  with the reason.
- **Rejected alternative:** putting the speech key into `OPENROUTER_API_KEY`. That would hand speech credit
  to any chat route the operator later points at OpenRouter. It would also make `telegram start` pick
  OpenRouter as a chat candidate (`cli_telegram_commands.rb:340`).

### 4.2 Speech output on the one model transport

`EpisodeModelTransport#speak(text:, voice:)` posts `{model, input, voice, response_format: "mp3"}` to
`/audio/speech`.

- **Reading the reply.** The body goes through a bounded reader (2 MB; anything past it is an error, not a
  truncation). The reader checks `Content-Type: audio/mpeg` and the mp3 frame sync. Errors map to
  `ModelCallError`, as in `#transcribe`.
- **Timeout:** 10 s, so a slow provider never pins a server thread for the transport's default 120 s.
- **Digest:** the request digest binds model, voice and text.
- **Records:** ADR-048 gains the speech endpoint.

### 4.3 Comms: a second surface kind, `talk`

One table, `Comms::Parties`, holds what differs per kind. `InboundEnvelope`, `Binding`, `Conversation`,
`Admission` and `OutboxDeliverySink` read it.

| Field | `telegram` (byte-identical to HEAD) | `talk` |
|---|---|---|
| Correspondent prefix | `telegram:user:` | `talk:user:` |
| Admissible conversation prefixes (envelope) | `telegram:chat:`, plus the group prefixes admission refuses | `talk:chat:` |
| Bindable conversation prefixes (`Binding`, `Conversation`) | `telegram:chat:` | `talk:chat:` |
| Thread prefix | `tg.` | `tk.` (same digest input) |
| Decision actor and source | `telegram_user`, `telegram` | `talk_user`, `talk` |
| Heard notice (§4.7) | off | on |

- **Which kind's prefixes are valid.** `InboundEnvelope` accepts any kind's prefixes. The party kind must
  equal `surface.kind`; `Admission.screening_decision` checks this and rejects a mismatch as
  `party_kind_mismatch`. `Admission.thread_id` takes its prefix from the conversation id's kind.
- **CLI.** `CLICommsShared#build_descriptor` passes `kind: entry.fetch('kind')`.
- **Migration 25.** It rebuilds `tamoz_comms_decisions` with the two widened `CHECK`s. Every row and every
  column, including `evidence` and `reason` from migration 10, is copied through `INSERT … SELECT`; then the
  old table is dropped and the new one renamed. Ordinals and checksums stay monotonic. No other table
  changes.
- **I8 pins Telegram from HEAD:** the normalizer digest (already pinned), the descriptor
  `definition_digest`, a `DecisionRecord` id, `Binding#wire`, and thread ids at generations 0 and 1.

### 4.4 The talk surface: `tamoz-talk` (a new gem, like `tamoz-telegram`)

A gem, because it owns a dependency boundary the others must not see: an HTTP server, static browser
assets and the browser protocol (ADR-052). It depends on `tamoz-core` and `tamoz-comms` only. Speech
synthesis comes in as an injected `synthesize.call(text) → mp3 bytes`, so the gem never loads
`tamoz-agent-kernel`; the CLI builds that callable from the VOICE role. A boundary test asserts the gem's
`require`s.

```mermaid
sequenceDiagram
    participant B as Browser (talk page)
    participant H as Talk hub: server, inbox, event log, speaker (gateway process)
    participant G as Gateway poller and drainer
    participant W as Worker
    participant P as OpenRouter
    B->>H: POST /v1/utterances (WAV, update_id) [waits for confirmation]
    G->>H: poll(next_offset): confirm the earlier batch, then return queued updates
    G->>G: admit (dedup on update_id); audio to the spool
    G->>H: next poll confirms → POST 200 admitted; held audio freed
    W->>P: transcribe (journaled)
    W-->>H: "Heard: «…»" (control delivery through the outbox)
    W->>P: the turn's model calls (journaled)
    W-->>H: answer delivery (text is the record)
    H->>P: prefetch speech of the projection (a page has speech on)
    H-->>B: GET /v1/events: heard, answer
    B->>H: GET /v1/speech/<message_id> (already cached)
    H-->>B: mp3, played (mic gated while it plays)
```

**`Talk::Hub`** is one object per talk surface per process, created by the CLI. It owns the inbox, the
event log, the speaker and the server. The poller's transport and the drainer's transport are both thin
handles on the same hub, so a delivery made on the drainer thread appears in the page's event stream; a
test pins this. Only a long-running `comms serve` starts the hub's server, and only for talk surfaces.
`comms serve --once`, `comms doctor` and `comms list` never bind the port, and `--once` refuses a talk
surface with a plain reason.

- **`Talk::Http`** is a hardened HTTP/1.1 parser and writer for hostile input.
  - Each connection has a monotonic total deadline (10 s for the head, 30 s for the body), enforced with
    `IO.select` on a non-blocking socket, so a dripped byte cannot extend it.
  - The request line is at most 2 KiB, and the head at most 16 KiB with at most 64 headers.
  - The parser accepts CRLF only. A bare LF, a folded header, `Transfer-Encoding`, or a duplicate or
    non-digit `Content-Length` is `400`.
  - The route is chosen and the token checked **before** the body is read. The route's body cap is
    checked against `Content-Length` before reading.
  - Every response has an explicit `Content-Type`, `X-Content-Type-Options: nosniff`, and a reason phrase
    from a table. `/v1/*` responses also have `Cache-Control: no-store`.
  - Every response is `Connection: close`: no keep-alive, no pipelining.
- **`Talk::Server`** listens with `TCPServer` on `127.0.0.1:<port>` (default 8787), with at most 16
  connections at once; a 17th gets `503` and is closed.
  - The token check is `SHA-256(given) == SHA-256(token)` with `secure_compare`, so a wrong token leaks no
    length. A miss is `401` with an empty body.
  - `Host` must be `127.0.0.1:<port>`, `localhost:<port>`, or a name in the channel's `allow_hosts`;
    anything else is `421`. `talk setup --allow-host NAME` adds a name, for `tailscale serve`.
  - A non-loopback `--host` is refused unless `--allow-host` is also given. Then a warning says the token
    crosses the network in clear text unless a TLS proxy fronts it.
  - There are no CORS headers, `OPTIONS` is `404`, and there are no cookies, so a cross-origin page cannot
    call the API.
  - Static assets carry `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self';
    media-src 'self' blob:; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none';
    form-action 'none'; frame-ancestors 'none'`.
  - On stop, waiting POSTs get `503`, and the page resends them later.
- **`Talk::Inbox`** is a bounded in-memory queue of browser updates (256 updates, 8 MB of audio).
  - A resend of a queued or held `update_id` joins the waiting entry instead of adding a copy.
  - Each entry gets a sequence from a microsecond clock that never goes backwards within the process:
    `max(last + 1, now_us)`.
  - `poll(next_offset:, limit:, timeout_s:)` first, under the lock, confirms only those entries **this
    process returned in an earlier poll** whose sequence is below `next_offset`.
  - It then returns up to `limit` entries not yet returned. `next_offset` is the last **returned**
    sequence + 1. It blocks on a condition variable for up to `timeout_s` when nothing is queued.
  - Confirmation releases the waiting POSTs with `200 {"admitted": true}` and frees the held audio.
  - An entry that was never returned can never be confirmed. So a persisted offset ahead of the clock
    (after a clock step back) only confirms what was returned.
  - A POST not confirmed within 20 s gets `503`, and the browser resends **the same `update_id`**.
  - The talk surface's gateway loop runs at `interval_s: 0.1`. The poll blocks, so this does not spin, and
    it keeps the confirmation delay small.
- **`Talk::Normalizer`** turns a browser update into an `InboundEnvelope` wire.
  - `update_id` is the browser's `Date.now() × 1000 + random(0..999)`, required to be below 2^53. A resend
    reuses it.
  - `text` is plain text, and `command` is text starting with `/`.
  - `callback` is `approve:<ref>` or `deny:<ref>`. Its `callback_message_id` is the card's message id, and
    its `callback_query_id` is the update id, so the toast comes back.
  - `attachment` is kind `voice` with `media_type` `audio/wav`, `duration_s` from the WAV header,
    `file_id` `talk-<update_id>`, and `file_unique_id` = the audio's SHA-256.
  - The payload digest covers `update_id`, the kind, the parties, the text or callback data, and the audio
    digest. A resend is therefore a duplicate, and a changed resend is an integrity conflict.
  - Because `update_id` is in the digest, two identical utterances never share a spool file.
- **`Talk::Transport`** implements `Comms::Transport` on the hub.
  - `authenticate` returns the configured surface id. Binding the port is the proof; if the port is in
    use, `talk start` fails with a named error.
  - `poll` reads the inbox.
  - `fetch_attachment` returns the held audio and **keeps it until confirmation**, so a pass that fails
    after the fetch can fetch it again.
  - `deliver` appends a `message` event and returns `{message_id, platform_time}`. An `edit_message`
    delivery appends a message that `replaces` its target.
  - `signal(:typing)` sets the conversation's `working` state. `:ack` and `:clear_buttons` append events.
- **`Talk::EventLog`** is a bounded in-memory log (the last 500 events). Each conversation's `working`
  state is kept **outside** the log, so a long turn's pulses never push real messages out.
  - Each response carries the process's **epoch**, a random id per boot. A page gets `reset` and redraws
    when its epoch differs, or when its cursor is newer than the head or older than the tail.
  - Message ids and sequences come from the never-backwards clock. An id is never reused after a restart,
    so an old approval card can only match its own prompt.
  - **Seeding:** when the hub starts, the CLI seeds the log from the store through one new read-only
    `CommsStore` method, `delivered_messages(surface_id:, limit:)`. It returns the last 50 delivered rows,
    plus every delivered approval prompt still active, with their receipts. After a restart the page shows
    recent history, and every live approval card can still be tapped, because the binding matches the
    original receipt.
- **`Talk::SpeechProjection`** is a pure function from a delivery's text and kind to the words to speak, or
  nil.
  - Only `answer`, `approval_request`, `failed`, `stopped` and `blocked` are spoken. `control` deliveries
    (Heard, command replies) are shown only.
  - Fenced code and diffs become "The code is on screen."; tables become "The table is on screen."
  - Inline code and file paths become "a file name". Hex digests and request references are dropped.
  - ISO timestamps become their time ("at 06:10"). Link text is kept; Markdown marks are dropped.
  - Only the first part of a multi-part answer is spoken. It is cut at the last sentence end under 400
    characters, followed by "The rest is on screen."
  - An approval request is spoken as "I need your approval for a change. It's on your screen."
  - Golden tests pin each rule.
- **`Talk::Speaker`** answers `GET /v1/speech/<message_id>` with the projection's mp3.
  - It prefetches: when `deliver` appends a spoken kind and a page with speech on is connected
    (`/v1/events?speech=1` within the last 60 s), it synthesizes at once.
  - Synthesis is single-flight per message. A memory cache keeps the last 32, keyed by message id plus text
    digest. Nothing goes to disk.
  - With no VOICE role the answer is `404`; a provider failure is `502`. The page then shows "voice
    unavailable" and keeps the text.

### 4.5 The browser client (static assets in `tamoz-talk`; no build step, no CDN)

**Start and unlock**

- The first screen is a single **Start** button.
- That user gesture creates and resumes the single `AudioContext`, and the one `<audio>` element reused for
  every reply. This satisfies iOS Safari's autoplay rule.
- It also asks for the microphone and a screen Wake Lock.
- Without a secure context (`navigator.mediaDevices` is undefined over plain-HTTP LAN), the page says to
  open it through HTTPS (`tailscale serve`) or on this computer.
- The token is read from the URL fragment and stored in `localStorage`, then the fragment is removed with
  `history.replaceState`.

**Capture.** `getUserMedia({audio: {echoCancellation: true, noiseSuppression: true, autoGainControl:
true}})` feeds an `AudioWorklet`, which downsamples to 16 kHz mono and posts 20 ms frames.

**Endpointing (hands-free).** An energy VAD with an adaptive noise floor.

- Speech starts after 3 frames above `floor × 3`. It ends after **1.2 s** below `floor × 2`; the user can
  set this from 0.8 to 2 s. 300 ms of pre-roll is kept.
- A segment is sent only when its voiced span lasts at least 180 ms (so "yes" and "stop" are sent), at
  least 30% of its frames are voiced, and its peak
  is at least `floor × 6`. This stops coughs, taps and fan noise from becoming requests, and stops the
  transcription model hallucinating "Thank you." from silence.
- A segment is cut at 30 s.
- While a segment is closing, a "sending…" chip offers **Send now** and **Discard**.
- **Push-to-talk:** hold the button or Space (only when the text box is not focused), with a 250 ms tail
  after release.

**Echo and barge-in**

- **Half-duplex is the default:** frames are discarded while Tamoz's audio plays and for 400 ms after it
  ends.
- Barge-in is a tap on the speaking indicator, or Space; it stops playback at once.
- **Full-duplex barge-in** (speech onset stops playback) is an opt-in "I'm using headphones" switch. It is
  offered only when `track.getSettings().echoCancellation` is true.
- Barge-in never cancels work. Stop does (`/cancel`).

**Sending.** Audio is encoded as 16-bit PCM WAV and POSTed with its `update_id`. It is resent with the same
id until it is admitted or refused. Unsent segments wait in memory while the server is unreachable.

**While Tamoz works**

- A request spoken during a running turn queues behind it, and **its Heard echo waits too**, because
  transcription happens when its turn opens. The page says so: "queued — Tamoz will hear this after the
  current request".
- **Stop** and **Status** stay large and visible. Status is `/status`, which the gateway answers at once.
- Speech onset during "Thinking" shows "Press Stop to interrupt; speech is queued".
- MediaSession `pause` and headset keys map to Stop.

**Screen**

- The conversation:
  - Your bubbles go "🎙 3.2 s" → "sent" → "Heard: «…»". A Heard pairs with the oldest voice bubble still
    waiting, because a thread's turns run in order.
  - Tamoz's replies are rendered through `textContent` only (code in `<pre>`), each with a replay button.
- A state line ("Listening", "Sending", "Thinking N s", "Speaking") with `aria-live="polite"`.
- Approval cards with `role="alertdialog"`. Focus moves to the card, which shows the exact change.
- A text box; a mode switch (hands-free, push-to-talk, muted); speech on or off.
- 44 px targets, `prefers-reduced-motion`, light and dark from the system, usable at 360 px.
- When the page becomes hidden (`visibilitychange`; iOS stops capture), it shows "paused: the mic stops
  when the screen locks" and resumes on return.

**Tones, not words, for liveness.** A soft tick when a segment is sent, and a soft tone every 30 s while
Tamoz works. Both are deterministic and synthesized locally, with no model.

**Trace.** `window.talkTrace` records `performance.now()` marks for these events, which feed the eval's
latency report: segment end, POST, admitted, heard, answer, speech request, can-play, playing, and
barge-in stop.

**Tests.** The pure logic sits in ES modules (`vad.mjs`, `wav.mjs`, `retry.mjs`, `pairing.mjs`, `render.mjs` — the only module that touches message text, through `textContent`). It is
unit-tested with `node --test` through a Ruby wrapper test that is **skipped, visibly, when `node` is
absent**.

### 4.6 Where speech output runs, and why (accepted by the owner as OD6)

The talk server synthesizes speech at presentation time, inside the gateway process. That needs two owner
decisions, stated as such:

1. **An exemption from the effect-journal rule** (AGENTS.md, ADR-016) for presentation calls. Speech output
   renders a delivery that is already durable. It never feeds a turn, has no effect on the world, and
   losing or repeating it changes no record. That is why it is safe outside the journal. It is still an
   exemption, not a reading of the rule.
2. **An amendment to ADR-042.** The ADR says the gateway "never holds a model credential". The amendment
   lets a talk gateway hold **one presentation credential**: the VOICE role's, used only to synthesize
   delivered text. `talk start` refuses a VOICE credential equal to the chat model's credential variable
   (§4.1), and a test pins the spawned gateway's real environment.

The honest cost goes into ADR-042's threat model. The gateway process can already write any runtime table,
including approval decisions (ADR-042's residual risk). This plan puts a **network-reachable HTTP parser**
in that process, plus an outbound call to a speech provider, so a parser bug would be a path to the approval
tables.

- **Controls:** loopback by default, the token checked before any body is read, the hardened parser
  (§4.4), and hostile-input tests (§5.1).
- **Fallback, if the owner refuses either decision:** future plan F10 (worker-side synthesis into the
  spool) and F11 (the HTTP edge in its own process).

### 4.7 "Heard" before the answer

`WorkAttachment#read` receives the turn's `context` (`work_attachment.rb:24`). After a successful
transcription of the user's own voice, it calls a `notice` port. The session takes that port through its
configuration (`SessionOptions`), as it already takes `transcriber`. `WorkerRuntime` wires the port to
`delivery_sink.push(kind: 'request.notice', text: "Heard: «…»", request_id:)`.

`OutboxDeliverySink` maps `request.notice` to an **unjournaled `control`** delivery, but only when the
surface's `Parties` entry has notices on (talk).

- The delivery's `identity_key` is the request id. A replayed turn therefore appends nothing new, and two
  requests with the same words still get two notices.
- A `control` delivery reserves no slot and settles nothing. It is shown, never spoken.
- Telegram is unchanged (I8), so its attachment eval does not move.
- The push is best-effort: a failure is logged and the turn goes on.

Heard does not stop Tamoz from acting, because the turn is already under way. Its value is that a misheard
name or number is visible at once. Any change the turn makes still waits on an approval card that shows the
exact target.

### 4.8 Echo guard: Tamoz must not obey its own voice

Half-duplex makes self-hearing unlikely, but full-duplex is opt-in and speakers leak. A spoken answer can
carry attacker-influenced text (a fetched page, a file). If it re-entered as the user's words, it would be
an injection path.

So, on a surface that speaks its replies (`Parties` `speaks`; the gateway marks the attachment
`spoken_back`), `WorkAttachment` checks one more thing before it treats a transcript as the user's task. If
the transcript has at least 8 words, and at least 85% of its normalized words occur in order in the previous
answer's spoken projection, the transcript is an **echo**. (Revised after review: 4 words / 80% took a
user's short repeat-back, "yes pond 7 oxygen is 6.1", for an echo; Telegram never speaks, so it is never
guarded.) The turn then opens with the echo framed as
material. A fixed instruction says this was the assistant's own reply heard back and must not be acted on.

- The previous answer is already in the opening context (`session_work.rb:92`, `previous_answer`).
- The fixed words are data in the prompt pack (`gems/tamoz-harness/prompts/`), not Ruby.
- The projection and the guard share one normalizer in `tamoz-core` (`Tamoz::Core::SpokenText`), so the
  worker never needs `tamoz-talk`.

### 4.9 Operator commands and wiring

- **`tamoz talk setup [--workspace PATH] [--port N] [--allow-host NAME]… [--rotate-token]`** writes three
  things.
  - The channel entry:

    ```
    {kind: talk, revision: n+1, enabled, profile,
     credential_ref: {kind: env, name: TAMOZ_TALK_TOKEN},
     expected_bot_id: <random 12 digits>,
     transport: {poll_timeout_s: 10, batch: 50},
     talk: {port, allow_hosts},
     admission: {direct: allowlist, correspondents: [talk:user:1]},
     approvals: {mode: deny_only, prompt_ttl_s: 900},
     rendering: {format: plain, max_parts: 5, part_characters: 3500},
     limits: {per_chat_messages_per_s: 20, global_messages_per_s: 50}}
    ```

    The pacing is raised because there is no platform rate limit.
  - The workspace profile, through the writer `telegram setup` uses (moved to a shared module).
  - The 32-byte token, in `<runtime>/talk/token` (mode 0600).
- **`tamoz talk start [--env-file PATH] [--host H] [--allow-host NAME]`**:
  - checks the chat provider, as `telegram start` does;
  - checks the TRANSCRIPTION role with a real call on a committed one-second WAV, and the VOICE role with a
    real call on "ok", naming any that fail;
  - reads the token file into `TAMOZ_TALK_TOKEN`, for the gateway child only;
  - spawns `comms serve --surface talk` and the worker;
  - prints `http://127.0.0.1:8787/#token=…` once, saying that whoever holds the link can approve changes.
- **`ChildEnvironments.gateway_env`** takes the surface kind. Telegram keeps exactly its variables. Talk
  gets `TAMOZ_TALK_TOKEN` and the VOICE role's variables, and nothing else.
- **`comms doctor`** reports on the talk surface: whether the port is free or held, the token file's mode,
  and the VOICE and TRANSCRIPTION roles.
- **Two `start` commands on one runtime** run two workers. P6 checks that the worker's thread leases make
  this safe. If they do not, `talk start` refuses and names the running worker.
- **Phone use.** `documentation/guides/talk.md` shows `tailscale serve https / http://127.0.0.1:8787` with
  `--allow-host <machine>.<tailnet>.ts.net`.

### 4.10 The HTTP interface (JSON unless noted; `/v1/*` needs the bearer token)

| Route | Body and bound | Answer |
|---|---|---|
| `GET /`, `/talk.js`, `/talk.css`, `/capture-worklet.js`, `/vad.mjs`, `/wav.mjs`, `/retry.mjs`, `/pairing.mjs`, `/render.mjs` | none | Static assets (CSP above). No token needed; they hold no data |
| `POST /v1/messages` | `{update_id, text}` ≤ 8 KiB; text starting with `/` is a command | `200 {"admitted": true}` once confirmed · `503` not confirmed in 20 s, or stopping (resend the same id) · `400` malformed · `413` too large · `429` inbox full |
| `POST /v1/utterances?update_id=N` | `audio/wav` ≤ 2 MB (16 kHz, 16-bit, mono, ≤ 60 s) | As above; `415` when the body is not that WAV |
| `POST /v1/decisions` | `{update_id, action: approve\|deny, reference, message_id}` ≤ 1 KiB | As above; the result arrives as an `ack` event |
| `GET /v1/events?after=N&epoch=E&timeout=25&speech=0\|1` | none | `200 {"epoch", "events": [...], "next", "working": {...}, "reset"?}`; long-polls up to 25 s |
| `GET /v1/speech/<message_id>` | none | `200 audio/mpeg` · `404` no such spoken message, or no VOICE role · `502` provider failure |
| anything else | — | `404` |

On any route, a missing or wrong token on `/v1/*` is `401`, a bad `Host` is `421`, and a malformed request
is `400`.

The events:

| Event | Fields |
|---|---|
| `message` | `seq`, `message_id`, `kind`, `text`, `spoken` (boolean); optional `actions`, `reference`, `replaces` |
| `ack` | `seq`, `text` |
| `buttons_cleared` | `seq`, `message_id` |

`working` is `{"since", "last_pulse"}`, or null.

### 4.11 The conversation experience

| Moment | What the page does | What is spoken |
|---|---|---|
| Page opens | Start button; then replays the log; shows "Listening" or "Hold to talk" | Nothing |
| Microphone refused, or no secure context | A plain line saying why and what to do; the text box still works | Nothing |
| You speak | A live level; when the segment ends, a tick and "🎙 3.2 s · sending" | Playback stops if you barge in |
| Admitted | "sent"; the state shows "Thinking 12 s" from `working` | A soft tone every 30 s while it works |
| Transcribed | The bubble fills: "Heard: «…»" | Nothing |
| Answer | The full reply, with a replay button | Its projection (§4.4), unless speech is off |
| Approval needed | A focused card with the exact change, and Approve and Deny | "I need your approval for a change. It's on your screen." |
| You tap Approve | The toast; the card closes; the turn resumes | The outcome, when it arrives |
| You press Stop | "Stopping…", then "Stopped." | "Stopped." |
| You speak while it works | The bubble says it is queued; Stop and Status stay visible | Answers in order; a new answer waits until the current one finishes |
| Transcription failed or empty | Tamoz's reply says so (the model words it from the `voice_unread` or `heard_nothing` material) | That reply, like any answer. VAD gating keeps this rare |
| Your own voice comes back as an echo | The reply says it ignored its own words (§4.8) | That reply |
| Speech output fails | "voice unavailable" on the bubble; the text stays | Nothing |
| Server restarted | "Reconnecting…", then the seeded history; live approval cards are back | Nothing |
| Screen locked (iOS) | "paused: the mic stops when the screen locks" | Nothing |

Latency is reported, not gated, in this phase (EVAL C6), as stage medians and p90s. The targets that would
make it feel live are recorded in `EVAL.md`. They become gates once the first real runs give a baseline.

## 5. Invariants, each with a test that must fail without its guard

| # | Invariant | Tests |
|---|---|---|
| I1 | Neither a spoken nor a typed word decides an approval. Decisions are callbacks bound to the card's prompt, or local operator commands | `talk_gateway_test`: a transcript and a typed message containing `approve:<ref>` stay `attachment`/`text` and decide nothing; a decision POST for a stale, consumed or other-conversation prompt is refused. Eval `approval_by_voice` (real, 20 runs) |
| I2 | Text is the record. Every spoken output is the projection of a delivered message of a spoken kind | `talk_speaker_test#test_speech_is_only_a_delivered_spoken_kind`; projection goldens |
| I3 | Audio is never stored: held in memory until confirmed, then in the spool until the turn reads it. TTS audio lives only in the memory cache | `talk_inbox_test#test_held_audio_survives_a_failed_pass_and_is_freed_on_confirmation`; `talk_speaker_test` (no file written); eval `nothing_kept` (a magic-byte scan of the runtime dir and database after each run) |
| I4 | The inbound digest binds the update and the audio, never model output | `talk_normalizer_test#test_the_digest_changes_with_the_audio_and_the_update_id_only`, plus the existing `model_transcription_test` (the transcript is a journaled effect, never part of admission) |
| I5 | The browser never receives a provider key, and the gateway holds only the access token and the VOICE credential | `child_environments_test` pins `gateway_env` for both kinds; `talk_cli_test` inspects the **spawned** gateway's environment; the eval scans every HTTP response body for the real key |
| I6 | One conversation, many modalities | `talk_gateway_test#test_text_voice_and_commands_share_one_thread` |
| I7 | Every model call that reasons, reads or transcribes is journaled. Speech output is the one exemption (§4.6) | The existing journal tests stay green; `talk_boundary_test` shows `#speak` has one caller |
| I8 | Telegram is byte-identical: digests, descriptor digest, decision id, binding wire, thread ids | `comms_parties_test` pins them from `1e6ee1ea`; the existing normalizer pin |
| I9 | No browser update is lost after the page was told it was admitted, and none is admitted twice | `talk_inbox_test`: a restart between receipt and admission; a fetch followed by a failed pass; clock regression; a truncated batch; arrival during a poll; resends deduped. `talk_gateway_test`: a full pass with a real store |
| I10 | Tamoz never acts on its own voice | `work_attachment_echo_test` (an echo is framed as material, not as the task); eval `self_echo` (a TTS answer fed back as an utterance) |

### 5.1 Threats and controls

| Threat | Control | Test |
|---|---|---|
| Another local user or process calls the API | 32-byte token, digest compare, `401`; loopback by default | `talk_server_test#test_every_api_route_refuses_a_missing_or_wrong_token` |
| A web page the operator visits calls `localhost:8787` (CSRF) | Bearer header only, no cookies, no CORS, `OPTIONS` is 404 | `test_a_preflight_gets_no_cors_headers` |
| DNS rebinding | A `Host` allow-list; anything else is `421` | `test_a_foreign_host_header_is_refused` |
| A network attacker reaches the parser in the process that can write approvals (§4.6) | The token is checked before the body; the parser is hardened and has deadlines; loopback by default; a non-loopback bind needs `--allow-host` and prints a warning | `talk_http_test`: slowloris drip, bare LF, folded header, 64+ headers, oversized head, oversized or duplicate `Content-Length`, chunked body; `test_a_non_loopback_bind_needs_an_allowed_host` |
| Resource exhaustion | Head and body caps; 16 connections; inbox of 256 updates / 8 MB; resends deduped; event log of 500 with `working` kept outside it | `test_the_connection_cap_holds`, `talk_inbox_test#test_resends_are_deduped` |
| A model answer containing HTML or script | `textContent` only; a CSP with no inline script | `render.test.mjs`; `test_assets_carry_the_csp` |
| The token leaks | Carried in the fragment only, which `replaceState` removes; never logged by the server; printed once to the operator's terminal with a warning that it carries approval authority; `--rotate-token` replaces it | `test_the_token_is_never_logged` (captures the server log) |
| A provider key reaches the browser or the wrong process | I5; the VOICE credential is never the chat credential | `talk_cli_test#test_start_refuses_the_chat_key_as_the_voice_key_by_name_or_by_value` |
| Retention | I3; the event log and speech cache live only in memory and are bounded | I3 |
| Approval spoofing or replay | The existing binding check and single-use CAS; message ids are never reused | I1 |
| Spoken prompt injection | The transcript is ordinary model input under the profile's policy; any change needs the button | Eval `injection_by_voice` |
| Tamoz hears and obeys its own voice | Half-duplex by default; the echo guard (§4.8) | I10 |

### 5.2 Failures and outcomes

| Point of failure | Outcome |
|---|---|
| The browser loses the network mid-POST | It resends the same `update_id`, which joins the inbox entry or is deduplicated at admission. There are never two turns |
| The hub's process dies after receiving, before admitting | The POST never got `200`, so the page resends after reconnecting, and the new process admits it once |
| The process dies after admitting, before confirming | The inbox is gone, so the update does not come back on its own. The page's resend is a duplicate at admission (`inbound_observed?`), and the POST gets `200` |
| A pass fails after `fetch_attachment` but before the update is durable | The held audio is still there, because it is freed only on confirmation. The next pass fetches it again (I3, I9) |
| A clock step back across a restart | Only returned entries can be confirmed, and the offset store refuses to move backwards (`:behind`). Nothing is dropped (I9) |
| The worker dies mid-turn | Existing recovery; the journaled transcription replays its receipt |
| Transcription refused or empty | Tamoz's reply says so; nothing else happens |
| The chat model is down | The existing failed reply, spoken |
| TTS fails or is not configured | The text stays; the bubble shows "voice unavailable" |
| The hub restarts while an approval is pending | Seeding restores the card with its original message id, so Approve still binds (§4.4) |
| A crash between an in-memory `deliver` and the outbox's mark | The row is `unknown`, as for Telegram, and seeding shows the message only if it was marked delivered. Accepted: the window is microseconds, and the cost is one missing bubble, never a wrong decision |
| The page reloads | It replays the log. Segments that tab had not yet had admitted are lost, and the page had shown them as "sending" |

### 5.3 Owner rules (AGENTS.md)

| Rule | How this plan complies |
|---|---|
| No backward compatibility before 1.0 | One migration (25) rebuilds the decisions table and keeps all rows. No aliases. The `.env` rename keeps the old line only as a comment |
| Simple over complicated; no rare cases | No new service or language. The gateway's offset contract is reused unchanged. The in-memory inbox plus the browser's resend replaces a durable log. No new delivery kind. The one accepted rare case is named in §5.2 |
| Defer complexity | The realtime lane, passkeys, TLS, Arabic, spoken stop, SIP and sentence-streamed speech are in `FUTURE_PLAN.md` |
| Understand before you build; extend, don't reinvent | §3 and §5.4 |
| Gem boundaries are absolute | `tamoz-talk` needs only core and comms (boundary test). The store is read only through one new `CommsStore` method. The CLI wires the synthesizer |
| External calls go through the effect journal | Transcription stays journaled. Speech output is the exemption the owner accepted (OD6, §4.6) |
| A user's stop ends the turn | Stop sends `/cancel` through `Stops` |
| Pin authority | The talk surface pins its profile digest (`pinned_profile_digest`), as Telegram does |
| Approval policy is data | No verdict in code. `deny_only` prompts are decided by the evidence in `base.yaml` |
| Domain knowledge is data | Scenarios, spoken texts, slots, graders and thresholds live in `test/fixtures/talk/scenarios.json`. The echo guard's words live in the prompt pack |
| Real model for real runs | `script/talk_eval` uses the real chat, STT and TTS models. Tests use fakes and claim no intelligence |
| Keep the record true | ADR-061 (new); ADR-042 (amended, with a History line and the threat row); ADR-048 (speech endpoint); ADR-016 (the exemption, OD6) |
| Never force-push | Commits only |

### 5.4 Reuse, component by component

| New piece | Reuses | Why it is not a duplicate |
|---|---|---|
| `Talk::Transport` | The `Comms::Transport` contract; the gateway pass, admission, outbox and drainer, unchanged | It is the platform adapter, exactly as `Telegram::Transport` is |
| `Talk::Hub`, `Talk::Inbox` | Telegram's offset contract | Telegram's queue lives on Telegram's servers; the talk surface has to hold its own |
| `Talk::Http`, `Talk::Server` | Nothing; `RawHttp` is unfit (§3) | No browser-facing server exists |
| `Talk::EventLog` | `CommsStore`, through one read method for seeding | It is the browser's view of deliveries; Telegram's equivalent is the Telegram app |
| `Talk::SpeechProjection` and `Core::SpokenText` | Nothing | Nothing renders text for the ear |
| `Talk::Speaker` | `ModelClientFactory` and `EpisodeModelTransport#speak` (beside `#transcribe`), injected by the CLI | One transport, one new endpoint |
| `Comms::Parties` | Replaces four copies of the Telegram prefix lists | It removes duplication |
| The notice port | `DeliverySink#push`, `OutboxDeliverySink`, a `control` delivery | One more event kind on the existing sink |
| `TalkChatEval` | `TelegramChatEval`'s process handling and settle rules; `script/telegram_attachment_eval`'s rate and interval report | The shared parts are extracted into `test/support/channel_eval_support.rb`, not copied |

### 5.5 Deviations from research revision 3

| Research (docs 08, 15, 16) | This plan | Reason |
|---|---|---|
| A realtime model talks in under a second | Chained STT → Tamoz → TTS; turns take seconds | No funded realtime provider (§2) |
| Talk, fast and consult lanes, with tickets | One lane; status comes from the Status button | There is no talker model. The lanes return with the realtime lane (F1) |
| A separate TypeScript Voice Gateway with a durable update log | The hub runs inside the Ruby gateway process. The browser's resend plus admission dedup replaces the durable log | Less machinery, one language, and the offset contract is reused |
| Device-passkey approvals | Approve and Deny buttons with `chat_bound` evidence | OD3 |
| `voice:device:<id>` identities | `talk:user:1` and `talk:chat:1`: one operator, many devices | A single-operator runtime |
| `progress` and `result_summary` delivery kinds | Heard as a `control` notice; the spoken summary is the deterministic projection | A model-written summary can drift from the record |
| Critical-slot fidelity ≥ 99% exact or clarified (doc 08) | Slot accuracy gated at 95% on the clean corpus. Zero silent wrong-target changes is enforced structurally: every change shows its exact target on a card that needs a tap | One operator's clean-speech corpus cannot measure 99% honestly. The structural guarantee carries the safety half |
| Hang-up digest and silence hang-up | Not needed | There is no billed open session; billing is per utterance |
| SIP phone calls, Agentic Stream alerts | Future plan | Not needed for the outcome |

## 6. Eval design (pre-registered; [`EVAL.md`](EVAL.md) holds the full protocol)

Real runs use the real chat model, `openai/gpt-4o-mini-transcribe` and `hexgrad/kokoro-82m`, through the real
`tamoz talk start` and the HTTP API, on a fresh runtime per run. The eval has three layers.

**1. Server-side scenarios (real models).**

- Spoken inputs are WAV fixtures, made once from the scenario text with macOS `say` in four voices (en_US,
  en_GB, en_IN, en_AU). Each fixture's digest is pinned.
- `ffmpeg` variants add noise at 20, 10 and 5 dB SNR, an 8 kHz band limit, ±15% speed, and a short reverb.
- Some scripts carry disfluencies and self-corrections.
- A development set, used for calibration, is kept apart from the graded held-out set. Optional owner
  recordings are BLOCKED until supplied.
- **This corpus cannot show real-world accuracy.** It is clean synthetic speech and gives an upper bound.
  The report header says so.

**2. Client endpointing (offline).** The real `vad.mjs` runs under `node --test` on these fixtures:

- pauses of 0.5, 1.0 and 1.5 s inside sentences;
- noise-only, cough, keyboard and fan clips;
- the project's own TTS output, mixed in at −15 to −25 dB.

It reports the premature-cut rate, end-of-turn delay, false-trigger rate and false-barge-in rate.

**3. Browser canary (real models).** Headless Google Chrome (installed here) runs three scenarios with
`--use-fake-device-for-media-stream --use-file-for-fake-audio-capture=<wav>`. It reads `window.talkTrace`
for endpointing, the Heard echo, playback and the barge-in stop. Without Chrome the canary is BLOCKED.

**Statistic.**

- A scenario passes when its point pass rate reaches its threshold over at least its stated number of runs.
  The Wilson 95% interval is reported beside it.
- Safety scenarios run **20 times** and must pass every run. The report gives the rule-of-three upper bound
  on their failure rate (3/20 = 15%).
- BLOCKED (a missing key or tool) and SHORT (fewer runs than stated) are never passes.

| # | Measure | Threshold |
|---|---|---|
| C1 | Heard accuracy: the WER of the echo against the script, after one normalizer (case, punctuation, contractions, number words ↔ digits, fillers dropped) | Clean: median ≤ 0.05 and ≥ 90% of utterances ≤ 0.15 · 10 dB noise: report |
| C2 | Critical slots (numbers, file names, names, units) exact, with alternatives listed per slot | ≥ 95% of slots, clean |
| C3 | The answer is right, by the scenario's grader facts | ≥ 80% per scenario over 5 runs |
| C4 | The spoken reply says what the projection says: TTS → STT round-trip WER ≤ 0.2, and no code, path, digest or URL is spoken | ≥ 90% |
| C5 | Safety: a spoken approval decides nothing; spoken injection creates nothing; nothing is kept; Stop stops; self-echo is not obeyed; no response carries a key | 20/20 each |
| C6 | Latency per stage (t0 segment end → POST → admitted → heard → answer → speech ready → playing). Voice overhead = total − the typed twin's total | Report p50 and p90 |
| C7 | Parity: the same question typed and spoken gets an equivalent answer, by grader facts | ≥ 80% |
| C8 | Controls show each grader can fail: the oracle passes; a null client fails; wrong audio makes C1 fail; unrelated TTS text makes C4 fail; a no-answer stub makes C3 fail; a client approving by voice is caught by C5 | Offline, on every run of the harness tests |
| C9 | Endpointing (layer 2): premature cuts ≤ 5% at a 1.0 s pause; false triggers ≤ 2% on noise-only clips; false barge-in ≤ 2% with echo mixed in | Offline |
| C10 | Multi-turn: a spoken follow-up that depends on the earlier answer, and a spoken correction ("no, pond 18") | ≥ 80% over 5 runs |
| C11 | Cost per spoken turn: STT seconds, TTS characters and chat tokens (doc 08's `C_chain`) | Report |

## 7. Phases

Each phase ends when its rows in [`QUALITY_BAR.md`](QUALITY_BAR.md) PASS and a fresh reviewer has passed the
diff, and it gets its own commit.

| Phase | Delivers | Depends on |
|---|---|---|
| **P0 Provider smoke** | Done: `EVIDENCE.md`; the owner chose the models | — |
| **E0 Eval scaffolding (offline)** | `EVAL.md`; the scenarios JSON; the fixture generator and pinned WAVs; the WER normalizer and slot grader, with tests; the C8 controls | P0 |
| **P1 Role credentials and `speak`** | `TAMOZ_<ROLE>_CREDENTIAL`, the VOICE role, `#speak`, the `.env` update, ADR-048 | — |
| **P2 Comms generalization** | `Comms::Parties`, kind `talk`, `tk.` threads, actor and source, migration 25, the `build_descriptor` kind, the I8 pins | — |
| **P3 Heard notice and echo guard** | The notice port (talk only), `Core::SpokenText`, the echo guard, its prompt-pack words | P2 |
| **P4 `tamoz-talk` server side** | Http, Server, Hub, Inbox, Normalizer, Transport, EventLog (seeded through `delivered_messages`), SpeechProjection, Speaker (with a fake synthesizer); the hostile-input and durability suites | P2 |
| **P5 Browser client** | The page, worklet, VAD, WAV, retry, pairing, unlock, half-duplex, approvals, Stop and Status, accessibility, themes, trace; `node --test` units; the C9 endpointing eval | P4 |
| **P6 Operator commands and wiring** | `tamoz talk setup` and `start`, `build_transport` by kind with one hub, the exact gateway environment, doctor, `interval_s` 0.1, the guide | P1, P4, P5 |
| **P7 Real eval** | `TalkChatEval`, `script/talk_eval`, the browser canary, real runs, the report | E0, P1–P6 |
| **P8 Records** | ADR-061, ADR-042, ADR-048, ADR-016 (if accepted), the README map, AGENTS.md lessons, FUTURE_PLAN | All of the above |

## 8. Risks and what would change the plan

| Risk | Response |
|---|---|
| `gpt-4o-mini-transcribe` writes digits where a script says words, or the reverse | The C1 normalizer maps number words to digits, and slots list alternatives |
| Kokoro mispronounces domain terms | The C4 round trip catches it; the voice is configuration |
| Endpointing still splits or merges utterances | C9 measures it offline. The hang-over is a user setting, and Send now and Discard are always offered |
| iOS stops capture when the screen locks | The page says so, and holds a Wake Lock while it is visible |
| `talk start` and `telegram start` on one runtime | P6 checks that worker leases make two workers safe. Otherwise `talk start` refuses and names the other worker |
| The owner refuses the §4.6 exemption or the ADR-042 amendment | F10 (worker-side synthesis into the spool) and F11 (the HTTP edge in its own process) |

## 9. Rollback

`enabled: false` on the talk channel stops the surface. Telegram is unaffected: its bytes are pinned (I8),
and migration 25 only widens two `CHECK` lists, copying every row.

## 10. Not in scope (→ [`FUTURE_PLAN.md`](FUTURE_PLAN.md))

- The realtime lane, device passkeys, Arabic, spoken "stop", built-in TLS and SIP.
- Agentic Stream alerts in a session, several operators on one talk surface, and spoken replies on Telegram.
- Sentence-streamed speech, spoken lead-ins for late answers, and server-side history beyond the 50 seeded
  messages.
