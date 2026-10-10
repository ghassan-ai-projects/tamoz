# Channels as one abstraction — analysis and plan (revision 6)

**Owner:** Ghassan · **Set:** 2026-10-10 · **History:** rev 1 → two reviews → rev 2; owner: all channel code in
its adapter gem → rev 3 → two reviews → rev 4; owner: no migration path, no backward compatibility (ADR-059) →
rev 5 → two reviews → rev 6 ([`REVIEW.md`](REVIEW.md)) · **Branch:** `improve-channels` · **Bar:** [`QUALITY_BAR.md`](QUALITY_BAR.md) ·
**Deferred work:** [`FUTURE_PLAN.md`](FUTURE_PLAN.md)
**Governing ADRs:** 014 (adapters are a closed, first-party set), 041 (contract gem plus adapter gems), 042 (the
gateway is its own process, holding only its credential), 052 (facades), 059 (no compatibility before 1.0),
061 (talk), 062 (a runtime is one agent; channels are ways in)

## 1. Outcome

All of a channel's code lives in its adapter gem (`tamoz-telegram`, `tamoz-talk`): transport, runtime wiring,
setup and pairing, checks. Everywhere else holds only the interfaces it implements, declared in `tamoz-comms`,
and one line in the CLI's closed registry (owner, 2026-10-10). Telegram and the talk page behave as they do today:
same approvals, same admission, same credential isolation, same voice.

**Three independent proofs, all tests:**

1. **Names** — no channel kind is named in `gems/*/lib` outside the adapter gems and the registry
   (`channel_kind_containment_test`, exact counts per file).
2. **Dependencies** — `channel_dependency_test` counts every line outside the adapters that loads or names one
   (any `'tamoz/telegram…'` string, `Telegram::`/`Talk::` with or without `Tamoz::`, `const_get`), and no gemspec
   may depend on an adapter; the registry file is counted exactly, not exempted. Because a line count can still be
   dodged, the loopback test below also runs **in a subprocess with both adapter gems' `lib` removed from the load
   path** and asserts no adapter file is in `$LOADED_FEATURES` — the core and the CLI work without the adapters
   present, which no renaming can fake.
3. **Behavior** — a third, test-only channel kind (`test/support/loopback_channel.rb`: an in-memory `Transport`,
   `Channel` and `Setup`) is added by a test through `CLI.new(channel_kinds:)`, runs `channel add` and `start`'s
   checks (from C2b) and a full gateway pass — admit, enqueue, deliver (from C3, once the grammar admits a new
   kind) — and passes the transport conformance suite, with no other file changed. It is the third example the
   interfaces are checked against, so they are not two-channel-shaped.

**The measure.** Today a third channel touches about 17 code files in four gems outside its adapter, plus a schema
change (§3.6). After this plan it touches its own gem and the registry line, plus the new-gem registration every
gem needs (`Gemfile`, test load path, requirements/public-API/dependency manifests, README gem map).

**No upgrade path** (owner, 2026-10-10; ADR-059). The schema changes through one new migration ordinal, because
ordinals are monotonic and checksummed (AGENTS.md); it **recreates the comms tables empty** and carries nothing.
Memory, checkpoints and the effect journal live in the same database file and are untouched. What is lost, by
decision (OD-K): channel bindings, routes and the outbox; every chat restarts as after `/new` (long-term memory
carries over, because it is keyed by tenant, `memory/surface.rb:36`); and `tamoz_comms_decisions`, which also
holds the CLI's own `tamoz approve` records (`cli_worker_commands.rb:433-450`), so the approval audit restarts.
Channels are re-added with `tamoz channel add` (§6).

## 2. What is already right — keep it

The last two PRs (#73 audio, #78 one setup) built on a sound core; the plan extends these seams.

- **The worker is channel-blind.** It sees an `InboundEnvelope` and an attachment kind, and emits events to a
  `DeliverySink` (ADR-041). Transcription, the echo guard and the Heard notice key on the attachment
  (`kind == 'voice'`, `spoken_back`), never on the channel (`work_attachment.rb:31-51`).
- **One transport seam.** `Comms::Transport` (`authenticate`, `poll`, `deliver`, `fetch_attachment`, `signal`)
  is implemented by `Telegram::Transport` and `Talk::Transport`; the gateway, admission, approvals, commands and
  delivery drainer are shared.
- **One inbound model.** Talk adapts its push-shaped browser input to the same cursor-ordered, confirm-by-next-
  poll stream Telegram has (`Talk::Inbox`, `Talk::Clock` floored at the durable offset). One crash model and one
  dedupe rule serve both; a webhook path is not needed (FUTURE_PLAN F1).
- **Adapter gems stay small and fenced.** `tamoz-talk` needs only `tamoz-core` and `tamoz-comms`
  (`test/talk_boundary_test.rb`); speech is injected as a lambda.
- **Credential isolation per child** (`ChildEnvironments`, ADR-042/062).

## 3. Where the abstraction leaks — evidence

### 3.1 The contract gem enumerates the channels

| File:line | Leak |
|---|---|
| `tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:31,70` | `KINDS = %w[telegram talk]`; `build(... kind: 'telegram')` |
| `surface_descriptor.rb:151,191-201` | `validate_talk!` — a talk-only port/host rule in the shared value |
| `tamoz-comms/lib/tamoz/comms/parties.rb:11-24` | A per-kind table of id prefixes, group rules, thread prefix (`tg.`/`tk.`) and `speaks` |
| `tamoz-comms/lib/tamoz/comms/decision_record.rb:42-43` | `ACTOR_KINDS = %w[os_user telegram_user talk_user]`, `SOURCES = %w[cli telegram talk]` |
| `tamoz-sqlite/lib/tamoz/sqlite/migrator.rb:1394-1396` | The same lists as SQL `CHECK`s — **talk needed migration 25 just to be allowed to approve** |
| `tamoz-comms/lib/tamoz/comms/transport.rb:13-16,26-28` | The contract's prose describes Telegram |

### 3.2 Telegram's identity is everyone's identity

`expected_bot_id` is mandatory in the descriptor (`surface_descriptor.rb:203-208`) and config
(`runtime_config_rules.rb:36-38`), keys the poller lease and cursor, is in the inbound primary key, and is hashed
into every request id (`tamoz-core/lib/tamoz/core/request_identity.rb:18-21`). The talk channel has no bot, so
`channel add talk` **invents a random 12-digit bot id** (`cli_talk_commands.rb:54-55`).

### 3.3 The CLI is the real channel registry

| File:line | Branch |
|---|---|
| `cli_channel_commands.rb:9-17` | `CHANNELS` text and a `case` per kind |
| `cli_start_commands.rb:11,41,67,69-72,79-81` | `NO_CHANNELS` text; `TAMOZ_TALK_HOST`; `talk_channel`; `talk ? talk_problem : telegram_problem`; `talk_token_env` |
| `cli_start_checks.rb:9,18,62,74` | `NO_HEARING`, the lease check by `expected_bot_id`, `warn_voice`, `talk_models_problem` |
| `cli_service_commands.rb:42` | `talk_token_env` again, for launchd |
| `cli_comms_shared.rb:76,84,134-162` | `build_descriptor` defaults to Telegram and merges `talk:` into `transport`; `build_transport` special-cases talk; `comms_client_factory` is Telegram-only |
| `cli_comms_commands.rb:63,134-140,165,198,247-268` | talk hubs started/stopped by the CLI; `--once` refused for talk; `poll_interval` by kind; Telegram wording; `bot_id` in `comms list` |
| `cli_comms_doctor.rb:62,76,89-104,139,160` | `doctor_talk` branch; Telegram-only checks (`webhook`, `tls`) |
| `cli_comms_ops.rb:325` | reads `expected_bot_id` |
| `cli.rb:32-35` | `include`s of the four per-kind modules |
| `cli_talk_gateway.rb` (whole) | The talk hub's lifecycle and voice synthesizer live in the CLI, in `@talk_hubs` |
| `tamoz-agent/.../child_environments.rb:19,27-42` | `CHANNEL_TOKENS`, a talk branch, `TAMOZ_TELEGRAM_SURFACE`/`_API_ORIGIN`, `TAMOZ_TALK_TRACE` |
| `tamoz-agent/.../runtime_config_rules.rb:29-38` | Kind list from `SurfaceDescriptor::KINDS`; `expected_bot_id` mandatory |

### 3.4 One credential, two homes

Talk's `credential_ref` says `{kind: env, name: TAMOZ_TALK_TOKEN}`, but the token lives in `<runtime>/talk/token`;
`start` and `service` copy it into the environment (`talk_token_env`), and `doctor_talk` reads the file directly.

### 3.5 Presentation is keyed by kind name

`Parties::KINDS[kind].speaks` decides `spoken_back` (`gateway_attachments.rb:82`) and whether notices are delivered
(`outbox_delivery_sink.rb:81`). It is a property of how the surface presents, looked up by name in a core table,
and not in the digest-bound descriptor.

### 3.6 The cost of a third channel today

`surface_descriptor.rb`, `parties.rb`, `decision_record.rb`, a SQLite migration, `runtime_config_rules.rb`,
`child_environments.rb`, `cli_channel_commands.rb`, a new `cli_<kind>_commands.rb`, `cli_start_commands.rb`,
`cli_start_checks.rb`, `cli_service_commands.rb`, `cli_comms_shared.rb`, `cli_comms_commands.rb`,
`cli_comms_doctor.rb`, `cli.rb`, `agent_cli.rb` — plus the new-gem registration.

(enola's Ruby extractor does not see module-function calls such as `Parties.of_conversation`, so
`impact_analysis` reported one dependent for `Tamoz::Comms::Parties`; this inventory is from `grep` over
`gems/*/lib`, checked by both reviewers.)

### 3.7 Frozen, not removed

These name a channel and stay; the containment test freezes their exact counts rather than exempting the file, so
a new mention in them still fails: checksummed past migrations in `migrator.rb` (`:754,756,1394,1396`); benchmark
protocol code (`tamoz-evals-runner/.../openclaw_durable_cli_adapter.rb`, `openclaw_comms_oracles.rb`; ADR-058
reviewed updates only); the stream's approval escalation default (`tamoz-stream/.../approval_relay.rb:247`, where
Agentic Stream escalates — the Go repo's contract); benchmark readiness (`tamoz-evals-runner/.../readiness.rb:20`,
`MISSION_SURFACES`, ADR-058). `bin/` and `script/` are outside the scan.

## 4. Target design

1. **`tamoz-comms` knows the grammar of channels, not the list.** (§4.1)
2. **A channel kind is three objects in its adapter gem — `Transport`, `Channel` (runtime) and `Setup`
   (operator) — implementing interfaces from `tamoz-comms`, found through one closed registry in the CLI.**
   (§4.2, §4.3)
3. **A channel sees only what it declares:** its descriptor (validated by its own kind) and its declared
   environment variables. (§4.3, §4.4)

### 4.1 `tamoz-comms`: grammar, not a list

- **`kind`** is a well-formed name, `/\A[a-z][a-z0-9_]{1,31}\z/`, with `os` and `cli` reserved (they would collide
  with actor `os_user` and source `cli`). The closed set (ADR-014) is the registry (§4.3).
- **Party ids** follow one grammar, split on the first two colons: correspondent `<kind>:user:<id>`, conversation
  `<kind>:<space>:<id>`, `space ∈ {chat, group, supergroup, channel}`, `<id>` = `-?[0-9]{1,20}` (Telegram
  supergroups are negative). Only `chat` is bindable; other spaces are refused groups — today's rule for both
  kinds, so `Parties` becomes a parser with no table. A party of another kind than the surface's is refused.
- **Identity** is `{stream_id: String}`: the remote update stream a surface consumes, which must start with
  `"<kind>:"` — Telegram `"telegram:bot:<id>"`, talk `"talk:<surface_id>"`. It keys the poller lease, the cursor,
  the inbound anchor and `Core::RequestIdentity`, and `authenticate` must return exactly it. Two Telegram surfaces
  on one bot still share one stream and one lease; talk no longer invents a bot number; the prefix rule means
  streams of different kinds cannot collide.
- **Commands** — `Commands.parse(text)` loses `bot_username:`. The Telegram normalizer, which already knows its bot
  (`normalizer.rb:26-29`), strips a `@<own bot>` suffix; any other `@suffix` stays and fails to parse, as today.
  `bot_username` leaves the core identity for Telegram's `settings`.
- **Decision actor and source** — either `os_user` with `cli`, or `<kind>_user` with source `<kind>` — the same kind
  on both sides, checked in Ruby and by a SQL `CHECK` (`actor_kind = source || '_user'`). Stricter than HEAD,
  which accepts `telegram_user` with source `talk`.
- **`authenticate(descriptor)`** returns `{'stream_id' => String}`, compared exactly with the descriptor; the unused
  `credential` argument goes (neither transport reads it, `gateway.rb:292`), and so does the gateway's
  `respond_to?(:authenticate)` escape (`gateway.rb:291`): every transport authenticates.
- **Thread ids** — `"<kind>.<surface_id>.<digest>"` (was `tg.`/`tk.`).
- **Descriptor fields** — kind-specific `settings` (opaque to the core, digest-bound, a flat JSON object of at most
  4096 bytes); `rendering.speech`
  (boolean, replaces `Parties::KINDS[kind].speaks`); `transport` keeps `credential_ref`, `poll_timeout_s`, `batch`,
  `max_response_bytes` and drops `mode` (one allowed value carries no information).
- **The transport contract's prose** describes the contract; Telegram and talk are examples.

**Deliberately unchanged** (no channel needs a change; AGENTS.md "no rare cases"): message refs stay integers —
Telegram, talk and the loopback test channel all use integer ids; the 4096-character part ceiling stays a core
bound (both kinds fit it). A channel that needs either changes them then (FUTURE_PLAN F3).

### 4.2 The runtime half: `Tamoz::<Kind>::Channel`

```ruby
module Tamoz::Comms::Channel
  def validate!(descriptor) = raise NotImplementedError   # refuses settings or rendering options it cannot serve
  def connect(descriptor, env:, voice: nil) = raise NotImplementedError   # → Connection, nothing started yet
end
# Connection: #transport, #start(floor:, history:), #stop, #interval_s
#   #start raises Comms::ConnectionError with its own message (e.g. the talk port is taken)
```

| Argument | Why every kind gets it |
|---|---|
| `env` | the kind's declared variables only (§4.3): Telegram's token and its loopback-only API origin (OD-G), talk's token path is in `state_dir`, its trace flag in `env` |
| `voice` | the synthesizer lambda, built by the CLI only when `rendering.speech` is on — the adapter holds no model code |
| `floor`, `history` (to `start`) | the durable cursor and delivered rows, as data, read **after** the lease is held so they cannot be stale — talk seeds its page; Telegram ignores them; neither touches the store |

- `Telegram::Channel#validate!` refuses `rendering.speech` and any `settings` key but `bot_username`; `#connect`
  builds client, normalizer and transport; `start`/`stop` are no-ops; `interval_s` 1.0. One transport serves the
  poller and the drainer (today two are built); safe because `Telegram::Client` opens a fresh `Net::HTTP` per call.
  The API origin is accepted only when it is `http://` on `127.0.0.1`, `localhost` or `[::1]` — the fake Bot API
  the evals run, never a remote host (OD-G).
- `Talk::Channel#validate!` holds today's port and `allow_hosts` rule and the "a non-loopback host needs
  `allow_hosts`" rule, which today only `start` enforces (`cli_talk_commands.rb:93`); `#connect` builds the hub;
  `start`/`stop` run the HTTP server; `interval_s` 0.1.
- The credential check is kind-blind and in one place: the CLI's `build_descriptor` refuses a `credential_ref.name`
  outside the setup's `env_names`, and calls `validate!`. `serve`, `start`, `doctor` and `add` all use it.
- `comms serve` is kind-blind. A surface's connection **and its drainer** start only from the gateway's
  `on_started` callback, once the lease is held — `Gateway#serve_loop(on_started:)` is the one gateway seam
  (`serve_loop` calls `start` on its own thread, `gateway.rb:167-170`). A second run therefore ends as
  `:poller_busy`, claims no outbox row and exits 1; today the drainer runs without a lease
  (`delivery_drainer.rb:79`, built at `cli_comms_commands.rb:213`). `--once` works for every kind.

### 4.3 The operator half: `Tamoz::<Kind>::Setup`; the registry

A setup never sees `RuntimeDirectory`, the store or a model (ADR-052: adapters depend only on `tamoz-core` and
`tamoz-comms`); it takes and returns plain data. Every method has a caller; none exists for symmetry:

| Method | Caller | Today |
|---|---|---|
| `summary` → one line | `tamoz channel` usage | `CHANNELS` (`cli_channel_commands.rb:9-10`) |
| `env_names` → names | the CLI's env slice; `build_descriptor`'s credential check; the worker's denylist | `CHANNEL_TOKENS` + extras (`child_environments.rb:19,30-41`) |
| `add(entries:, argv:, env:, state_dir:, terminal:)` → `[surface_id, entry]` | `tamoz channel add <kind>` | `channel_add_telegram` + pairing; `channel_add_talk` + token file |
| `check(descriptor:, env:, state_dir:, poller_free:)` → `[[name, true \| message], …]` | `start` (refuses on the first failure), `comms doctor` (prints all) | `telegram_problem`, `talk_problem`, `doctor_surface`'s Telegram body, `doctor_talk` |
| `announce(descriptor:, env:, terminal:)` | `start`, after the checks, with `env` already merged with `gateway_env` | `announce_talk` (the link with its token) |
| `gateway_env(descriptor:, env:, state_dir:)` → variables | `start`, `service install` | Telegram: its env slice; talk: token from `state_dir`, trace |

- `Comms::ChannelSetup` gives `announce` (silent) and `gateway_env` (`env.slice(*env_names)`) default bodies;
  `summary` has none — every kind describes itself.
- `add` fails by raising `Comms::SetupError` with a message the CLI prints; no return codes cross the interface.
- `state_dir` is `<runtime>/channels/<surface_id>/`, created and secured (0700) by the CLI. It is the only folder a
  setup may touch — not the runtime root, which holds the config, the database and other channels' state. Talk's
  token moves there (no compatibility to keep).
- `terminal` has `say(text)` and `confirm(question)`, implemented by the CLI, so the owner confirmation in
  Telegram pairing is still the CLI's prompt.
- `Telegram::Setup#add`, after the owner confirms, **confirms through the newest update** (`getUpdates
  offset: -1`, then `offset: last + 1`), so nothing sent while the bot was unpaired is answered later
  (`cli_telegram_pairing.rb:18-38` today confirms only up to the pairing message).

**A setup sees only what it declares.** Every setup method and `connect` get `env.slice(*setup.env_names)` — never
the whole environment, so adapter code cannot forward the chat key, another channel's token or `TAMOZ_ENV_FILE`.

**What stays in the CLI, the same for every kind:** `--env-file` reading with its 0077 check; the "runtime folder
inside the workspace" refusal, now run by `channel add` for every kind (today only talk's add and `start`,
`cli_talk_commands.rb:24`, `cli_start_commands.rb:59`); `save_channel`'s revision bump and `build_descriptor`;
securing `state_dir`; the poller-lease checks, passed to `check` as `poller_free:`; and the model checks, keyed on
`rendering.speech`, not on a kind (a speaking surface needs a transcription model and a voice key different from
the chat key; the CLI builds `voice`).

```ruby
CHANNEL_KINDS = {               # the closed set (ADR-014); one line per first-party channel
  'telegram' => ChannelKind.new(gem: 'tamoz/telegram', namespace: 'Tamoz::Telegram'),
  'talk'     => ChannelKind.new(gem: 'tamoz/talk',     namespace: 'Tamoz::Talk')
}.freeze
# ChannelKind#channel / #setup build instances after one lazy require; a test passes its own kind objects
```

- `channel add`, `start`, `service`, `comms serve`, `comms doctor` iterate the registry; an unknown kind is refused
  there (`ConfigRules` in `tamoz-agent` checks only the name's shape; it cannot see the CLI).
- **Child environments** (`ChildEnvironments`, in `tamoz-agent`, which cannot see the registry):
  `gateway_env(base, directory:, vars:, allowed:, voice_keys:)`. The CLI passes the setup's `gateway_env` result as
  `vars` and the kind's `env_names` as `allowed`; anything outside `allowed` + `TAMOZ_RUNTIME_DIR` is refused; the
  voice role's keys are merged after that check, only for a speaking surface. A gateway's environment is then
  exactly: the standard variables (`PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB`), `TAMOZ_RUNTIME_DIR`,
  `child_runtime_env`, its kind's `gateway_env`, and — if speaking — the voice keys. The worker's denylist is the
  union of the **loadable** registry kinds' `env_names` and every configured entry's `credential_ref.name`, enabled
  or not, applied after the model keys are merged. `start` refuses a model credential named like a channel
  variable, so that drop is never silent.
- **Test seam:** `CLI.new(channel_kinds:)` replaces `comms_client_factory:`; a test builds its own kind object (a
  Telegram one over a fixture client, or the loopback). The generic registry has no client hook.
- A missing adapter gem is `MissingAdapterError`, from the registry's one lazy `require`.
- Moved, then simplified: `cli_telegram_commands.rb`, `cli_telegram_pairing.rb`, `cli_talk_commands.rb`,
  `cli_talk_gateway.rb`, their `include`s (`cli.rb:32-35`), and the per-kind bodies of `cli_comms_doctor.rb`. The
  CLI ends with no per-kind file.
- Deleted (ADR-059): `comms doctor --bootstrap` (Telegram-only; `channel add telegram` records the stream),
  `TAMOZ_TELEGRAM_SURFACE` (read nowhere), `start --host`/`TAMOZ_TALK_HOST` (the address is talk's `settings.host`,
  set by the new `channel add talk --host`).

### 4.4 The descriptor

| Field | Today | Target |
|---|---|---|
| `kind` | member of `KINDS` | a well-formed name; registry-checked at the CLI |
| `identity` | `{expected_bot_id: Integer, bot_username:}` (talk: random number) | `{stream_id: "<kind>:…"}` |
| `transport` | mode, credential, poll timeout, batch, response cap, **talk's port/hosts** | credential, poll timeout, batch, response cap |
| `settings` | — | the kind's own section (≤ 4096 bytes), checked by `Channel#validate!` (Telegram: `bot_username`; talk: `port`, `allow_hosts`, `host`) |
| `rendering.speech` | `Parties::KINDS[kind].speaks` | a boolean; only a kind whose `validate!` allows it may set it |

Credentials stay env-only (a `file` credential adds a mechanism without isolation — the worker runs as the same
OS user; FUTURE_PLAN F8).

### 4.5 The schema

One new migration recreates every `tamoz_comms_*` table empty in the new shape — `stream_id TEXT` where `bot_id
INTEGER` was, the pairing `CHECK` for decision actor and source — and carries no row (ADR-059; it assumes a fresh
schema). No other table is touched.

## 5. Phases

Each phase is one commit or a short series, green on `rake ci`, reviewed by a fresh subagent against the bar
before commit. No commit leaves a check weaker than at HEAD: `KINDS` and `validate_talk!` leave the core in the
commit that adds the name rule, the registry and the CLI's credential check.

| Phase | Change | Proves it |
|---|---|---|
| **C0** Measures *(done, `a1c8c207`)* | `channel_kind_containment_test`, `channel_dependency_test` holding today's exact counts. | Pass at HEAD; each phase lowers them in the same commit |
| **C1** Conformance *(done, `a1c8c207`)* | `test/support/transport_conformance.rb` run by both transport tests: identity; well-formed polls with an integer cursor; an unconfirmed batch redelivered and the cursor releasing exactly it; an empty poll with no cursor; receipts; attachment limits; typing and unknown signals. | Mutating either transport's cursor (`+ 1` dropped) or size check fails it |
| **C2a** Interfaces and runtime half | `Comms::Channel`, `Comms::ChannelSetup` (reviewed as Ruby before any implementation), `Comms::SetupError`, `Comms::ConnectionError`, the registry, `Telegram::Channel`, `Talk::Channel`, the kind-name rule (also in `runtime_config_rules.rb:29-31`, which reads `KINDS`), `settings` + `rendering.speech`, `build_descriptor`'s credential check and `validate!`, `Gateway#serve_loop(on_started:)`, connection and drainer started from it, a kind-blind `comms serve`. | Serve-path tests (`comms_serve_supervision_test`, `talk_end_to_end_test`, `talk_comms_cli_test`, `talk_gateway_test`, `comms_gateway_test`); new: unknown kind refused; `speech` refused on Telegram; remote API origin refused; non-loopback talk host without `allow_hosts` refused by `serve`; a second run is `:poller_busy`, exits 1 and claims no delivery |
| **C2b** Setup half and child environments | `Telegram::Setup`, `Talk::Setup` moved from the CLI modules (backlog confirmation added); `state_dir`; env slicing; `channel add`/`start`/`doctor`/`service` iterate the registry; the generic CLI checks; `ChildEnvironments` by `vars:`/`allowed:`/`voice_keys:`; the loopback channel (add and checks); `telegram_boundary_test`. | `cli_channel_*`, `cli_start_test`, `cli_service_test`, `comms_cli_test`, `child_environments_test`; bar A1–A4, A11; a spy setup receives only its `env_names`; pairing confirms the backlog (`TelegramBotApiFake` holding three older updates) |
| **C3** Grammar, identity, schema | §4.1 and §4.5: `Parties` parser, `stream_id` through descriptor, `CommsStore` keywords, gateway, both transports, `Core::RequestIdentity` and the CLI readers (`cli_comms_commands.rb:247`, `cli_comms_doctor.rb:139`, `cli_comms_ops.rb:325`, `cli_start_checks.rb:18`); `authenticate(descriptor)`; the command suffix to the Telegram normalizer (`admission.rb:32-79`, `gateway_pairing.rb:16`, `gateway_admission.rb:28`); decision pairing rule; thread prefix; migration 26; the loopback channel's full gateway pass, in and out of a subprocess without the adapters. | `comms_parties_test`, `comms_admission_test`, `comms_decision_record_test`, `sqlite_comms_store_test`, `comms_seams_test`; migration on a fresh schema and on version 25; two Telegram surfaces on one bot conflict on the lease; a talk surface cannot hold a Telegram stream; `/help@otherbot` is not a command; `telegram_user` with source `talk` refused |
| **C4** Records | ADR-041 (grammar; `Channel`/`ChannelSetup`; the closed set in the registry), ADR-042 (gateway env by declared names; loopback-only API origin), ADR-061 (its `Parties` table, `tg.`/`tk.` and "speaks" text, line 24), ADR-062 (child env; `start --host` gone; "the runtime's own keys are set last" at line 57 replaced by the declared-names rule), ADR-014 Relates; READMEs of the comms gems; `documentation/guides/telegram.md` (`--bootstrap` at 74-83, the origin at 280), `documentation/guides/talk.md` (`--host` at 74); `documentation/guides/adding-a-channel.md`. | `rake adr:validate adr:verify`; the guide's steps are the loopback test's |

**Tests that change on purpose, and only these** (bar B2 — each diff is a rename, a move or a deletion of a removed
feature, checked by `git diff --word-diff`):

| Phase | Files | Why |
|---|---|---|
| C2a | `talk_comms_cli_test.rb:36` | the "port taken" wording comes from `Comms::ConnectionError` |
| C2a | `talk_hub_test.rb`, `talk_fixtures.rb`, `comms_gateway_harness.rb` and other descriptor builders | `port`/`allow_hosts` move from `transport` to `settings`; `mode` dropped |
| C2b | `cli_start_test.rb:269,277` | `start --host` cases move to `channel add talk --host` |
| C2b | `comms_cli_test.rb:133` | `--bootstrap` deleted |
| C2b | `child_environments_test.rb:79,87`; `cli_channel_*_test.rb`; `cli_service_test.rb`; `cli_start_test.rb`; `comms_cli_test.rb` | the new child-env signature; `channel_kinds:` replaces `comms_client_factory:`; the talk token in `state_dir`; `talk_boundary_test`'s `.speak(` caller list |
| C3 | the 37 files naming `bot_id`/`expected_bot_id` (`cli_channel_telegram_test.rb:40,176,272`, `cli_start_test.rb:202`, …); `sqlite_comms_store_test.rb:212-287`, `comms_values_test.rb:210` | `stream_id`; the `telegram.`/`talk.` thread prefix |

C0 and C1 come first: C0 measures the outcome, C1 pins the transport behavior every later phase must keep.

**Real-model evaluation (AGENTS.md).** `script/telegram_attachment_eval` runs before C2a and after C3 on the same
model; the report gives both, and a BLOCKED or SHORT run is reported, never counted as a pass (bar C1). The talk
eval (`script/talk_eval`) likewise.

**Wire and digests.** The descriptor's wire and `definition_digest` change; surfaces are re-added (§6). No pinned
digest covers the surface descriptor (`grep` of `documentation/benchmark` and `test/fixtures` for
`definition_digest`, `expected_bot_id`, `tg.`: no hit, 2026-10-10).

## 6. Moving the live runtime (a runbook, not code)

0. **Rotate the bot token** at @BotFather first and put the new one in the env file — the worker, which runs the
   model's tools, has held the old one through the hand-edited plist, and the plists store values
   (`cli_service_commands.rb:68-71`), so rotating later would leave the gateway on a revoked token.
1. Run `tamoz status` until `pending_work` and `paused_approvals` are empty (deny what is waiting with
   `tamoz approve ID --deny`), then `tamoz service uninstall`. Queued requests live in `tamoz_requests`, which the
   migration keeps; a request run after the comms tables are recreated has no route, and its answer would go
   nowhere (`outbox_delivery_sink.rb:57-58`).
2. Delete **all** of `<runtime>/service-backups/` (`uninstall` adds the leaky worker plist there; older backups may
   hold more copies), the old `<runtime>/talk/` folder, and the `channels:` block of `config.yaml` — the new config
   rules refuse its removed keys by name.
3. Pull, then `tamoz channel add telegram` (it confirms Telegram's backlog after pairing, §4.3) and
   `tamoz channel add talk --host …`.
4. `tamoz start` once (migration 26 runs when the database opens, `adapter.rb:108`), check both channels, stop it,
   then `tamoz service install --env-file …`.

Memory and the effect journal are kept; chats restart as after `/new`; Telegram pairing, the talk link and the
approval audit are re-made.

## 7. Owner decisions

| # | Decision | Status |
|---|---|---|
| OD-A | ~17 files and a schema change for no user-visible feature | Accepted (owner, "let us start implementing", 2026-10-10) |
| OD-G | `TAMOZ_TELEGRAM_API_ORIGIN` stays — the Telegram evals run real `tamoz` processes against a fake Bot API through it (`test/support/telegram_chat_eval.rb:414`) — but only as a loopback `http://` origin, so it can no longer send the token to another host | Revised after review: removing it would break the evals AGENTS.md requires |
| OD-J | Rotate the Telegram bot token | Owner action, §6 step 0 |
| OD-K | Recreate only the comms tables (keep memory); lost: channel state, chat continuity, the approval audit (including CLI `approve` records) | Accepted |
| OD-L | Cross-gem interface changes (AGENTS.md "ask before"): `Comms::Transport#authenticate(descriptor)` → `{'stream_id'}`; the `CommsStore` keywords (`bot_id:` → `stream_id:`); `Core::RequestIdentity`'s keyword; `Gateway.new` (no `credential:`) and `Gateway#serve_loop(on_started:)`; `ChildEnvironments.gateway_env`'s signature; new `Comms::Channel`, `Comms::ChannelSetup`, `SetupError`, `ConnectionError` | Part of the accepted plan; listed here so each is visible |

Settled by "no backward compatibility": thread prefix change, `--once` for talk, `start --host` removal,
`--bootstrap` removal, no upgrade script.

## 8. The web page and the CLI

**The web page is a channel and is fully in this plan.** The talk page (`tamoz-talk`) is the only web interface in
the repository (the only other HTTP listener is the kernel's witness gateway, not a user surface).

**The CLI (`tamoz ask`, `code`, `investigate`, `resume`, …) is not a channel**, on purpose; both review rounds
agreed:

| | Channel (Telegram, talk) | CLI |
|---|---|---|
| Where the turn runs | the shared worker, through the request inbox | in the CLI process (`CLI::TurnDriver`) |
| How output arrives | journaled outbox → drainer → transport | live graph events through `StreamSink` (`cli_turn_stream.rb:25`) |
| Who answers approvals | a remote correspondent, deny-only, evidence-gated (ADR-049) | the OS user at the terminal, with scoped grants |
| Tools, approvals, history | the runtime's | its own (ADR-062) |

Routing the CLI through the gateway would turn operator-scoped grants into remote deny-only approvals and lose the
live stream. There is no duplicated code between the two paths to remove. There is a gap: in production the
gateway gets no context-controls source (`comms_controls_source` returns `nil`, `cli_comms_shared.rb:173-175`), so
on Telegram and talk `/compact`, `/reset`, `/think`, `/verbose`, `/usage` and `/context` answer "not available"
while the CLI's verbs work — FUTURE_PLAN F10. A terminal that attaches to the running runtime as a channel is
FUTURE_PLAN F9; the loopback test channel (§1) proves such a kind needs only its own code.

## 9. Not in scope

Webhook transports, Telegram voice replies, a real third channel, string message refs, `file` credentials,
`channel list|remove`, third-party adapters, one pairing flow, a terminal channel, context controls on channels —
all in [`FUTURE_PLAN.md`](FUTURE_PLAN.md).
