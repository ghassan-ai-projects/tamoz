# One setup for every channel — plan (revision 1)

**Owner:** Ghassan · **Set:** 2026-10-09 · **Branch:** `one-setup-every-channel` (from `main` at `3faf1c8b`)
**Bar:** [`QUALITY_BAR.md`](QUALITY_BAR.md) · **Starting notes:** [`../talk-voice-2026-10-09/NEXT_SESSION.md`](../talk-voice-2026-10-09/NEXT_SESSION.md) §3

## 1. Outcome

One runtime is one agent. The terminal, Telegram and the talk page use the same chat model, model roles,
sources, workspace and abilities, set once in the runtime; a channel is only a way in. One command checks and
runs it, one command installs it as a service, and the owner's live `~/.tamoz` moves to this shape with its
history, memory and Telegram pairing intact.

## 2. Owner decisions (2026-10-09)

| # | Decision |
|---|---|
| OD1 | The CLI (`tamoz ask`, `code`, …) reads the runtime's config (models, roles, sources, workspace, abilities) but keeps its own per-session history. It is not a channel. |
| OD2 | Provider, model and the model roles live in the runtime's `config.yaml`; `.env` holds only keys. |
| OD3 | `tamoz service install` writes the launchd jobs from the config and `.env`, replacing the hand-edited plists. |
| OD4 | The live `~/.tamoz` is migrated in place (backup first), keeping history, memory and the Telegram pairing. |

## 3. Today (the seams this extends)

| Concern | Where it lives today |
|---|---|
| Runtime folder | `RuntimeDirectory` (`gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb`): `config.yaml` schema 2 — `workspace.root`, `sources` (memory, skills, mcp, websearch), `channels`, `approval`, `harness`; `create!`, `migrate!` (1 → 2 with backup), `channels`, `enabled_sources`. `tamoz init` creates it; `tamoz config migrate` migrates it. |
| Chat model | Flags or env on every command: the worker's `--provider/--model`, `TAMOZ_PROVIDER/TAMOZ_MODEL` (`CLI::ModelBuilder#build`, `cli_model_builder.rb`), and `telegram start`'s probe order (`working_provider`). A profile's `model_roles.primary` exists but chat profiles do not set it. |
| Model roles | Env only: `TAMOZ_<ROLE>_PROVIDER/_MODEL/_API_BASE/_CREDENTIAL` for TRANSCRIPTION, VISION, VOICE (`attachment_model`, `cli_worker_commands.rb:686`; `ChildEnvironments.role_credential`). |
| Abilities | A profile file per channel setup: `telegram setup` and `talk setup` each call `write_chat_profile` (`cli_telegram_commands.rb:191`) with their own id; channels name it in `channels.<id>.profile`. |
| Running | `telegram start` and `talk start` each probe a provider, spawn **their own** gateway and worker (`run_talk`, `supervise`), and pass env built by `ChildEnvironments`. `comms serve` already serves every enabled surface when no `--surface` is given. |
| Service | Hand-written `~/Library/LaunchAgents/com.tamoz.{gateway,worker}.plist` with keys in `EnvironmentVariables`. |
| CLI sessions | `ask/code` build a session in a per-session SQLite under a session dir (`cli_session_builder.rb`), take the model from flags/env, the workspace from `--root`, and read the runtime only for a named profile. |

## 4. Design

### 4.1 The runtime config gains `models` (schema 3)

```yaml
models:
  chat:          { provider: zai, model: glm-5.3-flash }
  transcription: { provider: openrouter, model: openai/gpt-4o-mini-transcribe, credential: OPENROUTER_SPEECH_API_KEY }
  voice:         { provider: openrouter, model: hexgrad/kokoro-82m, voice: af_heart, credential: OPENROUTER_SPEECH_API_KEY }
  vision:        { provider: openrouter, model: … }        # optional
abilities: chat                                              # the one profile every channel uses
```

- `credential` names an `*_API_KEY` variable in `.env`, never a key (ADR-048); without it a role uses its
  provider's usual variable. `api_base` is allowed per role, as today.
- `RuntimeDirectory` validates and exposes `models` and `abilities`; `migrate!` 2 → 3 with a backup.
- **Removed, not kept beside it (ADR-059):** `TAMOZ_PROVIDER`, `TAMOZ_MODEL` and every
  `TAMOZ_<ROLE>_*` variable. A command run on a runtime reads the config; `--provider/--model` stay as a
  one-run override for the CLI only.
- Models stay out of the profile on purpose: the profile's digest is pinned per thread at bind time
  (`WorkerRuntime#child_profile_for`, `validate_thread_profile`), so a model change there would break every
  existing conversation's pin. The model is not authority; the abilities are.

### 4.2 One abilities profile

`tamoz setup` writes one chat profile (`write_chat_profile`, unchanged in content) under the id in
`abilities`, and every channel entry names it. A runtime that already has one (the live `telegram`) keeps it
and `abilities` points at it, so its digest and every bound thread stay valid.

### 4.3 Commands

| Command | Does | Replaces |
|---|---|---|
| `tamoz setup [--workspace P] [--chat PROVIDER/MODEL] [--transcription …] [--voice …] [--vision …]` | Creates or updates the runtime: workspace, `models`, `abilities` profile. Re-running changes only what is passed. | `tamoz init` (removed) |
| `tamoz channel add telegram` | Pairs the bot (today's pairing flow) and writes the channel with the runtime's abilities. | `tamoz telegram setup` (removed) |
| `tamoz channel add talk [--port] [--allow-host]` | Writes the talk channel and its token. | `tamoz talk setup` (removed) |
| `tamoz channel list` / `remove ID` | Lists or disables a channel. | — |
| `tamoz start [--env-file .env]` | Checks the chat model and each configured role with one real call (a voice failure warns and runs text-only), then runs **one** gateway for every enabled channel and **one** worker; prints the talk link when talk is on. | `tamoz telegram start`, `tamoz talk start` (removed) |
| `tamoz service install [--env-file .env]` / `status` / `uninstall` | Writes and loads `com.tamoz.gateway` and `com.tamoz.worker` launchd jobs whose arguments and environment come from the config and `.env` through `ChildEnvironments`; `status` shows both and the last log lines. | the hand-edited plists |

`comms serve` (gateway) and the bare worker command stay as the processes `start` and the service run.

### 4.4 Children get the runtime, not models

The gateway and worker receive `--runtime-dir` and read `models` from the config. `ChildEnvironments` keeps
choosing the keys each child may hold, now from the config's credential names: the worker gets the chat key
and the transcription and vision keys; the gateway gets its channel tokens and, when talk is on, the voice
key (ADR-042 as amended); the chat key is still refused as the voice key, by name and by value.

### 4.5 The CLI reads the same runtime

`ask/code` (and the other session commands) resolve the runtime as today (`--runtime-dir`, then
`TAMOZ_RUNTIME_DIR`, then `~/.tamoz` when it exists). With a runtime they take the chat model from `models`,
the workspace from `workspace.root` (unless `--root` is given), the sources from `sources`, and the abilities
profile when no `--profile` is given; their history stays in their session dir (OD1).

### 4.6 Migration of the live runtime (OD4)

`tamoz config migrate` (2 → 3) backs up `config.yaml`, adds `models` from flags the operator passes
(`--chat zai/glm-5.3-flash`, roles), sets `abilities` to the profile the existing channels share (`telegram`)
and leaves channels, history, memory and the pairing untouched. Then `tamoz channel add talk`, then
`tamoz service install` replaces the two hand-written plists. Each step is reversible from the backup.

## 5. Phases

| Phase | Builds | Gate |
|---|---|---|
| P0 | This plan and its bar; two independent reviews; owner OK | bar rows 0–1 |
| P1 | Schema 3: `models`, `abilities`, validation, `migrate!` 2 → 3; `ModelBuilder`, `attachment_model` and `ChildEnvironments` read the config; env model variables removed | A1–A4, B1–B3 |
| P2 | `tamoz setup` (replaces `init`) | B4 |
| P3 | `tamoz channel add telegram`, `channel add talk`, `list`, `remove` (replace the two setups) | B5, B6 |
| P4 | `tamoz start` (replaces both starts): one gateway, one worker, probes, voice optional, talk link | A5, B7, B8 |
| P5 | `tamoz service install`, `status`, `uninstall` | A6, B9 |
| P6 | CLI session commands read the runtime | B10 |
| P7 | ADR-062, guides and reference updated; migrate the owner's `~/.tamoz`; live check: Telegram and the talk page on one runtime, real models | F rows, C1 |

Each phase: tests first where they pin a property, `rubocop -a`, the phase's rows graded, a fresh reviewer,
fixes, commit.

## 6. Tests (the properties that must hold)

- Config: a document without `models.chat` is refused by `start`, not by `setup`; a credential that holds a
  key, not a name, is refused; a role without `credential` uses its provider's variable; schema 2 migrates
  with a backup and keeps every other key byte-for-byte; schema 1 still migrates through 2.
- Every command that builds a chat model on a runtime gets the config's (worker, CLI ask, `start` probe); no
  code path reads `TAMOZ_PROVIDER/MODEL/<ROLE>_*` (a source scan test).
- Channels: `channel add` never writes or changes a profile when `abilities` is set; both channels name the
  same profile; telegram pairing and talk token behave as today (their existing tests move, not shrink).
- `start`: one gateway serves telegram and talk together (a fake Telegram API and the talk HTTP API in one
  run); one worker answers both; a failing voice probe runs text-only and says so; a failing chat or
  transcription probe stops with its name; a second `start` is refused.
- `service install`: the written plists hold exactly the arguments and the environment `ChildEnvironments`
  gives each child (golden files with keys masked); the worker plist never holds a channel token, the gateway
  plist never the chat key; `uninstall` removes only what `install` wrote.
- CLI: `ask` on a runtime uses the config's model and workspace with no flags; `--provider/--model` still
  override for one run; history stays in the session dir.
- Migration: the owner's runtime shape (pinned as a fixture with its channels, sources and a bound thread)
  migrates and the thread's profile pin still validates.

## 7. Not in scope (future plan)

- The CLI as a channel sharing conversation history (OD1).
- A session-history tool so a channel can review past conversations in other channels.
- systemd or Windows services.
- The talk findings that are not about setup (empty recordings, Stop's repeated lines, voice language) —
  listed in `NEXT_SESSION.md` §2.

## 8. Risks

| Risk | Answer |
|---|---|
| The live Telegram service breaks during migration | Backup first; migrate on a copy (`--runtime-dir` to a copied folder) and run `start` there before touching `~/.tamoz`; the old plists are kept as `.bak` until the new service answers. |
| A thread bound to the old profile no longer validates | `abilities` points at the existing profile, unchanged; a fixture with a bound thread proves it. |
| Removing the env model variables breaks scripts and guides | No backward compatibility before 1.0 (ADR-059); every guide and reference page is updated in P7, and a source scan finds any reader left. |
| One worker for both channels is slower | It is the same worker the Telegram service runs today (`--concurrency 1`); concurrency stays a config value. |
