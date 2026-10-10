# Channels as one abstraction — analysis and plan (revision 5)

**Owner:** Ghassan · **Set:** 2026-10-10 · **History:** rev 1 → two reviews → rev 2; owner: all channel code in
its adapter gem → rev 3 → two reviews → rev 4; owner: no migration path, no backward compatibility (ADR-059) →
rev 5 ([`REVIEW.md`](REVIEW.md)) · **Branch:** `improve-channels` · **Bar:** [`QUALITY_BAR.md`](QUALITY_BAR.md) ·
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
2. **Dependencies** — no gem outside the adapters requires `tamoz/telegram` or `tamoz/talk` or references
   `Tamoz::Telegram`/`Tamoz::Talk`, except the registry's one lazy load; no gemspec depends on an adapter
   (`channel_dependency_test`). Names can be renamed away; dependencies cannot.
3. **Behavior** — a third, test-only channel kind (`test/support/loopback_channel.rb`: an in-memory `Transport`,
   `Channel` and `Setup`) is added by a test with one injected registry entry, runs `channel add`, `start`'s checks
   and a gateway pass end to end, and passes the transport conformance suite — with no other file changed. This
   is the third example the interfaces are checked against, so they are not two-channel-shaped.

**The measure.** Today a third channel touches about 17 code files in four gems outside its adapter, plus a schema
change (§3.6). After this plan it touches its own gem and the registry line, plus the new-gem registration every
gem needs (`Gemfile`, test load path, requirements/public-API/dependency manifests, README gem map).

**No upgrade path** (owner, 2026-10-10; ADR-059). The schema changes through one new migration ordinal, because
ordinals are monotonic and checksummed (AGENTS.md); it **recreates the comms tables empty** and carries nothing.
Memory, checkpoints and the effect journal live in the same database file and are untouched. Channels are
re-added with `tamoz channel add` (§6).

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
Agentic Stream escalates — the Go repo's contract). `bin/` and `script/` are outside the scan.

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
- **Decision actor and source** — `actor_kind ∈ {os_user, <kind>_user}`, `source ∈ {cli, <kind>}`, checked by the
  same name rule in Ruby and by shape `CHECK`s in SQL.
- **Thread ids** — `"<kind>.<surface_id>.<digest>"` (was `tg.`/`tk.`).
- **Descriptor fields** — kind-specific `settings` (opaque to the core, digest-bound); `rendering.speech`
  (boolean, replaces `Parties::KINDS[kind].speaks`); `transport` keeps `credential_ref`, `poll_timeout_s`, `batch`,
  `max_response_bytes` and drops `mode` (one allowed value carries no information).
- **The transport contract's prose** describes the contract; Telegram and talk are examples.

**Deliberately unchanged** (no channel needs a change; AGENTS.md "no rare cases"): message refs stay integers —
Telegram, talk and the loopback test channel all use integer ids; the 4096-character part ceiling stays a core
bound (both kinds fit it). A channel that needs either changes them then (FUTURE_PLAN F3).

### 4.2 The runtime half: `Tamoz::<Kind>::Channel`

```ruby
module Tamoz::Comms::Channel
  def validate!(descriptor) = raise NotImplementedError   # refuses settings, rendering, credential options it cannot serve
  def connect(descriptor, env:, floor:, history:, voice: nil) = raise NotImplementedError   # → Connection
end
# Connection: #transport, #start, #stop, #interval_s.  #start raises Comms::ConnectionError with its own message.
```

| Argument | Why every kind gets it |
|---|---|
| `env` | the kind's declared variables only (§4.3): Telegram's token and API origin (OD-G), talk's token and trace flag |
| `floor`, `history` | the durable cursor and delivered rows, as data — talk seeds its page; Telegram ignores them; neither touches the store |
| `voice` | the synthesizer lambda, built by the CLI only when `rendering.speech` is on — the adapter holds no model code |

- `Telegram::Channel#validate!` refuses `rendering.speech` and any `settings` key but `bot_username`; `#connect`
  builds client, normalizer and transport; `start`/`stop` are no-ops; `interval_s` 1.0. One transport serves the
  poller and the drainer threads (today two are built); safe because `Telegram::Client` opens a fresh
  `Net::HTTP` per call.
- `Talk::Channel#validate!` holds today's port and `allow_hosts` rule and the "a non-loopback host needs
  `allow_hosts`" rule, which today only `start` enforces (`cli_talk_commands.rb:93`); `#connect` builds the hub;
  `start`/`stop` run the HTTP server; `interval_s` 0.1.
- Every `validate!` refuses a `credential_ref.name` outside its setup's `env_names`, so a config cannot point a
  gateway at the chat key.
- `validate!` is called in one place: the CLI's `build_descriptor`, used by `serve`, `start`, `doctor` and `add`.
- `comms serve` is kind-blind and starts each connection only after the gateway holds the lease, so a second run
  is `:poller_busy`, not `EADDRINUSE`. One gateway seam makes that possible, because `serve_loop` calls `start` on
  its own thread (`gateway.rb:167-170`): `Gateway#serve_loop(on_started:)`. `--once` works for every kind.

### 4.3 The operator half: `Tamoz::<Kind>::Setup`; the registry

A setup never sees `RuntimeDirectory`, the store or a model (ADR-052: adapters depend only on `tamoz-core` and
`tamoz-comms`); it takes and returns plain data. Every method has a caller; none exists for symmetry:

| Method | Caller | Today |
|---|---|---|
| `summary` → one line | `tamoz channel` usage | `CHANNELS` (`cli_channel_commands.rb:9-10`) |
| `env_names` → names | the CLI's env slice; `ChildEnvironments`' denylist; `validate!`'s credential check | `CHANNEL_TOKENS` + extras (`child_environments.rb:19,30-41`) |
| `add(entries:, argv:, env:, runtime_path:, terminal:)` → `[surface_id, entry]` | `tamoz channel add <kind>` | `channel_add_telegram` + pairing; `channel_add_talk` + token file |
| `check(descriptor:, env:, runtime_path:, poller_free:)` → `[[name, true \| message], …]` | `start` (refuses on the first failure), `comms doctor` (prints all) | `telegram_problem`, `talk_problem`, `doctor_surface`'s Telegram body, `doctor_talk` |
| `announce(descriptor:, env:, terminal:)` | `start`, after the checks | `announce_talk` (the link) |
| `gateway_env(descriptor:, env:, runtime_path:)` → variables | `start`, `service install` | Telegram: its env slice; talk: token from its file, host, trace |

`Comms::ChannelSetup` gives `summary`, `announce` (silent) and `gateway_env` (`env.slice(*env_names)`) default
bodies, so Telegram overrides only what differs. `terminal` has `say(text)` and `confirm(question)`, implemented
by the CLI, so the owner confirmation in Telegram pairing is still the CLI's prompt.

**A setup sees only what it declares.** Every setup method and `connect` get `env.slice(*setup.env_names)` — never
the whole environment, so adapter code cannot forward the chat key, another channel's token or `TAMOZ_ENV_FILE`.
`ChildEnvironments` refuses any `gateway_env` key outside `env_names` + `TAMOZ_RUNTIME_DIR`, and any forbidden or
model-role key.

**What stays in the CLI, the same for every kind:** `--env-file` reading with its 0077 check; the "runtime folder
inside the workspace" refusal, now run by `channel add` for every kind (today only talk's add and `start`,
`cli_talk_commands.rb:24`, `cli_start_commands.rb:59`); `save_channel`'s revision bump and `build_descriptor`;
the poller-lease checks, passed to `check` as `poller_free:`; and the model checks, keyed on `rendering.speech`,
not on a kind (a speaking surface needs a transcription model and a voice key different from the chat key; the CLI
builds `voice` and adds the voice key to that gateway's environment).

```ruby
CHANNEL_KINDS = {               # the closed set (ADR-014); one line per first-party channel
  'telegram' => ChannelKind.new(gem: 'tamoz/telegram', namespace: 'Tamoz::Telegram'),
  'talk'     => ChannelKind.new(gem: 'tamoz/talk',     namespace: 'Tamoz::Talk')
}.freeze
# ChannelKind#channel(client_factory: nil) / #setup(client_factory: nil) build instances after one lazy require
```

- `channel add`, `start`, `service`, `comms serve`, `comms doctor` iterate the registry; an unknown kind is refused
  there (`ConfigRules` in `tamoz-agent` checks only the name's shape; it cannot see the CLI).
- `ChildEnvironments` (in `tamoz-agent`) takes explicit `gateway_vars:` and `channel_names:` from the CLI — the
  union of every registry kind's `env_names` and every entry's `credential_ref.name`, enabled or not — and applies
  the worker's denylist **after** the model keys are merged.
- **Test seam:** `CLI.new(channel_kinds:)` replaces `comms_client_factory:`; a test passes `client_factory:` for one
  kind, or adds the loopback kind. Tests change their setup line, not their assertions.
- A missing adapter gem is `MissingAdapterError`, from the registry's one lazy `require`.
- Moved, then simplified: `cli_telegram_commands.rb`, `cli_telegram_pairing.rb`, `cli_talk_commands.rb`,
  `cli_talk_gateway.rb`, their `include`s (`cli.rb:32-35`), and the per-kind bodies of `cli_comms_doctor.rb`. The
  CLI ends with no per-kind file. `talk_boundary_test`'s list of `.speak(` callers changes from
  `cli_talk_gateway.rb` to the CLI file that builds `voice` — the one expected assertion change.
- Deleted (ADR-059): `comms doctor --bootstrap` (Telegram-only; `channel add telegram` records the stream),
  `TAMOZ_TELEGRAM_SURFACE` (read nowhere), `start --host`/`TAMOZ_TALK_HOST` (the address is talk's `settings.host`,
  set by `channel add talk --host`).

### 4.4 The descriptor

| Field | Today | Target |
|---|---|---|
| `kind` | member of `KINDS` | a well-formed name; registry-checked at the CLI |
| `identity` | `{expected_bot_id: Integer, bot_username:}` (talk: random number) | `{stream_id: "<kind>:…"}` |
| `transport` | mode, credential, poll timeout, batch, response cap, **talk's port/hosts** | credential, poll timeout, batch, response cap |
| `settings` | — | the kind's own section, checked by `Channel#validate!` (Telegram: `bot_username`; talk: `port`, `allow_hosts`, `host`) |
| `rendering.speech` | `Parties::KINDS[kind].speaks` | a boolean; only a kind whose `validate!` allows it may set it |

Credentials stay env-only (a `file` credential adds a mechanism without isolation — the worker runs as the same
OS user; FUTURE_PLAN F8).

### 4.5 The schema

One new migration recreates every `tamoz_comms_*` table empty in the new shape — `stream_id TEXT` where `bot_id
INTEGER` was, shape `CHECK`s for decision actor and source — and carries no row (ADR-059; it assumes a fresh
schema). No other table is touched.

## 5. Phases

Each phase is one commit or a short series, green on `rake ci`, reviewed by a fresh subagent against the bar
before commit. No commit leaves a check weaker than at HEAD: `KINDS` and `validate_talk!` leave the core in the
commit that adds the name rule, the registry and `Channel#validate!`.

| Phase | Change | Proves it |
|---|---|---|
| **C0** Measures | `channel_kind_containment_test` and `channel_dependency_test`, holding today's exact counts and references. Containment: Ripper tokens of `gems/*/lib/**/*.rb` (comments dropped); each string, symbol, constant and identifier split on `_`, punctuation and lower→upper case changes, downcased, parts equal to `telegram`/`talk`/`tg`/`tk` counted; exact count per file; its own unit cases (`talk_hub`, `CLITalkCommands`, `TAMOZ_TALK_TOKEN`, `'telegram_user'`, `:talk`, `"tg."` each count once). | Both pass at HEAD with today's numbers; every later phase lowers them in the same commit |
| **C1** Conformance | `test/support/transport_conformance.rb`: properties every transport shares, no skips — `authenticate` returns the configured identity; `poll` returns well-formed envelopes and a cursor past the last update, and redelivers what was not confirmed; `deliver` returns a receipt with a message id; `fetch_attachment` over `max_bytes` raises `ResponseTooLargeError`; an unknown signal is `:unsupported`. | Telegram and talk pass; mutating either's cursor or size check fails |
| **C2a** Interfaces and runtime half | `Comms::Channel`, `Comms::ChannelSetup` (as Ruby, reviewed before any implementation), the registry, `Telegram::Channel`, `Talk::Channel`, the kind-name rule, `settings` + `rendering.speech`, `validate!` in `build_descriptor`, `Gateway#serve_loop(on_started:)`, a kind-blind `comms serve`; `KINDS`, `validate_talk!`, `Parties::KINDS[].speaks` leave the core. | Serve-path tests with unchanged assertions (`comms_serve_supervision_test`, `talk_end_to_end_test`, `talk_comms_cli_test`, `talk_gateway_test`, `comms_gateway_test`); new: unknown kind refused; `speech` refused on Telegram; non-loopback talk host without `allow_hosts` refused by `serve`; second run is `:poller_busy` |
| **C2b** Setup half | `Telegram::Setup`, `Talk::Setup` moved from the CLI modules; env slicing; `channel add`/`start`/`doctor`/`service` iterate the registry; the generic CLI checks; the loopback test channel; `telegram_boundary_test`. | `cli_channel_*`, `cli_start_test`, `cli_service_test`, `comms_cli_test` with unchanged assertions; loopback end to end; a spy setup receives only its `env_names` |
| **C3** Grammar, identity, schema | §4.1 and §4.5: `Parties` parser, `stream_id` through descriptor, store contract, gateway, both transports and `Core::RequestIdentity`; command suffix to the Telegram normalizer; decision rule; thread prefix; the migration. | `comms_parties_test`, `comms_admission_test`, `comms_decision_record_test`, `sqlite_comms_store_test`, `comms_seams_test`; migration on a fresh schema; two Telegram surfaces on one bot conflict on the lease; a talk surface cannot hold a Telegram stream's lease; `/help@otherbot` is not a command |
| **C4** Child environments | `gateway_vars:`/`channel_names:`; denylist after the model merge. | §A rows A1–A3 with their mutations |
| **C5** Records | ADR-041 (grammar; `Channel`/`ChannelSetup` seams; closed set in the registry), ADR-062 (child env by declared names; `start --host` gone), ADR-042 (API-origin decision), ADR-014 Relates; READMEs of the three comms gems; `documentation/guides/adding-a-channel.md` (the gem, the registry line, the registration list, the conformance suite, the loopback example). | `rake adr:validate adr:verify`; the guide's steps match the loopback test |

C0 and C1 come first: C0 measures the outcome, C1 pins the transport behavior every later phase must keep.

**Wire and digests.** The descriptor's wire and `definition_digest` change; surfaces are re-added (§6). No pinned
digest covers the surface descriptor (`grep` of `documentation/benchmark` and `test/fixtures` for
`definition_digest`, `expected_bot_id`, `tg.`: no hit, 2026-10-10).

## 6. Moving the live runtime (a runbook, not code)

1. Stop `tamoz service` when no turn is running. (A turn still open when the comms tables are recreated loses its
   route and its answer is dropped — accepted under ADR-059.)
2. Pull, and delete the `channels:` block from `~/.tamoz/config.yaml`. The new config rules refuse old entries
   with a message that says exactly this, so the step cannot be missed.
3. `tamoz channel add telegram` — pairing by message, not `--owner`: the pairing poll confirms every update
   before the pairing message, so the fresh comms tables never see Telegram's unconfirmed backlog.
   `tamoz channel add talk --host …`.
4. `tamoz start` once (the migration runs when the database opens, `adapter.rb:108`), then `tamoz service
   install` — which also replaces today's hand-edited worker plist that gives the worker
   `TAMOZ_TELEGRAM_BOT_TOKEN` (checked 2026-10-10).
5. Rotate the bot token at @BotFather (the worker, which runs the model's tools, has held it) and delete that
   plist's copy in `<runtime>/service-backups/`.

Memory, history in checkpoints and the effect journal are kept; Telegram pairing and the talk link are re-made.

## 7. Owner decisions

| # | Question | Recommendation |
|---|---|---|
| OD-A | Accept ~17 files and a schema change for no user-visible feature | Yes — three tests make the gain permanent and checkable |
| OD-G | `TAMOZ_TELEGRAM_API_ORIGIN` makes the Telegram origin configurable, contradicting `surface_descriptor.rb:15-17` ("a configurable origin is a bot-token exfiltration primitive"); `test/support/telegram_chat_eval.rb` uses it | Remove it; the eval injects a `client_factory:` like every other test. One less way to misdirect the token |
| OD-J | Rotate the Telegram bot token, because the worker plist exposed it to the worker | Yes — whether or not this plan is built |
| OD-K | Reset only the comms tables (keep memory) rather than the whole database | Yes — §4.5 |

Settled by the owner's "no backward compatibility" and no longer questions: thread prefix change, `--once` for
talk, `start --host` removal, `--bootstrap` removal, no upgrade script.

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
FUTURE_PLAN F9; the loopback test channel (§1) already proves such a kind needs only its own code.

## 9. Not in scope

Webhook transports, Telegram voice replies, a real third channel, string message refs, `file` credentials,
`channel list|remove`, third-party adapters, one pairing flow, a terminal channel, context controls on channels —
all in [`FUTURE_PLAN.md`](FUTURE_PLAN.md).
