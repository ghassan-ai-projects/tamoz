# Talking to Tamoz over Telegram

A Telegram channel is a **user surface**, not a capability the model can call.
The bot answers people the operator put on an allowlist and nobody else; the
gateway holds the bot token and never constructs a session or opens a workspace
file.

Current version: `0.1.0.alpha.1` (pre-release).

The approval semantics are the load-bearing part of the design: approval is
gated on evidence, and the base policy lets the paired chat approve. The full
model is recorded in
[ADR-049](../adr/adr-049-telegram-approval.md).

## 1. Create the bot

Create a bot with [@BotFather](https://t.me/botfather). The token it gives you
is the only secret in the whole setup.

## 2. Authenticate it

Export the token, then bootstrap. Bootstrap prints the bot's numeric id and
deliberately does not persist it — you copy it into config yourself, so the
surface is pinned to a bot you chose:

```bash
export TAMOZ_TELEGRAM_BOT_TOKEN='<token from BotFather>'
```

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms doctor --bootstrap --credential-ref TAMOZ_TELEGRAM_BOT_TOKEN
```

Copy the printed `authenticated bot id` into `expected_bot_id` below. `tamoz`
never persists or trusts the token automatically.

## 3. Collect the allowlist

You also need the numeric Telegram id of everyone allowed to talk to it. Send
the bot a message, then read the pending update:

```bash
rbenv exec bundle exec ruby -rtamoz/telegram -e 'puts Tamoz::Telegram::Client.new(ENV.fetch("TAMOZ_TELEGRAM_BOT_TOKEN")).call("getUpdates", {"offset" => -1}, idempotent: true).inspect'
```

## 4. Configure the surface

Add the surface to `~/.tamoz/config.yaml` (schema 2). The token is referenced by
NAME, never by value, and `correspondents` is the allowlist — an unlisted sender
is durably rejected with no turn and no answer:

```yaml
channels:
  telegram-ops:
    kind: telegram
    revision: 1
    enabled: true
    profile: ops
    credential_ref: {kind: env, name: TAMOZ_TELEGRAM_BOT_TOKEN}
    expected_bot_id: 7463512990
    threading: conversation
    admission:
      direct: allowlist
      correspondents: ["telegram:user:11111111"]
    approvals:
      mode: deny_only
      prompt_ttl_s: 900
```

`profile` names a trusted profile in `~/.tamoz/profiles/`, and it — not the
chat — decides what a message is allowed to cause. Check the wiring before you
open the channel; every failure is named and exits 1:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms doctor
```

The doctor checks, in order: runtime permissions, token presence, adapter
presence, TLS, token validity (getMe), the exact bot id against
`expected_bot_id` (a token swap is a different surface), the webhook/poller
conflict, and the poller lease.

## 5. Run the two processes

Two ordinary foreground processes, in two terminals. Neither is a daemon and
neither writes a PID file, so launchd, systemd, Docker or runit supervise them
the way they supervise anything else.

The **gateway** long-polls Telegram, admits messages and sends answers. It runs
silently until it exits:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms serve
```

The **worker** executes the turns those messages became, and streams its
lifecycle events as newline-delimited JSON. Without it the gateway still admits
messages durably and nothing is ever answered:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz worker --json
```

Both exit cleanly on `SIGINT`/`SIGTERM` after finishing the work in hand. The
gateway can take up to one long-poll timeout (30s by default) to go, because a
pass already blocked in `getUpdates` finishes first — set your supervisor's stop
timeout above that.

A second gateway for the same bot refuses to poll rather than double-reading
the update stream, and if a competitor holds the stream from elsewhere,
Telegram's `409` is reported as a named poller conflict. A long poll that times
out or loses its connection is the normal weather of long polling: it observed
nothing, so the durable offset does not move and the next pass retries it.
Restarting either process is safe at any point — a message already admitted is
not re-admitted, and a terminal answer is durable before the occurrence closes,
so it survives a gateway that dies before sending it.

### Watching a silent bot

Since the running gateway prints nothing, ask a separate shell what a surface
is doing — poll offset, bindings, conversation-to-thread map and outbox state:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms list
```

`tamoz status --json` also reports a `channels` section (surfaces, last-poll
age, outbox depth and the comms safety counters).

Add `--once` to either command to do a single pass and exit, which is what you
want from cron or a test; `comms serve --once --json` reports each surface's
outcome for deterministic supervision.

## 6. Approval flow

Under ADR-049, approval authority is a function of evidence strength, not of
which transport pressed a button:

```text
chat_bound  <  filesystem_operator
```

- A bound Telegram correspondent supplies `chat_bound` and may **deny** any
  active prompt — denial is unconditional and fail-safe.
- The base policy requires `chat_bound` to approve, so the paired chat gets
  **Approve** and **Deny** buttons. Raise `evidence.approve` to
  `filesystem_operator` in the policy to make the chat deny-only; `tamoz approve`
  at the computer always works.
- Absent or ambiguous evidence never approves; an unknown delivery is resolved
  by the operator, never guessed.

See [`../operations/operations.md`](../operations/operations.md) for the
operator-side approval, delivery-resolution and revocation commands, and
[ADR-049](../adr/adr-049-telegram-approval.md) for the threat model.

## Next reads

- [`../operations/operations.md`](../operations/operations.md) — revocation, `:unknown` deliveries, approvals.
- [`../adr/adr-049-telegram-approval.md`](../adr/adr-049-telegram-approval.md) — the evidence-gated approval decision.
- [`../reference/config.md`](../reference/config.md) — env vars and the runtime directory.
