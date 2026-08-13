# Tamoz

Tamoz is a Ruby-native durable agent framework for checkpointed, interruptible,
observable, and evaluation-governed AI workflows.

An agent turn is a graph run over a SQLite-backed checkpoint store. It survives
`kill -9`, resumes from its last committed barrier, and reconciles an
interrupted side effect from proven state rather than guessing. Nothing acts
without a reviewed plan bound to its digest, and nothing changes a file without
an approval you granted.

**This is pre-release software** (`0.1.0.alpha.1`). Read
[`documentation/limitations.md`](documentation/limitations.md) before building
on it — it lists, with evidence, what Tamoz does not do.

## The thirteen gems

| Package | Responsibility | Runtime dependencies |
|---|---|---|
| `tamoz-core` | Shared values, context, secrets, canonical digests, worker pool, the durable-circuit engine | stdlib, Zeitwerk |
| `tamoz-graph` | Deterministic checkpointed graph execution and durability contracts | `tamoz-core` |
| `tamoz-scheduler` | Schedule and occurrence values, the store contract (never executes work) | `tamoz-core` |
| `tamoz-stream` | The supervised gRPC episode worker and the Situation boundary | `tamoz-core`, gRPC, protobuf |
| `tamoz-sqlite` | The durable adapter: checkpoints, request inbox, effect journal, leases, schedules, comms | `tamoz-graph`, `tamoz-scheduler`, `tamoz-stream`, `sqlite3` |
| `tamoz-tools` | The workspace toolbox, the skills compiler, the capability host | `tamoz-core` |
| `tamoz-mcp` | Governed MCP client/host and governed websearch | `tamoz-core`, the official MCP SDK |
| `tamoz-comms` | Channel values, admission policy, rendering, transport seam, store contract | `tamoz-core` |
| `tamoz-telegram` | Telegram Bot API transport adapter | `tamoz-comms` |
| `tamoz-observability` | Closed signal catalog, correlation, bounded recorders, metrics and trace projection | `tamoz-core` |
| `tamoz-otel` | Optional governed OTLP/HTTP exporter | `tamoz-observability` |
| `tamoz-agent` | The deliberative agent runtime and the `tamoz` CLI | `tamoz-tools`, `tamoz-graph`, `tamoz-sqlite`, `tamoz-comms`, `tamoz-observability`, RubyLLM |
| `tamoz-evals` | Conformance, artifact verification, release evidence | stdlib only |

Each gem installs and runs with only its declared dependencies, proven per gem
by an isolated install into its own `GEM_HOME`. `tamoz-evals` is a non-runtime
gem: no production gemspec may depend on it.

Tamoz Agent is the reference application under `apps/tamoz-agent`.

## What works today

- **Reviewed change loop.** Discovery reads, then a separately reviewed action
  plan, an exact diff shown before approval, a digest-bound atomic patch, and a
  configured verification command. A failed check becomes evidence for up to two
  newly reviewed repairs with fresh approvals; a repeated action or a repeated
  failure stops safely rather than looping.
- **Durable multi-turn sessions.** `ask`, `resume`, `continue`, `follow-up`,
  `redirect`, `cancel`, `show`, `list`, `resolve`. A killed process resumes; an
  ambiguous effect stops as `:unknown` and waits for a human decision.
- **Trusted project profiles.** Project authority lives outside the repository
  being worked on. A file in an untrusted checkout can suggest configuration; it
  never becomes executable authority without an explicit import and preview.
- **One sealed capability host.** Local tools, skills, MCP servers and websearch
  register as four built-in sources at session construction and are then sealed.
  The authority intersection is computed once from policy; content never grants.
- **Evaluated skills, governed MCP, three-layer memory, bounded self-healing,
  durable scheduling, and the supervised episode worker** (gRPC EpisodeWorker
  for the stream runtime, with evidence pull, the learning loop, and approval
  relay on the reverse channel).

## Quick start

```bash
export OPENAI_API_KEY="..." && export TAMOZ_MODEL="gpt-5-mini"
```

```bash
rbenv exec bundle exec tamoz --root . "Explain the persistence boundary"
```

```bash
rbenv exec bundle exec tamoz --root . --allow-changes --check 'test=rbenv exec bundle exec rake test' "Fix the failing test"
```

Read-only is the default. See
[`documentation/getting-started/install.md`](documentation/getting-started/install.md)
for requirements, durable sessions, profiles and the full subcommand surface.
For a copy-paste agent/operator runbook covering MCP and governed websearch, see
[`documentation/guides/agent-operator.md`](documentation/guides/agent-operator.md),
and see [`documentation/operations/operations.md`](documentation/operations/operations.md)
for backup, restore and crash recovery.

## Documentation

The full documentation set is under
[`documentation/`](documentation/README.md), organized by topic and reachable
from its index:

- **Start here** — [product](documentation/overview/product.md),
  [concepts](documentation/overview/concepts.md),
  [quickstart](documentation/getting-started/quickstart.md)
- **Architecture** — [overview](documentation/architecture/overview.md),
  [gem map](documentation/architecture/gems.md),
  [data model](documentation/architecture/data-model.md),
  [security model](documentation/architecture/security-model.md),
  [invariants](documentation/architecture/invariants.md)
- **Design** — [the design docs](documentation/design/README.md),
  [decisions/ADRs](documentation/adr/README.md)
- **Guides** — [operator runbook](documentation/guides/agent-operator.md),
  [Telegram](documentation/guides/telegram.md),
  [evaluation](documentation/guides/evaluation.md)
- **Operations** — [runbook](documentation/operations/operations.md),
  [observability](documentation/operations/observability-ops.md)
- **Reference** — [CLI](documentation/reference/cli.md),
  [configuration](documentation/reference/config.md),
  [public API](documentation/reference/public-api.md)

## Talking to it over Telegram

A channel is a **user surface**, not a capability the model can call. The bot
answers people the operator put on an allowlist and nobody else; the gateway
holds the bot token and never constructs a session or opens a workspace file.

Create a bot with [@BotFather](https://t.me/botfather), then authenticate it.
Bootstrap prints the bot's numeric id and deliberately does not persist it —
you copy it into config yourself, so the surface is pinned to a bot you chose:

```bash
export TAMOZ_TELEGRAM_BOT_TOKEN='<token from BotFather>'
```

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms doctor --bootstrap --credential-ref TAMOZ_TELEGRAM_BOT_TOKEN
```

You also need the numeric Telegram id of everyone allowed to talk to it. Send
the bot a message, then read the pending update:

```bash
rbenv exec bundle exec ruby -rtamoz/telegram -e 'puts Tamoz::Telegram::Client.new(ENV.fetch("TAMOZ_TELEGRAM_BOT_TOKEN")).call("getUpdates", {"offset" => -1}, idempotent: true).inspect'
```

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

### Keeping it open

Two ordinary foreground processes, in two terminals. Neither is a daemon and
neither writes a PID file, so launchd, systemd, Docker or runit supervise them
the way they supervise anything else. The **gateway** long-polls Telegram,
admits messages and sends answers. It runs silently until it exits:

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
timeout above that. A second gateway for the same bot refuses to poll rather
than double-reading the update stream, and if a competitor holds the stream
from elsewhere, Telegram's `409` is reported as a named poller conflict. A long poll that times out or loses its connection is the normal
weather of long polling: it observed nothing, so the durable offset does not
move and the next pass retries it. Restarting either process is safe at any
point — a message already admitted is not re-admitted, and a terminal answer is
durable before the occurrence closes, so it survives a gateway that dies before
sending it.

Since the running gateway prints nothing, ask a separate shell what a surface is
doing — poll offset, bindings, conversation-to-thread map and outbox state:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz comms list
```

Add `--once` to either command to do a single pass and exit, which is what you
want from cron or a test; `comms serve --once --json` reports each surface's
outcome for deterministic supervision.

Revoking a correspondent, resolving an `:unknown` delivery, and the deny-only
approval flow are in
[`documentation/operations/operations.md`](documentation/operations/operations.md).
The full walkthrough is in
[`documentation/guides/telegram.md`](documentation/guides/telegram.md).

## Evidence

Release status is machine-readable, not a claim in prose.
[`docs/requirements-manifest.json`](docs/requirements-manifest.json) is generated
from the invariants, the ADRs, the phase exit criteria, the public API, the CLI
surface and the migrations; [`docs/REQUIREMENTS_AUDIT.md`](docs/REQUIREMENTS_AUDIT.md)
is regenerated by RUNNING each named test, so a row is `pass` only because its
test executed and passed.

```bash
rbenv exec bundle exec rake ci
```

```bash
rbenv exec bundle exec tamoz-eval scorecard agent-smoke
```

The scorecard runs a fixed deterministic corpus and reports task success,
verified completion, plan and repair attempts, approvals, call and byte proxies,
unnecessary mutation and repeated-action stops, with hard-zero gates on unsafe
actions, false-positive completions and incomplete evidence. See
[`documentation/guides/evaluation.md`](documentation/guides/evaluation.md).

[`docs/RELEASE_REHEARSAL.md`](docs/RELEASE_REHEARSAL.md) records a clean-clone
rehearsal on a pinned toolchain outside the development checkout.

The authoritative design is committed under
[`docs/design-v0.1/`](docs/design-v0.1/) — the working archive, including plans,
reviews and audits, is mapped in [`docs/README.md`](docs/README.md); the build
order and active phase are in
[`docs/PRODUCT_EXECUTION_ROADMAP.md`](docs/PRODUCT_EXECUTION_ROADMAP.md).

## Security and guarantees

Tamoz makes no exactly-once claim for arbitrary external effects. Replay-safe
effects require idempotency, atomic participation, or reconciliation; ambiguous
work stops rather than repeating. See [`SECURITY.md`](SECURITY.md) and
[`documentation/architecture/security-model.md`](documentation/architecture/security-model.md)
for the complete boundary.

## Status

`0.1.0.alpha.1` — pre-release. The project is usable today and every claim about
it is backed by executed evidence, but the public contract is still hardening;
breaking changes are announced in [`CHANGELOG.md`](CHANGELOG.md). What is not
implemented, what carries weaker evidence, and what has never had an independent
adversarial review are listed in
[`documentation/limitations.md`](documentation/limitations.md).

## License

MIT. See [`LICENSE`](LICENSE).
