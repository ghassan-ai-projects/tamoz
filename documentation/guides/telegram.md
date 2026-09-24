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

## 0. Quick start (the short path)

You need a bot token from [@BotFather](https://t.me/botfather) and one model
provider key (`OPENROUTER_API_KEY` or `DEEPSEEK_API_KEY`). Put them in the
environment or in a `KEY=value` file such as `.env`:

```bash
TAMOZ_TELEGRAM_BOT_TOKEN=<token from BotFather>
OPENROUTER_API_KEY=<your key>
```

Then two commands. `setup` is the one-time pairing; `start` runs the gateway and
the worker together in the foreground until Ctrl-C:

```bash
rbenv exec bundle exec tamoz telegram setup --workspace ~/my-project --env-file .env
rbenv exec bundle exec tamoz telegram start --env-file .env
```

`setup` authenticates the token (`getMe`), waits up to 120s for your first
private message to the bot, prints the sender's name and id, and asks you to
confirm it is you (`--owner TELEGRAM_USER_ID` skips the question). On `y` it
writes the channel and a workspace profile into the runtime directory (default
`~/.tamoz`, or `--runtime-dir PATH` on both commands). Running it again on an
existing runtime repairs it: an unpinned channel is adopted and a missing
profile is written.

`start` verifies the token, then tries each configured provider with one real
call and uses the first that answers (DeepSeek, then OpenRouter; force one with
`--provider NAME --model NAME`). A missing token, a refused token, a missing or
refused key, or an empty provider account is named in one `tamoz:` line before
anything runs. The worker runs with `--work-routing`, the tool-calling loop chat
is built on.

Now message the bot. Section 7 describes what to expect; the rest of this guide
is the manual path — what those two commands write, and how to configure each
piece by hand.

### When it does not answer

| Symptom | Cause and fix |
|---|---|
| `start` says the key was refused or the account is out of credit | Top up or switch provider; `start` names the variable it tried. |
| The bot replies "I can't reach my AI model: …" | The worker lost its provider mid-run (key revoked, credit ran out, rate limit). The reply names which. |
| A stranger gets no reply at all | By design: only paired correspondents reach the model. Add their `telegram:user:<id>` to `correspondents` (§3–4). |
| Nothing happens after you tap **Approve** | Make sure `start` (or a worker) is still running; the decision is durable and the turn resumes on the worker's next pass. |
| `comms doctor` reports a poller conflict | Another gateway or a webhook is reading the same bot. Stop it; one bot token, one gateway. |
| `start` says Tamoz is already running for this bot | An earlier `start` is still running (maybe in another terminal). Stop it with Ctrl-C there, then start again. After a crash, `start` waits the few seconds until Telegram lets go. |
| The bot says "My settings changed since we last talked…" | Expected once after re-running `setup` or editing the profile: the conversation continues on a fresh thread bound to the new settings. |
| The worker log says an MCP server could not be started | A configured MCP server (`sources.mcp`) is unreachable. Chat keeps working without that server's tools; fix or remove the server and restart. |

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
messages durably and nothing is ever answered. Chat turns need the tool-calling
work loop, so pass `--work-routing` — without it the worker serves chat on the
older plan/review path:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz --work-routing worker --json
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

## 7. What the chat does

Each message gets one plain reply, with Telegram's typing indicator while Tamoz
works. A greeting or a question is answered directly; a question about the
workspace reads the files; a change is proposed and, when policy asks, waits for
your tap. The conversation is remembered across messages and across restarts
until you send `/new`. Replies come in the language you write in.

| Command | What it does |
|---|---|
| `/help` | The short list; `/help more` lists every command. |
| `/new` | Starts a fresh conversation; earlier messages are no longer used. |
| `/status` | One sentence: working on your message, queued, waiting for your Approve/Deny, stopping, or nothing running. `/status --diagnostic` prints every state axis for an operator. |
| `/cancel` | Stops the work in progress: no further model call or tool runs, a model call already under way is abandoned, and you get "Stopped." instead of the answer. It stops every open message in the conversation; `/cancel r<ref>` stops one. |

- **Formatting.** Markdown the model writes — `code`, **bold**, code blocks,
  links — shows as formatting. The transport sends it as escaped Telegram HTML
  that always parses, so a reply is never refused for bad markup.
- **Approvals.** A change that needs approval shows what it will do: the file
  and its content (and the mode, if not `0644`), the diff for an edit, or the
  command for a check, followed by **Approve** and **Deny**. Content is shown in
  a code block its own text cannot break out of. After your tap the buttons
  disappear and Telegram shows a short toast ("Approved"/"Denied"); a tap on an
  old prompt says it is no longer waiting. Deny writes nothing and closes the
  request.
- **Honest endings.** A change no configured check verified ends with "No
  automatic check covered this change, so give it a quick look." A turn that
  failed, gave up, or lost its provider says so in one sentence. Long answers
  arrive whole, split across messages at Telegram's 4096-character limit.
- **Other messages.** Photos, stickers and other non-text messages get "I can
  only read text messages for now."

### Checking the experience yourself

`script/telegram_chat_eval` plays every expectation in
[`docs/telegram-chat/GOAL.md`](../../docs/telegram-chat/GOAL.md) as a Telegram
user against the real gateway and worker on a real provider, with a local
stand-in for Telegram's servers that refuses what Telegram refuses. It writes a
report with a transcript and the steps each turn took:

```bash
rbenv exec bundle exec ruby script/telegram_chat_eval
```

It runs the real `setup` and `start` commands; only Telegram's servers are a
stand-in (`TAMOZ_TELEGRAM_API_ORIGIN`). `--runtime-from ~/.tamoz` runs every
scenario on a copy of your own runtime — its history, profiles and MCP
sources — which is how problems that only an existing install has are found.
`--only greet,memory` runs a subset; keys come from the environment or `.env`,
and `--provider`/`--model` pin one. It costs a few cents of model calls.

## Next reads

- [`../operations/operations.md`](../operations/operations.md) — revocation, `:unknown` deliveries, approvals.
- [`../adr/adr-049-telegram-approval.md`](../adr/adr-049-telegram-approval.md) — the evidence-gated approval decision.
- [`../reference/config.md`](../reference/config.md) — env vars and the runtime directory.
