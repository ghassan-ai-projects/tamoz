# Experience harness — mock Telegram for agent-driven chat sessions

Design + evidence rules + build acceptance for two harnesses that let an agent
(or a person) drive a simulated Telegram chat session against the **real**
Tamoz runtime, to find and feel the chat issues instead of inferring them. This
is planning — no code. Building is bounded by the acceptance criteria below.

## Why

The deferred "experience spike" needs a real transport or a stand-in. A real bot
adds token, network, and privacy friction. A mock transport removes all three
while keeping the real gateway → worker → outbox → drainer chain, so an agent
can actually converse and report the 15 issues as *felt*. Real DeepSeek supplies
the intelligence; only the transport is simulated.

## The seam this plugs into (verified)

`Comms::Gateway.new(adapter:, checkpoints:, transport:, descriptor:, drainer:)`
takes an **injectable transport** and builds its `DeliveryDrainer` from it
(`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb:104-124`); `serve_once`
polls that transport and drains through it (`:175,:202`). Both harnesses inject a
transport at this one seam. **No runtime code changes** — this respects the
study's "no second runtime" hard-zero.

Two mocks already exist to extend:
- `FakeTransport` (`test/support/openclaw_comms_fixture.rb:78`) — in-process,
  implements `poll`/`deliver`/`signal`, normalizes raw updates via the real
  `Telegram::Normalizer`, records `sends`, supports fault injection. Today it
  serves a fixed `batch`, not a live queue.
- `TelegramFixtureServer` (`test/support/telegram_fixture_server.rb`) — a local
  HTTP Bot-API server (getMe/getUpdates/sendMessage…) with duplicate/reorder/
  throttle/drop/delay. Today it serves scripted responses, not a live queue.

---

## Harness A — in-process (agent lives in the chat)

**Purpose:** the fastest way for an agent to hold a multi-turn conversation and
critique the experience. No network, no HTTP.

**Extension to `FakeTransport` (small, test-support only):**
- a thread-safe **inbound queue**: `enqueue(raw_update)`; `poll` drains up to
  `limit` and advances the offset correctly;
- **inbound builders**: `user_message(text, reply_to: nil)` and
  `callback(data, message_id:)` that produce raw Bot-API update hashes (so the
  real normalizer runs, including `reply_to_message.message_id` for I1
  reply-binding);
- a **read side**: `outbound` (already `sends`) plus `last_card` / `wait_outbound`.

**Driver / REPL (`ExperienceHarness`, new test-support + `bin/tamoz-chat-sim`):**
- constructs the real runtime (gateway + worker + store) with the extended
  `FakeTransport`, using the launcher's env discipline (`TAMOZ_PROVIDER=deepseek`,
  `DEEPSEEK_API_KEY` from `.env`, UTF-8 locale — see
  `running-tamoz-agent-locally`);
- API: `say(text)`, `reply(text)` (binds to the last question message), `tap
  (data)`, `pump` (one `serve_once` + worker turn + drain), `transcript`
  (ordered inbound + outbound);
- `bin/tamoz-chat-sim` opens a stdin loop: each line is a user message, each bot
  card is printed — so **an agent drives it over `Bash`** (line-by-line or a
  heredoc) and reads the replies.

**Exercises:** the full admission → worker → projection → delivery chain, the
real normalizer, clarify/approval/cancel/redirect/status flows, reply-binding
(I1), disambiguation (I2), and — with real DeepSeek — actual answers.

**Does NOT exercise:** real HTTP transport behavior (long-poll offsets on the
wire, real send/edit/callback receipts, rate limits). Use Harness B for those.

---

## Harness B — local Bot-API server (transport fidelity)

**Purpose:** validate the transport-level claims Harness A cannot — the study's
real-transport gap (G13) — without a real bot.

**Extension to `TelegramFixtureServer`:**
- a **live mode**: `getUpdates` serves from an injectable inbound queue and
  returns correct offsets/long-poll semantics; `sendMessage`/`editMessageText`/
  `answerCallbackQuery` **record** calls and return realistic receipts
  (`message_id`, `date`, and the edited message id);
- inject/read helpers: `enqueue_user_message`, `enqueue_callback`,
  `outbound_calls`;
- keep the existing fault modes (throttle with `retry_after`, timeout, drop) for
  resilience runs.

**Driver:** the **real** `Tamoz::Telegram::Transport` + gateway/worker run
against `server.url` (as the transport tests already do), driven by the same
`ExperienceHarness` API so a session script runs unchanged on A or B.

**Exercises:** getMe, long-poll offset confirmation, real send/edit receipts,
`answerCallbackQuery` ordering/latency, rate-limit/timeout handling — i.e. the
transport realism EG-5 needs, short of a real bot.

**Does NOT replace:** the final real-Telegram/real-bot gate (EG-5) for
production evidence. A local server is high fidelity but is still not
api.telegram.org.

---

## Evidence discipline (non-negotiable)

- Mocking the **transport** is fine for exercising the chat and letting an agent
  experience the UX.
- Judging the **experience/answers** requires **real DeepSeek** (per the
  real-LLM rule). Mock transport + real DeepSeek = a legitimate experience
  harness (transport simulated, intelligence real).
- Mock transport + **deterministic provider** = plumbing only. It is **never**
  intelligence or "the chat is good" evidence, and **never** the real-Telegram
  gate.
- Every harness run records: provider/model, transport kind (in-process /
  local-server / real), and whether the model was real or deterministic. A run
  that cannot state these is not usable evidence.

## How this maps to the plan

- Harness A + real DeepSeek **is** the deferred experience spike, minus the
  credentials — it needs only the `DEEPSEEK_API_KEY` already in `.env`. It is the
  tool to walk `04-user-issue-discovery.md`'s 15 issues live and confirm which
  bite hardest, and to check I1–I5 as they land.
- Harness B partially closes EG-5's transport-realism gap ahead of a real bot,
  and can host EG-3's callback-ack/edit-receipt observations.
- Both reuse the real gateway/worker/outbox/drainer — no second runtime, no
  status cache, no narrator.

## Build acceptance (so building later is bounded)

**Harness A is done when:** an agent can script a multi-turn session via
`bin/tamoz-chat-sim`; the bot cards for accepted / working / waiting-clarify /
completed are captured in `transcript`; a `reply` to a clarification resumes the
same occurrence (I1); a bare `/cancel` with two open requests disambiguates
(I2); real DeepSeek produces the answer; and the run records provider +
transport kind. No network is used.

**Harness B is done when:** the real `Telegram::Transport` completes getMe /
long-poll getUpdates / sendMessage / editMessageText / answerCallbackQuery
against the local server; offsets advance correctly; callback ack and edit
receipts are observed; and the throttle/timeout/drop fault modes behave. The
same session script that runs on A runs on B unchanged.

## Non-goals

- Not a second runtime, event bus, status cache, or model narrator.
- Not a replacement for the real-bot gate (EG-5) in production evidence.
- Harness A is not transport evidence; a deterministic-provider run on either
  harness is not intelligence evidence.
