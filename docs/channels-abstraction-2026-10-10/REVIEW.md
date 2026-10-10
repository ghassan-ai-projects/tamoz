# Channels as one abstraction — plan reviews

Two independent reviewers (fresh subagents, read-only, `docs/subagent-orchestration.md`) read plan revision 1
against the code and ADRs on 2026-10-10, each through one lens. Both verdicts: sound direction, not ready until
the high findings were fixed. Revision 2 resolved them; revision 3 then took the owner's direction that all
channel code, setup included, lives in its adapter gem.

## Lens 1 — architecture and extensibility (0 critical / 4 high / 6 medium / 4 low)

| # | Finding | Resolution |
|---|---|---|
| H1 | The containment allowlist can never be empty: checksummed past migrations, benchmark-protocol code (ADR-058), and `approval_relay.rb:247` name a kind | PLAN §3.7 names them as permanent exemptions with reasons; E1 reworded |
| H2 | `stream_id` also re-keys `Core::RequestIdentity` (`request_identity.rb:18-21`), needs a second migration that cannot carry rows without legacy machinery | `stream_id` deferred (FUTURE F7); C4 renames `expected_bot_id` → `account_id` with identical values, so no key changes |
| H3 | C2 removed `validate_talk!` and opened `kind` before C4 added the registry and `Channel#validate!`: a gap where talk hosts go unchecked and `kind: slack` builds a Telegram transport | Reordered: the registry, `Channel#validate!` and the removal of `KINDS`/`validate_talk!` land in one phase (C2) |
| H4 | `comms_client_factory:` is a Telegram-only test seam used by six test files; no home in the target | `CLI.new(channel_kinds:)` — a test overrides one `ChannelKind` |
| M1 | Inventory gaps (`cli_service_commands.rb:42`, `cli_start_checks.rb`, `cli_comms_ops.rb:325`, …) and one wrong location | §3.3 corrected |
| M2 | `connect` lacked the cursor floor and delivered history; `speech:` and `#kind` were wrong in the shared contract | `connect(descriptor, credential:, floor:, history:, voice:)`; `#kind` dropped |
| M3 | `ConfigRules` (tamoz-agent) cannot see a CLI registry | Shape check in config; closed set enforced at the CLI entry points (A6) |
| M4 | Child env carries more than credential and roles (`TAMOZ_TELEGRAM_API_ORIGIN`, `TAMOZ_TALK_TRACE`, …) | `Setup#gateway_env` per kind |
| M5 | `rendering.speech: true` on Telegram would turn on notices with no voice | `Channel#validate!(descriptor)` validates the whole descriptor (A7) |
| M6 | A `file` credential is readable by the worker (same OS user) | `file` credentials deferred (FUTURE F8) |
| — | Third-channel thought experiment: "two files" did not hold (new-gem registration; integer message refs; Telegram rendering limits; WhatsApp 24-hour window) | §1 now counts the standard new-gem registration; the core leaks are listed in FUTURE F3, not pre-built |
| L | Id grammar (negative ids, split on two colons); `stream_id` prefix; denylist for unconfigured tokens | Grammar stated in §4.1; denylist is a union incl. registry kinds' names |

## Lens 2 — simplicity, safety and delivery risk (0 critical / 3 high / 8 medium / 3 low)

| # | Finding | Resolution |
|---|---|---|
| H1 | The live upgrade (OD-E) could not run: new config rules refuse today's entries; re-adding Telegram could re-pair; a stored descriptor with revision ≥ new is treated as deployed | PLAN §6: a scripted, tested upgrade (rewrite entries in place, bump revision, keep allowlist), preconditions, rollback; bar B8 |
| H2 | C3 (`stream_id`) not needed for the outcome; riskiest data change; duplicate replies if anchors drop | Deferred (FUTURE F7); rename-only C4 keeps every key byte-identical |
| H3 | Containment test patterns are trivially evaded (double quotes, symbols, `%w[]`, env names, `tg.`) and could not finish | Ripper token scan, case-insensitive `telegram|talk|tg|tk`, per-file counts that may only fall |
| — | Outside the plan: the installed `com.tamoz.worker.plist` gives the worker `TAMOZ_TELEGRAM_BOT_TOKEN`, breaching ADR-062 today | Confirmed by reading the plist's variable names (no values); §6 step 4 reinstalls the service; reported to the owner |
| M1 | `file` credentials add a mechanism without isolation | Cut (FUTURE F8) |
| M2 | A2 missed the voice-key ≠ chat-key refusal; generic env drops API origin and trace | A2 mutation added; `Setup#gateway_env`; OD-G for the API origin |
| M3 | Denylist from configured channels is weaker than today's fixed list | Union of every entry's ref and every registry kind's names (A1) |
| M4 | OD-B leaves a paused turn on its old `tg.` thread | §6 precondition: no open work or pending prompt |
| M5 | `connect` missing inputs; listener starts before the lease (`EADDRINUSE` instead of `:poller_busy`) | Inputs added; connection starts after `Gateway#start` (B7) |
| M6 | Conformance suite tested things talk lacks; dedupe is the store's, not the transport's | Suite limited to shared properties; B1 mutation targets cursor/size |
| M7 | Talk's loopback rule enforced only in `start`; `speech` settable on Telegram | Both moved into `Channel#validate!` (A7) |
| M8 | Migration tested only on a fresh schema | Carry test on a version-25 database (B4) |
| L1 | Kind names `os`/`cli` collide with `os_user`/source `cli` | Reserved (A5) |
| L2 | Dropping `transport.mode` and moving the command suffix are churn | Cut |
| L3 | "Cannot be configured" overstated | A6 restated to the CLI entry points |

## Owner direction after the reviews (revision 3)

"Since we have a Telegram gem, should all Telegram code move to it, with interfaces elsewhere that Telegram
implements?" — Yes. Revision 2 had kept a per-kind setup file in the CLI; revision 3 moves the setup half into
the adapter gem behind `Comms::ChannelSetup`, taking and returning plain data so the adapter still depends only
on `tamoz-core` and `tamoz-comms` (ADR-052; A9 boundary test). Two things stay out of the adapters on purpose:
the closed registry (ADR-014 — the composition root decides which adapters exist) and the model checks, which
key on `rendering.speech`, not on a kind, so adapter gems never hold model code.

Revision 3 was reviewed by two fresh reviewers; see below.

## Revision 3 reviews (2026-10-10)

Two fresh reviewers read revision 3 against the code; both verdicts: right direction, not ready until the high
findings were fixed. Revision 4 resolves every high and medium finding.

### Architecture and interfaces (0 critical / 2 high / 6 medium / 7 low)

| # | Finding | Resolution |
|---|---|---|
| H1 | The containment regex `\b(telegram\|talk)\b` misses compound names (`talk_hub`, `CLITalkCommands`, `TAMOZ_TALK_TOKEN`) — `_` is a word character — so rev 2's fix of the same finding did not work | Tokens split on `_`, punctuation and case changes; whole-word parts counted; unit cases prove compound names count |
| H2 | Interface signatures lacked what the moved code reads: `connect` no env (API origin, trace); `add` no env (`--env-file`); `check`/`doctor` no runtime path (talk token file); no workspace root | `env:` (sliced) to every setup method and `connect`; `runtime_path:` where files are read; the workspace check runs in the CLI for every kind |
| M1 | `poller_ok?` needs the store; `--bootstrap` is Telegram-only | CLI passes `poller_free:`; `--bootstrap` deleted (OD-H) |
| M2 | "Connection after the lease" needs a gateway change (`serve_loop` calls `start` itself) | `Gateway#serve_loop(on_started:)`, named in C2 and bar 1.1 |
| M3 | `ChildEnvironments` (tamoz-agent) cannot see the registry; `TAMOZ_TELEGRAM_SURFACE` is read nowhere | Explicit `gateway_vars:`/`channel_names:`; the variable deleted |
| M4 | C2 removed `KINDS` but the kind-name rule arrived in C3 | Rule and reserved names moved into C2 |
| M5 | Registry returned constants; tests need instances over a fixture client; `validate!` call site unnamed | `ChannelKind#channel/#setup(client_factory:)` build instances; `validate!` called once, in `build_descriptor` |
| M6 | §8's evidence was wrong: channels get no context controls in production (`comms_controls_source` is `nil`) and the parity test never touches the CLI | §8 corrected; the conclusion (CLI is not a channel) holds; the real gap is FUTURE F10 |
| L | Per-kind wording left in the CLI; merge preflight into doctor; transcription keyed on speech; one boundary assertion changes; inventory errors; one transport on two threads; upgrade step 3 served live traffic | `summary` and `ConnectionError` messages; one `check` method; F2 note; assertion change named; §3.3 fixed; thread safety stated; step removed |
| — | Third-channel leaks remaining: integer `account_id`, `bot_username`, `transport.mode` | Listed in FUTURE F3 |

### Safety, simplicity and delivery (0 critical / 3 high / 5 medium / 3 low)

| # | Finding | Resolution |
|---|---|---|
| H1 | `gateway_env` saw the whole environment (chat key, other tokens, `TAMOZ_ENV_FILE`); a `credential_ref` naming the chat key would reach a gateway (ADR-062) | One `env_names` per kind; every setup method gets only that slice; `ChildEnvironments` refuses foreign keys; `validate!` refuses a ref outside `env_names`; bar A2, A2b, A2c with mutations |
| H2 | Same containment regex defect; `≤` counts let a regression hide in slack | Exact per-file counts; drops written into the table |
| H3 | The upgrade left old descriptor rows (disabled/removed surfaces) that `comms list`/`pair`/`doctor` cannot parse; step 3 (`serve --once`) polled Telegram live with no worker | Script redeploys every stored surface and removes unconfigured rows; serving step removed (migration runs on open); B8 fixture includes a disabled surface |
| M1 | No store interface can check the quiet precondition; prompts bound to the old revision go dead | One new `CommsStore` method (OD-I, cross-gem change for the owner); the script refuses when anything is open or a lease is live |
| M2 | Moving setup dropped the inside-workspace refusal and `--env-file` permission check | Both stay in the CLI, for every kind (A10) |
| M3 | A1's mutation did not discriminate; denylist applied before model keys were merged | Fixture names disabled and registry-only tokens; denylist after the merge |
| M4 | The breached plist survives in `service-backups/`; the worker held the bot token | Delete the backup; rotate the token (OD-J) |
| M5 | Whole-file exemptions hide new mentions (C3's own migration goes into `migrator.rb`) | Frozen counts instead of exemptions (§3.7) |
| L | `TAMOZ_TELEGRAM_SURFACE` unused; talk doctor needs poller state; one-shot script should be deleted | Deleted; `poller_free:`; deleted after use (E4) |

Both reviewers agreed with PLAN §8: the CLI should not become a channel.

## Owner direction after the revision 3 reviews (revision 5)

"I want it to be 10/10; we do not need a migration since there is no backward compatibility yet." Revision 5:

- **No upgrade path.** The upgrade script, its tests, the open-work store method (old OD-I), the quiet precondition
  and every row-carrying test are gone. One new migration ordinal (required: ordinals are monotonic and
  checksummed) recreates the comms tables empty; memory, checkpoints and the effect journal share the database
  file and are kept (OD-K). The live runtime moves by a five-step runbook (PLAN §6).
- **The right identity, now that nothing is carried.** The numeric `account_id` compromise is replaced by
  `stream_id: "<kind>:…"` (rev 1's design, deferred in rev 2 only because of row carrying). `bot_username` and the
  `/cmd@bot` rule move into Telegram; `transport.mode` is dropped.
- **Proof beyond names**, answering the rating's weaknesses: a dependency test (names can be renamed away;
  requires cannot), and a test-only loopback channel that is the third example the interfaces are checked against.
- **Every interface method has a named caller**; default bodies keep Telegram's setup small.
- **Fewer owner decisions**: thread prefix, `--once`, `start --host`, `--bootstrap` and the upgrade are settled by
  "no backward compatibility". OD-G now recommends removing the configurable Telegram origin.
