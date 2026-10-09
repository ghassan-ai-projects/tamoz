# tamoz-talk

The browser talk channel for Tamoz: one gem implementing the `Tamoz::Comms::Transport` seam over a
hardened stdlib HTTP server and the talk page (ADR-061). Depends only on `tamoz-core`, `tamoz-comms` and
the standard library. Speech synthesis is injected (`synthesize: ->(text) { mp3_bytes }`), so the gem
never loads a model client; `tamoz talk start` builds it from the VOICE role.

## Facade

- `Tamoz::Talk::Hub.new(descriptor:, token:, synthesize: nil, floor: 0, host: '127.0.0.1')` — one talk
  surface in one process. `#start` binds the server, `#transport` returns a `Comms::Transport` handle
  (the gateway poller and the delivery drainer each take one), `#seed(rows)` restores delivered messages
  from `CommsStore#delivered_messages`, `#stop` releases waiting requests with 503.

## What it guarantees

- **Admission is confirmed, not assumed.** A POST waits until a later `poll` confirms the batch it came in
  (Telegram's offset contract); an unconfirmed update is handed out again; the page resends the same
  `update_id`, and admission dedup makes that harmless.
- **Audio is never stored.** It is held in memory until confirmation; the gateway moves it to the
  attachment spool; speech output lives in a bounded memory cache.
- **Only the token holder reaches the API.** Bearer token compared by digest, `Host` allow-list, no CORS,
  no cookies, CSP on the page, strict HTTP parsing with deadlines and caps.
- **Text is the record.** Speech is the deterministic projection (`Tamoz::Core::SpokenText`) of a delivered
  message of a spoken kind.

Routes, events, limits and the page's behaviour are in `docs/talk-voice-2026-10-09/PLAN.md` §4.4–§4.11.
