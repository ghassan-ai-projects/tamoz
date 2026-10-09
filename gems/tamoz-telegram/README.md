# tamoz-telegram

The Telegram transport adapter for Tamoz (ADR-041): one gem implementing the
`Tamoz::Comms::Transport` seam over the Telegram Bot API. Depends only on
`tamoz-comms` and the standard library — no HTTP client gem.

## What it does

- `authenticate` — `getMe` (wrong token → `AuthenticationError`, never a retry)
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
