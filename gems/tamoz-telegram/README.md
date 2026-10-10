# tamoz-telegram

The Telegram channel for Tamoz (ADR-041): every line of Telegram code, behind the
`tamoz-comms` interfaces. Depends only on `tamoz-comms` and the standard library — no
HTTP client gem.

- `Tamoz::Telegram::Transport` — the `Comms::Transport` over the Bot API
- `Tamoz::Telegram::Channel` — validates a descriptor (no speech; only `bot_username` in
  `settings`) and connects one transport that the gateway and its drainer share; its update
  stream is `telegram:bot:<id>`
- `Tamoz::Telegram::Setup` — `tamoz channel add telegram` (pairing by message, then confirming
  Telegram's whole backlog), the token, bot-id and webhook checks that `start` and
  `comms doctor` run, and the variables its gateway holds (`TAMOZ_TELEGRAM_BOT_TOKEN`, and
  `TAMOZ_TELEGRAM_API_ORIGIN`, accepted only as a loopback stand-in)

## What it does

- `authenticate` — `getMe`, returned with its `stream_id` (wrong token → `AuthenticationError`, never a retry)
- `poll` — `getUpdates` with the candidate `next_offset` confirming the prior
  durable prefix remotely; `allowed_updates` is always supplied explicitly
- `deliver` — exactly one `sendMessage`/`editMessageText` per `Delivery`; a
  timeout on a send becomes `AmbiguousDeliveryError` (genuinely irreconcilable,
  design §10) and is never retried blindly
- `signal` — `answerCallbackQuery` (ephemeral, unjournaled)
- `fetch_attachment` — `getFile`, then the bytes from `/file/bot<token>/<file_path>`: the path is
  validated, the body bounded by the caller's `max_bytes` and a download deadline, and Telegram's
  "file is too big" read as `ResponseTooLargeError`. The normalizer turns a document, photo, voice note
  or audio file into a bounded `attachment` envelope (a forwarded voice note is `audio`)

## Conformance

The test suite drives every method against an in-memory fixture server
(`test/support/telegram_fixture_server.rb`) that can duplicate, reorder,
throttle, lose, and time out — the `tamoz-comms` conformance conditions.
