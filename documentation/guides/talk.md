# Talking to Tamoz by voice

The talk channel is a page in your browser: you speak, Tamoz shows what it heard, answers in text, and
speaks a short form of the answer. It is a channel like Telegram — same conversation memory, same `/new`,
`/status` and `/cancel`, same approval rule — reached from a phone or a desktop. Design and evidence:
[ADR-061](../adr/adr-061-the-talk-channel-is-a-browser-surface-whose-voice-is-presentation.md) and
[`docs/talk-voice-2026-10-09/`](../../docs/talk-voice-2026-10-09/PLAN.md).

## 0. Quick start

You need a chat model key and a speech key. Speech goes through OpenRouter's audio endpoints; give it its
own key so it can never spend the chat model's credit. `.env` holds only keys:

```bash
ZAI_API_KEY=<chat model key>
OPENROUTER_SPEECH_API_KEY=<OpenRouter key for speech>
```

The runtime's config names the models:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz setup --workspace ~/my-project --chat zai/glm-5.3-flash \
  --transcription openrouter/openai/gpt-4o-mini-transcribe --transcription-credential OPENROUTER_SPEECH_API_KEY \
  --voice openrouter/hexgrad/kokoro-82m --voice-name af_heart --voice-credential OPENROUTER_SPEECH_API_KEY
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz channel add talk
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz start --env-file .env
```

`start` checks the chat model, the speech-to-text model and the voice with one real call each (a voice that
does not answer is named and replies are text only until it does), then prints
a link such as `http://127.0.0.1:8787/#token=…`. Open it, tap **Start**, allow the microphone, and talk.
**Whoever holds the link can talk to Tamoz and approve its changes**; replace it with
`tamoz --runtime-dir ~/.tamoz channel add talk --rotate-token`.

`--<role>-credential` names the variable that holds a role's key (never the key itself). Without it a role
uses its provider's usual variable (`OPENROUTER_API_KEY`). `start` refuses a voice key that is the chat
model's key.

## 1. On a phone (iPhone or Android)

Browsers allow the microphone only over HTTPS (or on the computer itself). Tailscale gives the Mac an HTTPS
name that only your own devices can reach; nothing is opened to the internet. The free personal plan is
enough. The Mac must be awake and Tamoz running while you talk.

**Once, on every device**

1. Install Tailscale on the Mac (tailscale.com/download or the App Store) and on the phone (App Store or
   Google Play). Sign in to the same account on all of them.
2. In the admin console (login.tailscale.com → DNS) turn on **MagicDNS** and **HTTPS Certificates**.
3. Give the Mac a `tailscale` command: Tailscale menu → Settings → **Install CLI**. Without it, use
   `/Applications/Tailscale.app/Contents/MacOS/Tailscale` wherever this guide says `tailscale`.

**Once, on the Mac**

```bash
tailscale serve --bg http://127.0.0.1:8787
```

```bash
tailscale serve status
```

The first `serve` may print a link to enable Serve for your tailnet; open it, then run the command again.
`status` prints the Mac's name, such as `https://my-mac.tail1234.ts.net`. Tell Tamoz to accept that name
(the page refuses any other, a guard against DNS rebinding):

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz channel add talk --allow-host my-mac.tail1234.ts.net
```

Restart Tamoz so it reads the name: Ctrl-C a running `start` and run it again, or, for the service,
`tamoz --runtime-dir ~/.tamoz service uninstall` then `service install --env-file "$PWD/.env"`. `start` now
also prints `https://my-mac.tail1234.ts.net/#token=…`. The port is the talk page's (`8787` unless you chose
`channel add talk --port N`); `channel add talk --host 0.0.0.0` is never needed and is refused unless an allowed name is set.

**Getting the link onto the phone**

The link is a key: whoever has it can talk to Tamoz and approve its changes. Do not send it through a chat
or email. Under the service, build it from the token file and copy it:

```bash
printf 'https://my-mac.tail1234.ts.net/#token=%s' "$(cat ~/.tamoz/channels/talk/token)" | pbcopy
```

- **iPhone:** with the same Apple ID the copy reaches the phone (Universal Clipboard), or AirDrop it. Paste
  it in Safari, then Share → **Add to Home Screen**.
- **Android:** show it as a QR code (`brew install qrencode`, then `pbpaste | qrencode -t ansiutf8`) and scan
  it with the camera. Open it in Chrome, then ⋮ → **Add to Home screen**.

Tap **Start talking** and allow the microphone. The phone needs Tailscale switched on (its VPN icon shows).

**Turning it off:** `tailscale serve reset` stops the HTTPS name; `channel add talk --rotate-token` makes
every old link stop working once Tamoz restarts (for the service: `service uninstall`, then `service install`,
which carries the new token).

| On the phone you see | Do |
|---|---|
| The page does not load | Tailscale is off on the phone or the Mac, or the Mac is asleep |
| A blank page or `421 Misdirected Request` | The name in the address is not the one given to `--allow-host`; check `tailscale serve status` |
| "The mic needs HTTPS…" | You opened `http://`; use the `https://…ts.net` link |
| "Mic blocked…" | Allow the microphone for the site in Safari or Chrome settings, then reload |
| "Mic paused while the screen is off" | The phone stopped the microphone; unlock it and the page resumes |

## 2. Talking

- **Hands-free** (default): speak; the page waits about 1.2 s of quiet before it sends (Settings → Pause
  before sending: 0.8–2 s). While it is about to send it shows **Send now** and **Discard**. Coughs, clicks
  and steady fan noise are ignored.
- **Push to talk** (Settings → Microphone): hold the mic button, or Space. **Off** keeps the mic closed.
- Your bubble shows **Heard: “…”**, what Tamoz understood. Check names and numbers there.
- While Tamoz speaks, the microphone is off (so it cannot hear itself). Tap the mic or press Escape to cut
  it off. With headphones, Settings → "Headphones (talk over replies)" lets you talk over it.
- **Stop** appears while Tamoz works or speaks and ends the current request (`/cancel`). Settings → **Ask
  Tamoz for status** asks what is running (`/status`). Anything you say while Tamoz works waits its turn;
  the bubble says "Queued".
- Typing works everywhere; **Type instead** on the start screen skips the microphone and speech.

## 3. Changes need a tap

When Tamoz wants to change something it shows a card with the exact change and says "I need your
approval…". Only the **Approve** button approves. Saying or typing "yes, approve it" is just a message;
it never decides anything. **Deny** always works.

## 4. What is kept

Nothing you say is stored as audio: a recording is held in memory until the gateway has taken it, then in
a temporary file until the turn has read it. Spoken replies live in a small memory cache. The
conversation is kept as text, like any channel. If the gateway restarts, the page shows the last 50
messages and any card still waiting for your tap.

## 5. Troubleshooting

| You see | Why | Do |
|---|---|---|
| "This link is not valid any more" | The token was rotated | Open the new link from `start` |
| "The mic needs HTTPS…" | Plain HTTP on another device | Use `tailscale serve` (section 1) |
| "Voice unavailable" on a reply | The voice model failed or is not set | Check the voice model `setup --voice` names and its key; the text is complete |
| "Didn't catch that" | The sound was too short or too quiet | Speak again, or use push to talk |
| "Mic paused while the screen is off" | The phone stops capture when the screen locks | Unlock; the page resumes |
| `start` says the talk page cannot listen on the port | Another program (or another Tamoz) uses it | Stop it, or `tamoz channel add talk --port N` |
| `start` says Tamoz is already running for this channel | An earlier `start` is still running | Ctrl-C it there, then start again |
| `start` says the voice key must not be the chat model's key | Speech would spend the chat credit, and the gateway would hold the chat key | Give speech its own key (`OPENROUTER_SPEECH_API_KEY`) |

`tamoz comms doctor` checks the talk token, whether the port is free and whether another gateway holds
the channel.

## 6. Measuring it

The eval plays synthetic speech (macOS `say`, four English voices) through the real channel and real models, and
grades what Tamoz heard, answered and said, plus the safety properties (a spoken "approve" never decides, Tamoz
never obeys its own voice, Stop stops, nothing is kept). Protocol and thresholds:
[`EVAL.md`](../../docs/talk-voice-2026-10-09/EVAL.md).

```bash
bundle exec ruby script/generate_talk_fixtures
```

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec ruby script/talk_eval --canary
```

A missing tool, key or credit is **BLOCKED** and fewer valid runs than stated is **SHORT**; neither is a pass.
