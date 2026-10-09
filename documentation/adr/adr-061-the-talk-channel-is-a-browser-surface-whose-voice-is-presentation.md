# ADR-061 — The talk channel is a browser surface; its voice is presentation, its record is text

**Status:** Accepted 2026-10-09
**Date:** 2026-10-09
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-041](./adr-041-communication-channels-are-a-contract-gem-plus-per-transport-adapter-gems.md) (a second transport gem), [ADR-042](./adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md) (the process it runs in, and the speech credential it may hold), [ADR-016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) (speech output is presentation, not an effect), [ADR-049](./adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md) (approval stays a bound button)

The operator talks to Tamoz from a browser page. To Tamoz the page is a channel like Telegram: a
`talk` surface whose transport is a small HTTP server inside the gateway process. Speech is
transcribed by the worker as a journaled effect and becomes the user's words; replies are text first
and spoken second, as a deterministic projection of the delivered text.

## Context

The owner wants voice conversation with Tamoz without Telegram shaping it (research revision 3,
`docs/talk-voice-2026-10-09/PLAN.md`). The only funded speech provider, OpenRouter, offers speech-to-text
and text-to-speech but no realtime speech model, so a sub-second talker is not available; turns take
seconds. Tamoz already has a governed channel path — admission, dedup, one thread per conversation,
`/cancel`, approval buttons — and a journaled transcription path for Telegram voice notes.

## Decision

- **A second surface kind.** `Comms::Parties` holds what differs per kind (identity prefixes,
  `tg.`/`tk.` thread prefix, whether the surface speaks). Admission refuses a party of another kind;
  Telegram's digests, thread ids and decision ids are byte-identical (pinned).
- **The transport is `tamoz-talk`.** A hardened stdlib HTTP server (deadlines, caps, CRLF only, the
  token checked before any body is read, a `Host` allow-list, no CORS, CSP), an in-memory inbox whose
  entries are confirmed only by a later poll with an offset it handed out (Telegram's contract, so the
  gateway is unchanged), and an event log the page long-polls. The browser resends an unconfirmed
  update with the same id; admission dedup makes that harmless. Audio is held in memory until
  confirmed, then handed to the worker through the attachment spool; it is never stored.
- **Speech in is the user's words.** The worker transcribes the WAV as a journaled effect
  (`TAMOZ_TRANSCRIPTION_*`), shows "Heard: «…»" on speaking surfaces, and treats a transcript that is
  most of its own last spoken reply as an echo — framed material, never a request.
- **Speech out is presentation.** `Tamoz::Core::SpokenText` projects a delivered message of a spoken kind
  into words (no code, paths, digests or URLs; a sentence-bounded cut). The talk server synthesizes it
  with the VOICE role (`TAMOZ_VOICE_*`) when the page asks, caches it in memory, and never stores it.
- **Approval stays a button.** A spoken or typed "approve" is a request, never a decision; decisions
  are callbacks bound to the card's prompt and message id (ADR-049, `chat_bound`).

## Consequences

Voice gets every channel guarantee Telegram has, with one small HTTP surface and no new service.
**Cost:** turns take seconds (no realtime model); the gateway holds the speech credential and a
network-reachable parser (ADR-042's threat model); the page's history lives in memory, seeded from the
outbox on restart.

## Invariants

- 56 — a user channel is identified, bound, and grants nothing.
- 57 — channel delivery is ordered, bounded, and ambiguity-safe.

## Threat model

**Asset:** approval authority, the conversation, provider keys. **Adversary:** another local process or
network peer, a web page in the operator's browser, a model answer carrying markup, the operator's own
speaker.

| Threat | Mitigation |
|---|---|
| An unauthenticated caller | 32-byte token, compared by digest, checked before any body is read; loopback by default |
| A web page calls the API (CSRF) or rebinds DNS | Bearer header only, no cookies or CORS; `Host` allow-list (421) |
| Hostile HTTP input | Deadlines per head and body, caps on line, head, headers, body and connections; `Transfer-Encoding`, bare LF and duplicate identity headers refused |
| A spoken "yes" approves | Only a callback bound to an active prompt decides |
| Tamoz obeys its own voice | Half-duplex by default; the echo guard frames its own reply as material |
| Markup in a reply runs in the page | Text is set through `textContent` only; CSP forbids inline script |
| Audio kept | Memory until confirmed, then the spool until read; speech output in a bounded memory cache |

**Residual risk:** whoever holds the link can approve changes; the link is printed once to the
operator's terminal and can be rotated (`tamoz talk setup --rotate-token`).

## History

- 2026-10-09 — Accepted (owner decisions OD1–OD6, `docs/talk-voice-2026-10-09/PLAN.md` §2).
