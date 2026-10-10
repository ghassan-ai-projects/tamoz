# Channels as one abstraction — future plan

Work deliberately left out of [`PLAN.md`](PLAN.md) (AGENTS.md: defer complexity). Each item has a sketch, the
test that would prove it, and what it waits on. None is built.

## F1. Push (webhook) transports

- **Sketch:** a channel whose platform pushes (Telegram webhooks, Slack Events, WhatsApp Cloud) buffers into the
  same cursor-ordered inbox talk uses, so the gateway's crash model is unchanged. Only the connection's `start`
  differs (an HTTPS listener). No second gateway path.
- **Test:** the C1 conformance suite, plus a crash between receive and admit redelivering once.
- **Waits on:** a channel that cannot long-poll; public HTTPS (talk F4 or a tunnel).

## F2. Voice replies on Telegram

- **Sketch:** `rendering.speech` on a Telegram surface makes the drainer send `sendVoice` with the synthesized
  part-0 projection (`Core::SpokenText`); the CLI then hands the Telegram gateway the voice key, as it does for talk; `Telegram::Channel#validate!` stops refusing `speech`.
- **Test:** delivery of a spoken answer is one journaled effect; a synthesis failure delivers text.
- **Note:** the CLI's speech checks key on `rendering.speech`; they would also require a transcription model for a
  speaking Telegram surface. Split "hears" from "speaks" then, not before.
- **Waits on:** owner wanting it; ADR-061's "voice is presentation" applies unchanged.

## F3. A third channel (Slack, WhatsApp, e-mail, Signal)

- **Sketch:** a new adapter gem with `Transport`, `Channel` and `Setup`, one registry line, and the standard
  new-gem registration — the loopback test channel (PLAN §1) is the worked example. Known places the core will still have to grow, found in review and not pre-built:
  `InboundEnvelope` message refs are integers (`inbound_envelope.rb:154`; Slack `ts`, WhatsApp `wamid` are
  strings); the 4096-character part ceiling (`rendering.rb:42`, `delivery.rb:30`) and `restricted_html` (Telegram's
  HTML subset) are core bounds both current kinds fit; the typing cadence is Telegram's (`delivery_drainer.rb:14`);
  WhatsApp's 24-hour reply window would block proactive notices and approval cards.
- **Test:** the conformance suite; containment and dependency tests; an isolated install.
- **Waits on:** a named need.

## F4. `tamoz channel list | remove | disable`

- **Sketch:** iterate the registry and `RuntimeDirectory.channels`; remove rewrites config and drops the lease.
- **Waits on:** ADR-062's future-work list.

## F5. Third-party channel adapters

- **Sketch:** ADR-014's preconditions — a privilege boundary limited to the adapter's credential, an
  operator-pinned digest per adapter, author-run contract tests.
- **Waits on:** an ADR-014 revision; not before 1.0.

## F6. One pairing flow for every channel

- **Sketch:** Telegram pairs by "send any message, confirm at the terminal"; talk by a token link. A shared
  `pair` step in the setup contract could serve both plus future kinds.
- **Waits on:** a third channel that needs pairing; two instances are not yet a pattern worth a seam.

## F7. (Adopted in plan revision 5: the string `stream_id`.)

## F8. File credentials

- **Sketch:** `credential_ref: {kind: file, path:}` — relative, no `..`, opened with `O_NOFOLLOW`, a regular file
  owned by the user, mode 0600.
- **Waits on:** a credential that must not pass through the environment. Deferred in review: the worker runs as
  the same OS user and can read the runtime folder, so it adds a mechanism without adding isolation.

## F9. A terminal channel (`tamoz chat`)

- **Sketch:** a `tamoz-terminal` adapter gem whose `Channel` connects a terminal to the running runtime through the
  same gateway, inbox and outbox as Telegram and talk (a local socket in the runtime folder, token-guarded like
  talk); its `Setup` is `channel add terminal`. Unlike `tamoz ask`, it shares the runtime's conversation, tools and
  approvals. `tamoz ask`/`code` stay in-process (PLAN §8).
- **Test:** the C1 conformance suite; containment counts unchanged outside the new gem and the registry line;
  an isolated install.
- **Waits on:** the owner wanting to talk to the running agent from a terminal; it is also the cheapest real test
  of PLAN §1's "a new channel touches only its gem and one line".

## F10. Context controls on channels

- **Gap found in review:** in production the gateway gets no controls source (`comms_controls_source` returns
  `nil`, `cli_comms_shared.rb:173-175`), so on Telegram and talk `/compact`, `/reset`, `/think`, `/verbose`, `/usage`
  and `/context` answer "not available"; the CLI's verbs work. Only tests inject a source.
- **Sketch:** the gateway enqueues a durable control request; the worker, which owns the session, applies it through
  the same `Session` methods the CLI calls and answers through the outbox.
- **Test:** each control on a channel changes the same session state as the CLI verb; a parity test compares the two.
- **Waits on:** the owner wanting these controls on a phone.

## F11. More than one talk page per runtime

- **Today:** every talk surface's update stream is `talk:page` (`Talk::Setup::STREAM`), so a second talk entry
  written by hand would find the stream's lease held and stop as `:poller_busy`.
- **Sketch:** name the stream after the surface (`talk:<surface_id>`), which needs `ChannelSetup#add` to know the
  surface id.
- **Waits on:** a need for two pages on one runtime.
