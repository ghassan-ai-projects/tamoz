# One setup for every channel — plan (revision 2)

**Owner:** Ghassan · **Set:** 2026-10-09 · **Revised:** 2026-10-10 after two independent reviews
**Branch:** `one-setup-every-channel`, built in the worktree `.claude/worktrees/one-setup` · **Bar:**
[`QUALITY_BAR.md`](QUALITY_BAR.md) · **Starting notes:**
[`../talk-voice-2026-10-09/NEXT_SESSION.md`](../talk-voice-2026-10-09/NEXT_SESSION.md) §3

## 1. Outcome

One runtime is one agent. Telegram and the talk page answer with the same chat model, model roles, sources,
workspace and abilities, set once in the runtime; the CLI uses the same models and sources. One command
checks and runs it, one installs it as a service, and the owner's live `~/.tamoz` moves to this shape with
its history, memory, web search and Telegram pairing intact.

## 2. Owner decisions

| # | Date | Decision |
|---|---|---|
| OD1 | 2026-10-09, narrowed 2026-10-10 | The CLI (`ask`, `code`, …), given `--runtime-dir` or `TAMOZ_RUNTIME_DIR`, takes the chat model, model roles and sources from the runtime. Its workspace stays the current folder (or `--root`); its tools, approvals and history stay its own. There is no `~/.tamoz` default for the CLI. |
| OD2 | 2026-10-09 | Provider, model and the model roles live in the runtime's `config.yaml`; `.env` holds only keys and provider endpoints. |
| OD3 | 2026-10-09 | `tamoz service install` writes the launchd jobs from the config and `.env`, replacing the hand-edited plists. |
| OD4 | 2026-10-09 | The live `~/.tamoz` is migrated in place, after a rehearsal on a consistent copy, keeping history, memory and the Telegram pairing; every step has a tested rollback. |
| OD5 | 2026-10-10 | One gateway per channel, one shared worker. The Telegram token never sits in the process that runs the talk page's web server (ADR-042 unchanged). |

## 3. Today (the seams this extends)

| Concern | Where it lives today |
|---|---|
| Runtime folder | `RuntimeDirectory` (`gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb`): `config.yaml` schema 2 (`workspace.root`, `sources`, `channels`, `approval`, `harness`); `create!`, `migrate!`, `channels` (`validate_channel!` requires a `profile` per channel); unknown top-level keys are ignored. `tamoz init` creates it. |
| Chat model | `CLI::ModelBuilder#build` (`cli_model_builder.rb:19-24`): flag, then `TAMOZ_PROVIDER/TAMOZ_MODEL`, then a profile's `model_roles.primary`. Callers: CLI sessions (ask, code, …), one-shot, `memory consolidate` (`cli_memory_commands.rb:94`), the worker (`--provider/--model`). `telegram start` probes a provider list (`working_provider`). |
| Model roles | Env only: `TAMOZ_<ROLE>_*` for TRANSCRIPTION, VISION, VOICE (`attachment_model`, `cli_worker_commands.rb:686`; `ChildEnvironments.role_credential`). |
| Abilities | `write_chat_profile` (`cli_telegram_commands.rb:191`), called by `telegram setup` and `talk setup` with their own ids; the profile's digest is pinned per thread (`validate_thread_profile`, `worker_runtime.rb:727`; `child_profile_for`, `:1189`). |
| Child environments | `ChildEnvironments` (`gems/tamoz-agent/lib/tamoz/agent/child_environments.rb`): per-kind `gateway_env`, `talk_gateway_env`, `worker_env`. **`worker_env` does not forward the websearch source's credential and env (`TAMOZ_BRAVE_API_KEY`, `TAMOZ_WEBSEARCH_*`) that `McpSourceBuilder` reads (`mcp_source_builder.rb:289`), nor a provider endpoint like `ZAI_API_BASE`.** |
| Running | `telegram start`, `talk start`: probe, then spawn their own gateway and worker (`supervise`). `already_running` reads only the Telegram poller lease. |
| Service | Hand-written `com.tamoz.{gateway,worker}.plist` that run **this checkout's** `exe/tamoz` with `-rbundler/setup`, `KeepAlive` and a 30 s throttle; the worker plist also holds the Telegram token (against ADR-042). |
| CLI | Uses a runtime, when given, for MCP (`cli_session_builder.rb:50`), memory (`cli_memory_commands.rb:28`) and persona (`cli_session_commands.rb:125`); profiles load through `Profile.resolve_path` and the adoption registry (`cli_authority.rb:45-67`). |
| Model and role env readers outside the CLI | `bin/tamoz-chat-sim`; `script/{agent_latency_smoke,telegram_chat_eval,telegram_attachment_eval,live_alms_telegram,thermal_real_run,self_investigation_eval,investigation_real_run,talk_eval}`; `agenteval/adapters/{tamoz,tamoz_code_support}.rb`; `agenteval/skills/pack.rb`; `test/support/{experience_harness,talk_chat_eval}.rb`; `apps/tamoz-agent/README.md`, `gems/tamoz-agent/README.md`. |

## 4. Design

### 4.1 `models` in the runtime config (no schema bump)

```yaml
models:
  chat:          { provider: zai, model: glm-5.3-flash }
  transcription: { provider: openrouter, model: openai/gpt-4o-mini-transcribe, credential: OPENROUTER_SPEECH_API_KEY }
  voice:         { provider: openrouter, model: hexgrad/kokoro-82m, voice: af_heart, credential: OPENROUTER_SPEECH_API_KEY }
  vision:        { provider: openrouter, model: … }        # optional
```

- `models` is an additive key, so the schema stays 2: `RuntimeDirectory` validates it when present and
  exposes it; `tamoz setup` writes it (backing up `config.yaml` first, `backup_config!`). Rolling back the code
  needs no config restore, because old code ignores the key.
- `credential` names an `*_API_KEY` variable, never a key; one validation function
  (`ChildEnvironments.role_credential`'s rule) serves the config and the child environments. Without it a role
  uses its provider's usual variable. A provider endpoint (`ZAI_API_BASE`, `<ROLE> api_base`) stays in `.env`.
- Models stay out of the profile: its digest is pinned per thread, so a model change there would break every
  bound conversation. No thread records the chat model (the worker passes no `profile_roles`), so moving it to
  the config changes no receipt.
- **Precedence:** for the CLI, `--provider/--model` (one run) > `models.chat` > the profile's `primary`. The
  worker and `start` take `models.chat` only. `TAMOZ_PROVIDER`, `TAMOZ_MODEL` and every `TAMOZ_<ROLE>_*` are
  removed in P4, together with the commands that set them (ADR-059: no shim).

### 4.2 One abilities profile, without a second source of truth

There is no new `abilities` key. `RuntimeDirectory` requires every chat channel's `profile` to be the same id
and that profile to exist. `tamoz setup` writes `profiles/chat.yaml` only when the runtime has no chat profile
yet; it never rewrites an existing one, because that would change its digest and invalidate every bound
thread. `setup --workspace` on a runtime that already has a profile is refused, naming why (changing the
workspace of a lived-in runtime is the future plan). `channel add` names the profile the runtime already uses
(the live one is `telegram`).

### 4.3 Commands

| Command | Does | Replaces |
|---|---|---|
| `tamoz setup [--runtime-dir D] [--workspace P] [--chat PROVIDER/MODEL] [--transcription …] [--voice …] [--vision …]` | Creates the runtime or updates its `models`; writes the chat profile only when none exists. A re-run changes only what is passed. A missing key is reported ("OPENROUTER_SPEECH_API_KEY is not in .env yet"), not refused. | `tamoz init` |
| `tamoz channel add telegram` | Today's pairing flow; the channel names the runtime's profile. | `tamoz telegram setup` |
| `tamoz channel add talk [--port] [--allow-host] [--rotate-token]` | Today's talk channel and token; names the runtime's profile. | `tamoz talk setup` |
| `tamoz start [--env-file F]` | Checks the chat model and each configured role with one real call (a failing voice warns and runs text-only; a failing chat or transcription stops with its name), then runs one `comms serve --surface X` per enabled channel and one worker, all supervised; prints the talk link. Refuses when the runtime is already served (any channel's lease, a running worker, or a loaded `com.tamoz.*` job for this runtime) or its folder is inside the workspace. | `tamoz telegram start`, `tamoz talk start` |
| `tamoz service install [--env-file F]`, `service status`, `service uninstall` | Writes, loads, reports and removes one launchd job per channel gateway plus one for the worker, from the config and `.env`. | the hand-edited plists |

Health stays where it is: `tamoz comms doctor` (channels) and `tamoz status` (work); `start` and
`service status` print the runtime's models and channels. `channel list/remove` are not built (`comms list`
and the config cover them; future plan).

### 4.4 Children get the runtime; `ChildEnvironments` composes their keys

The gateways and the worker receive `--runtime-dir` and read `models` from the config. `ChildEnvironments`
builds each child's environment from the config:

- **worker:** the chat model's key and endpoint variables, each configured role's credential, and every
  enabled source's `credential_refs` and `env_allowlist` values (this restores web search, which today's
  `telegram start` worker silently lacks);
- **gateway (telegram):** its bot token, unchanged;
- **gateway (talk):** its token and the voice credential, unchanged (ADR-042); the chat key is refused as
  the voice key by name and by value.

### 4.5 `.env`, the service and secrets

- `.env` is passed explicitly (`--env-file`, an absolute path is recorded); `start` and `service install`
  refuse a `.env` readable by group or others.
- `service install` writes each plist atomically with mode 0600 (create, then rename), backs up any existing
  `com.tamoz.*` plists to `<runtime>/service-backups/<stamp>/`, then loads the new jobs. The plists carry the
  values their child needs (launchd has no env file); the talk token is one of them, so
  `channel add talk --rotate-token` tells the operator to re-run `service install`.
- A separate plist writer owns what `ChildEnvironments` does not: the Ruby path, `-rbundler/setup`,
  `BUNDLE_GEMFILE`, `GEM_HOME/GEM_PATH`, `WorkingDirectory`, `KeepAlive`, `ThrottleInterval`, `ExitTimeOut`
  and log paths, all from the running Ruby and the checkout, with XML escaping.
- No command prints a secret: install, status and errors name variables, never values; `service status` reads
  the plist's arguments and the logs, never `launchctl print` (which shows the environment).
- The service runs the checkout it was installed from; the runbook says to install from a checkout kept on
  `main`.

### 4.6 The CLI (OD1)

With an explicit runtime, `ask/code/memory consolidate` take `models.chat` and the roles from the config and
keep reading sources from it as they already do. The workspace stays `--root` or the current folder, and the
existing workspace-mismatch refusal for MCP stays. Tools, approvals and history do not change.

### 4.7 Migrating the live runtime (OD4) — a runbook, delivered and rehearsed

`docs/one-setup-2026-10-09/RUNBOOK.md`, each step with its check:

1. `tamoz service status`-equivalent snapshot of the two hand-written jobs; note the database row counts and
   every bound thread's profile digest.
2. Stop both jobs (`launchctl bootout`), wait for the Telegram poller lease to expire, confirm no `tamoz`
   process serves `~/.tamoz`.
3. Take a consistent copy (`sqlite3 runtime.sqlite3 ".backup copy.sqlite3"` plus the rest of the folder);
   check the row counts and digests on the copy.
4. Rehearse on the copy with the live service still stopped: `tamoz setup --chat zai/glm-5.3-flash …`,
   `channel add talk`, `start` on a different talk port; Telegram and the page answer; stop it.
5. Apply the same `setup` and `channel add` to `~/.tamoz` (config backed up by `setup`).
6. `tamoz service install` from a checkout on `main` (the old plists are backed up).
7. Verify: the live checks in the bar (C rows); no old job or orphan worker serves the runtime.
8. **Rollback** (tested in the bar): `service uninstall`, restore `config.yaml` from its backup, put back
   the backed-up plists, `launchctl bootstrap` them; the old checkout starts on the restored config.

## 5. Phases

| Phase | Builds | Leaves working |
|---|---|---|
| P0 | This plan and its bar; two reviews; owner OK | — |
| P1 | `models` (chat, transcription, vision) in `RuntimeDirectory`; one credential rule; `ModelBuilder` resolves the runtime itself, so every command that builds a model reads it; `attachment_model` and the talk preflight read the roles; `worker_env` forwards the keys they name; the env readers stay and win for now | both old starts (they still set env, so `models.chat` is ignored there until P4); `models.voice` comes with P4, where talk is wired |
| P2 | `tamoz setup` (replaces `init`); the one-profile rule in `RuntimeDirectory` | old starts |
| P3 | `tamoz channel add telegram`, `channel add talk` (replace the two setups) | old starts |
| P4 | `tamoz start` (replaces both starts); `ChildEnvironments` composes from the config (worker sources, endpoints); **the env model variables and the old commands are removed here**, with every reader in §3's last row updated in the same phase | new start |
| P5 | `tamoz service install`, `status`, `uninstall`; the plist writer | — |
| P6 | ADR-062 (a runtime is one agent; channels are ways in); ADR-042/048/061 and the guides, reference and READMEs updated; `RUNBOOK.md` | — |
| P7 | Rehearsal on a copy, then the owner's `~/.tamoz` with the owner present; live checks | — |

Each phase: the properties' tests first; code written to the clean-code bar from the start (methods ≤ 20
lines, complexity ≤ 8, intent names; owner: high-quality code); `rubocop -a`; rows graded; two fresh reviewers
(the phase's safety or function lens, and code quality); fixes; commit. New test
files are split per command; the ones that drive processes go in `SLOW_TESTS`; no everyday file over 5 s.

## 6. Tests (properties that must hold)

- Config: `models` validated (a key-shaped `credential` refused and never echoed); a role without
  `credential` uses its provider's variable; `setup` writes `models` with a backup and leaves every other key
  semantically equal (not byte-equal: Psych re-serialises); two chat channels naming different profiles are
  refused.
- Model building: worker, `start` probes, CLI and `memory consolidate` take the config's model with the
  stated precedence; a source scan over the named files of §3's last row and the CLI finds no reader of the
  removed variables (allowlist: the CLI's `--provider/--model` flags).
- Children: each child's environment equals its rule, built from a config with web search enabled and a talk
  channel (golden, keys masked); mutation: forward the full `.env`.
- `start`: a second `start`, a `start` while a `com.tamoz.*` job for the runtime is loaded (launchctl
  fake), and a `start` on a talk-only runtime are each refused; a failing voice probe runs text-only and says
  so; a failing chat or transcription probe stops with its name; one subprocess test drives a fresh process.
- End to end (slow lane, injected waits, free ports, fake Telegram API): one `start` serves Telegram and the
  page through two gateways and one worker; both answer.
- Service: plists are pure output of the config, `.env` and checkout (golden, keys masked); compared field by
  field with the owner's current plists (masked fixture) so nothing they carry is lost; XML escaping with a
  path containing a space and a value with `<&>`; 0600, written atomically; install twice is a no-op;
  uninstall with the files already gone succeeds; uninstall touches only `com.tamoz.*` labels it wrote;
  no output contains a secret (mutation: print the env). A real-launchd smoke run is owner-only and marked
  BLOCKED in CI.
- Idempotence: `setup`, both `channel add`, `service install` re-run without change.
- Migration: a fixture of the owner's shape (two sources, a `telegram` channel with profile `telegram`, a
  bound thread) gets `models` and a talk channel, and the thread's pin still validates; the rollback restores
  the old config and plists and the old start validates the runtime.

## 7. Not in scope (future plan)

- The CLI sharing the abilities profile, workspace or history (OD1).
- Changing the workspace of a lived-in runtime.
- `channel list/remove`.
- A session-history tool; systemd or Windows services.
- The talk findings not about setup (`NEXT_SESSION.md` §2: empty recordings, Stop's repeated lines, voice
  language).

## 8. Risks

| Risk | Answer |
|---|---|
| The live service runs this checkout | All work happens in the worktree; the main checkout stays on `main` until the change is merged and P7 runs. |
| The migration breaks Telegram | Runbook: stop, consistent copy, rehearse, apply, verify; tested rollback; the owner present for P7. |
| Web search is lost | `ChildEnvironments` forwards every enabled source's credential and env; a golden test with web search enabled, and a live check. |
| A bound thread stops validating | No profile is ever rewritten; a fixture with a bound thread proves it. |
| Removing the env variables breaks scripts | Every reader is listed (§3) and changed in P4 with the commands; a source scan proves none is left. |
| The bot token sits in plists | The new worker plist holds no channel token (today's does); the Telegram gateway plist holds only its own. The token was seen in a review transcript on 2026-10-09: rotate it with @BotFather after P7. |
