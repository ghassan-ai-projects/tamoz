# Talking to Tamoz by voice

The talk channel is a page in your browser: you speak, Tamoz shows what it heard, answers in text, and
speaks a short form of the answer. It is a channel like Telegram — same conversation memory, same `/new`,
`/status` and `/cancel`, same approval rule — reached from a phone or a desktop. Design and evidence:
[ADR-061](../adr/adr-061-the-talk-channel-is-a-browser-surface-whose-voice-is-presentation.md) and
[`docs/talk-voice-2026-10-09/`](../../docs/talk-voice-2026-10-09/PLAN.md).

## 0. Quick start

You need a chat model key and a speech key. Speech goes through OpenRouter's audio endpoints; give it its
own key so it can never spend the chat model's credit. In `.env`:

```bash
ZAI_API_KEY=<chat model key>                       # or any provider `tamoz telegram start` accepts
OPENROUTER_SPEECH_API_KEY=<OpenRouter key for speech>

TAMOZ_TRANSCRIPTION_PROVIDER=openrouter            # speech to text
TAMOZ_TRANSCRIPTION_MODEL=openai/gpt-4o-mini-transcribe
TAMOZ_TRANSCRIPTION_CREDENTIAL=OPENROUTER_SPEECH_API_KEY

TAMOZ_VOICE_PROVIDER=openrouter                    # text to speech
TAMOZ_VOICE_MODEL=hexgrad/kokoro-82m
TAMOZ_VOICE_NAME=af_heart
TAMOZ_VOICE_CREDENTIAL=OPENROUTER_SPEECH_API_KEY
```

Then:

```bash
rbenv exec bundle exec tamoz talk setup --workspace ~/my-project
rbenv exec bundle exec tamoz talk start --env-file .env
```

`start` checks the chat model, the speech-to-text model and the voice with one real call each, then prints
a link such as `http://127.0.0.1:8787/#token=…`. Open it, tap **Start**, allow the microphone, and talk.
**Whoever holds the link can talk to Tamoz and approve its changes**; replace it with
`tamoz talk setup --rotate-token`.

`TAMOZ_*_CREDENTIAL` names the variable that holds a role's key (never the key itself). Without it a role
uses its provider's usual variable (`OPENROUTER_API_KEY`). `start` refuses a voice key that is the chat
model's key.

## 1. On a phone

Browsers allow the microphone only over HTTPS (or on the computer itself). With Tailscale:

```bash
tailscale serve --bg https / http://127.0.0.1:8787
rbenv exec bundle exec tamoz talk setup --allow-host <machine>.<tailnet>.ts.net
```

`start` then also prints `https://<machine>.<tailnet>.ts.net/#token=…`. The page refuses any other host
name (a guard against DNS rebinding), and `--host 0.0.0.0` is refused unless an allowed name is set.

## 2. Talking

- **Hands-free** (default): speak; the page waits about 1.2 s of quiet before it sends (Settings: 0.8–2 s).
  While it is about to send it shows **Send now** and **Discard**. Coughs, clicks and steady fan noise are
  ignored.
- **Push to talk**: hold **Talk** or Space.
- Your bubble shows `sent`, then **Heard: «…»** — what Tamoz understood. Check names and numbers there.
- While Tamoz speaks, the microphone is off (so it cannot hear itself). Tap **Talk**, press Space or
  Escape to cut it off. With headphones, Settings → "I'm using headphones" lets you talk over it.
- **Stop** ends the current request (`/cancel`); **Status** asks what is running (`/status`). Anything you
  say while Tamoz works waits its turn — the bubble says "queued".
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
| "This link is not valid any more" | The token was rotated | Open the new link from `talk start` |
| "The microphone needs HTTPS" | Plain HTTP on another device | Use `tailscale serve` (section 1) |
| "voice unavailable" on a reply | The voice model failed or is not set | Check `TAMOZ_VOICE_*`; the text is complete |
| "Didn't catch that." | The sound was too short or too quiet | Speak again, or use push to talk |
| "paused: the microphone stops when the screen locks" | iOS stops capture when the screen locks | Unlock; the page resumes |
| `start` says the talk page cannot listen on the port | Another program (or another Tamoz) uses it | Stop it, or `tamoz talk setup --port N` |
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
