# Talk with Tamoz by voice: future plan

Work deliberately left out of [`PLAN.md`](PLAN.md) (AGENTS.md: defer complexity). Each item has a design
sketch, the tests that would prove it, and the decision it waits on. None is built.

## F1. The realtime talk lane (sub-second turns, barge-in mid-word, tickets)

- **Design:** research doc 15. A realtime speech model (OpenAI `gpt-realtime` over WebRTC, or Gemini Live)
  talks; `consult(question)` returns a ticket at once and the answer is spoken at the next pause; the fast
  lane answers "what are you doing" from the event log. The talk server mints the provider's ephemeral
  client secret, so the key stays server-side. The `consult` tool posts to `POST /v1/messages` exactly as
  typed text does, so Tamoz is unchanged.
- **Tests:** research doc 16 gates G1–G6 (responsiveness p50 ≤ 0.8 s, barge-in ≤ 250 ms, zero unsupported
  spoken claims, ticket flow, parity, 30-minute stability).
- **Waits on:** a funded realtime provider key (OpenRouter has no realtime API as of 2026-10-09).

## F2. Device-passkey approvals

- **Design:** WebAuthn registration at pairing; the challenge is `SHA-256(domain ‖ nonce ‖ approval_id ‖
  action_digest ‖ request_revision ‖ expires_at)`; a new `device_passkey` level in `AuthorityEvidence`,
  minted only by assertion verification.
- **Tests:** research doc 16 P1 tests 3–5 and gate G8 (stale, forged, replayed or expired assertions are
  rejected).
- **Waits on:** the owner placing `device_passkey` in the lattice (ADR-049); WebAuthn needs HTTPS (F4).

## F3. Arabic (and other languages)

- **Design:** no code change for input (qwen3-asr detects the language); add the language hint and a
  spoken-projection check per language; choose a TTS voice per language.
- **Tests:** EVAL C1–C4 per declared language and dialect, with native-speaker recordings, not `say`.
- **Waits on:** the dialects to trial and consenting speakers.

## F4. Built-in TLS for phones without Tailscale

- **Design:** `tamoz talk setup --tls` makes a private CA and a server certificate (OpenSSL stdlib); the
  operator installs the CA on the phone once.
- **Tests:** handshake test; refused plain HTTP when TLS is on.
- **Waits on:** evidence that `tailscale serve` is not enough.

## F5. Spoken "stop"

- **Design:** needs a recognizer that runs before the turn (streaming STT in the talk server, or the
  realtime lane F1). A transcript that is exactly a stop phrase becomes `/cancel` (fail-safe, like deny).
- **Tests:** false-trigger rate on 100 non-stop utterances ≤ 1%; every stop phrase stops.
- **Waits on:** F1 or a streaming STT endpoint.

## F6. Phone calls (SIP)

- **Design:** research doc 16 P5: the provider's SIP webhook, the same controller, caller ID plus a spoken
  PIN for read-only use, approvals on the paired page.
- **Waits on:** F1.

## F7. Agentic Stream alerts spoken in a session

- **Design:** wire `OutcomeSubscriber` into the talk surface's event log; the interjection rules in
  research doc 15.
- **Waits on:** a named operational workflow.

## F8. Full page history beyond the seeded 50 messages

- **Design:** revision 2 already seeds the last 50 delivered messages and every live approval card on hub
  start (`CommsStore#delivered_messages`). Scrolling further back would page through that method.
- **Waits on:** an operator wanting it.

## F9. Spoken replies on Telegram

- **Design:** research doc 13 (`sendVoice`, the same projection and `Talk::Speaker` logic moved to a shared
  place).
- **Waits on:** the owner wanting it; nothing in the talk plan depends on it.

## F10. Worker-side speech synthesis (the fallback if the ADR-042 amendment is refused)

- **Design:** the worker synthesizes the projection as a journaled `model.speak` effect after the text
  answer, writes the mp3 to the attachment spool under the delivery id, and the talk server serves it once
  and deletes it.
- **Cost:** speech is paid for even when nobody listens, and the spoken reply lands later.
- **Waits on:** the owner's answer to the ADR-042 amendment.

## F11. The HTTP edge in its own process

- **Design:** move `Talk::Server` and the hub into a third process that holds only the access token. It
  talks to the gateway over a loopback socket using the transport shape. A parser bug then reaches a process
  that cannot write the runtime database.
- **Waits on:** the owner judging the ADR-042 threat row (PLAN §4.6) too costly, or the surface leaving
  loopback for real.

## F12. Sentence-streamed speech

- **Design:** split the projection into its first sentence and the rest; synthesize both in parallel and
  play them in order, so the first audio arrives about twice as fast for long answers.
- **Tests:** the C6 "speech ready" stage halves for answers of more than one sentence; the order is never
  wrong.
- **Waits on:** C6 showing that first-audio time matters after prefetch.

## F13. Spoken lead-ins for late or queued answers

- **Design:** when more than one answer is pending, or one arrives more than 30 s after its question,
  prefix the projection with "About «first words of Heard»:".
- **Waits on:** an owner trial showing that queued answers are confusing.

## F14. Live speech is not a "voice message"

Seen in the owner's first live session (2026-10-09): on the talk page Tamoz says "I got your voice message",
because the shared attachment prompt (`gems/tamoz-harness/prompts/attachment_text.json`, `voice`) frames every
transcript as a Telegram-style voice note. Design: a `talk` variant of the `voice` label chosen by the surface kind
(`Parties#speaks`), with the prompt-pack pin updated. Test: the talk turn's opening material uses the talk label;
Telegram's is byte-identical. Open: whether one neutral wording ("what the user said") serves both surfaces.

## F15. Pair Heard and replies to the utterance that caused them

Found in review (2026-10-09): the page pairs a Heard notice and a final reply with the oldest open bubble.
An utterance the gateway refuses after the inbox confirmed it (open-request limit, integrity conflict)
gets only a control notice, so its bubble stays open and later Heards and answers shift by one. The
conversation itself is right; only the page's labels are wrong. Design: carry the inbound message id
through the request so its deliveries name it (`reply_to`), and pair by it. Test: a refused utterance
between two admitted ones leaves both admitted bubbles with their own Heard and answer.

## F16. A stronger echo guard

Found in review: the guard compares the transcript only with the last spoken answer and needs 8 words.
Design: the gateway records what it actually spoke (the last few projections, by message id) and the
worker compares with all of them, with a lower word floor for near-exact matches; an echo turn's own
reply is not spoken, so full-duplex cannot loop. Waits on: evidence of a missed echo in real use.

## F17. The HTTP edge off loopback

Found in review: a peer that can reach a non-loopback port can hold all 16 connections with slow
requests, and an aborted long-poll keeps its slot until its 25 s wait ends. Design: a 1 s deadline until
the request line, a per-peer cap, one slot reserved for authenticated requests, and a poll generation
so a new poll ends the old one. Belongs with F11 (the edge in its own process).

