# Talk channel — where we stopped (2026-10-09)

Start here next session. The talk channel (voice and text from a browser page) is built and in review as
[ghassan-ai-projects/tamoz#73](https://github.com/ghassan-ai-projects/tamoz/pull/73) on branch
`add-audio-support`. The owner's order: **finish PR #73 first**, then plan and build **one abstracted setup**
for every channel (§3).

## 1. PR #73 — state

- Commits: plan → speech transport and role keys → second surface kind → Heard + echo guard → talk gem, page
  and CLI → eval → four review rounds of fixes → CI fixes.
- Four independent reviews (security, correctness, eval rigor, architecture): no critical finding; every high
  and medium finding fixed or recorded (`QUALITY_BAR.md` review log; `FUTURE_PLAN.md` F14–F17).
- **CI:** the last failures were, in order: a stale ADR evidence citation → the syntax gate reading
  `script/talk_canary.mjs` as Ruby (moved to `script/talk/canary.mjs`) → CI's older node not taking a folder
  for `node --test` and printing TAP (`# fail 0`) → **the everyday-gate time budget** (185 s > 180 s at 3
  workers; `main` runs at 156 s). See §1.1 for the fix.
- Open in the bar: the gated real-model eval (C1–C7, C10–C13), driver-level adversaries (C8), D1–D3, D6, D7,
  E and F rows. ADR-061 is `Implementation: Partial` until the gated eval runs.
- Owner decisions raised, not yet answered:
  1. Spoken phrases (`SpokenText` "The code is on screen." …) and the `Heard: «…»` label are English literals
     in Ruby: move them to data under ADR-058, or keep them as interface strings?
  2. Migration 25 rebuilds the decisions table and copies its rows; ADR-059 allows a reset before 1.0. Keep
     the copy or simplify?

### 1.1 The CI budget fix (this session)

- `talk_http_test` paid real time (a 1.5 s sleep and 0.3 s drips): the write deadline is now injectable like
  the head and body deadlines (`deadlines: { write: }`), 3.0 s → 1.3 s, and its test still fails when the
  deadline is long.
- The endpointing eval (now `talk_endpointing_eval_test`, about 2 s of CPU) moved to the slow lane; `rake ci_full`
  still runs it. Owner rule: mark only the slowest files as slow, and only when they cannot be made faster.
- Locally `rake test_fast` is 37 s on both `main` and the branch. If CI still exceeds 180 s, the next lever is
  `rake test_profile` on the runner shape (3 workers) and refreshing `TEST_WEIGHTS`. The owner also moved the three slowest
  everyday files to the slow lane (`work_loop_test` 13.2 s, `subagent_spec_test` 10.3 s, `research_spec_test`
  7.4 s); making them faster and bringing them back is a candidate task.

## 2. Findings from the owner's live sessions (Chrome, real models)

What worked: English heard almost word for word; Tamoz answered, followed language switches (English ↔
Arabic), remembered within the talk conversation, refused honestly what it cannot do (Telegram history, web,
MCP), Stop stopped running and queued requests.

Fix list, in priority order:

1. **The talk channel is not the Telegram runtime.** It ran on a test runtime (`tmp/talk-live/`, pond
   workspace), so it had none of Telegram's abilities (web search, skills, memory, the ALMS MCP server). This
   is §3.
2. **Empty recordings cost a model turn.** Four utterances carried no speech; three transcription calls in
   under 0.5 s returned nothing (the journal's `model.transcribe` attempts at 1791581054xxx have a `nil`
   result), and each still produced a full answer ("I couldn't hear anything"). Fix: an empty transcript
   answers "Didn't catch that" without a model call; find what the endpointer lets through (clicks? quiet
   speech? the Stop click?).
3. **A voice outage blocks start.** OpenRouter's `hexgrad/kokoro-82m` did not answer at all (30 s timeouts,
   credit fine at $4.95) and `talk start` refused to start. Start text-only and say so; speech is presentation.
4. **Stop with queued requests** prints "Stopped." once per request (four lines); one line would do.
5. The lease wait message says "Telegram" on a talk channel (`already_running` in
   `cli_telegram_commands.rb`).
6. "MCP" was heard as "MCB" — expected for acronyms; the model coped.
7. Replies call live speech a "voice message" (F14).
8. Arabic: transcribed and answered, but the voice is English-only and the reply mixed dialects.

## 3. Next change: one abstracted setup for every channel

Owner (2026-10-09): Telegram, the CLI and the web page must be **one agent**: the same provider, abilities
and memory everywhere; a channel is only a way in.

Today each channel has its own setup: `telegram setup` and `talk setup` each write a profile, each `start`
picks a provider and spawns its own worker, and the launchd jobs carry keys edited by hand.

Proposed shape (plan it with a quality bar and reviews before building, per AGENTS.md):

| Piece | Holds |
|---|---|
| `tamoz setup` (one runtime) | workspace, chat provider and model, model roles (transcription, voice, vision), sources (memory, skills, MCP, websearch), approval profile, one abilities profile |
| `tamoz channel add telegram\|talk` | only the way in: token or link, admission, port; uses the runtime's profile and provider |
| `tamoz start` | one worker and one gateway for every enabled channel |
| `tamoz service install` | the launchd jobs, written from the same config and `.env` |
| CLI (`tamoz ask/code`) | the same runtime config, so terminal, Telegram and web page share one agent |

Facts to start from (read-only inspection, no secrets):

- The live Telegram service runs on `~/.tamoz`: `com.tamoz.gateway` runs `comms serve --surface
  telegram-ops`; `com.tamoz.worker` runs the worker with `--provider zai --model glm-5.3-flash`, Brave web
  search, `--concurrency 1`. The worker job has **no** `TAMOZ_TRANSCRIPTION_*`, so Telegram voice notes are
  not set up either.
- `~/.tamoz/config.yaml`: workspace root is this repo; sources memory, skills, MCP (ALMS at
  `192.168.2.112:8001`) and websearch; channel `telegram-ops` uses profile `telegram`.
- A first step was drafted and set aside to keep PR #73 focused: `talk setup` reusing the runtime's existing
  chat profile instead of writing its own (`shared_chat_profile` in `cli_talk_commands.rb`, plus a test).
  The patch is at `tmp/next-session/talk-shares-profile.patch`.
- `talk start` spawns its own worker, so it must not run on a runtime that a launchd worker already serves;
  until §3 exists, joining talk to `~/.tamoz` means a separate `comms serve --surface talk` job plus
  transcription settings on the existing worker job.

## 4. How to run things

```bash
bundle exec ruby script/generate_talk_fixtures
```

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 bundle exec ruby script/talk_eval --canary
```

The live test runtime is `tmp/talk-live/` (token in `tmp/talk-live/runtime/talk/token`, a no-voice env copy in
`tmp/talk-live/env-novoice`). Start it with `tamoz --runtime-dir $PWD/tmp/talk-live/runtime talk start
--env-file .env --provider zai --model glm-5.3-flash` and `ZAI_API_BASE=https://api.z.ai/api/coding/paas/v4`.
