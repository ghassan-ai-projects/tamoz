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

## The gems

| Package | Responsibility | Runtime dependencies |
|---|---|---|
| `tamoz-core` | Shared values, context, secrets, canonical digests, the durable-circuit engine, legacy sentinels | stdlib, Zeitwerk |
| `tamoz-cancellation` | The cancellation token plus OS-signal traps, process-group primitives, interruptible sleep | `tamoz-core` |
| `tamoz-concurrency` | Bounded pools, stream sink, event stream, the shared-budget drain base class | `tamoz-cancellation`, `tamoz-core` |
| `tamoz-graph` | Deterministic checkpointed graph execution and durability contracts | `tamoz-cancellation`, `tamoz-concurrency`, `tamoz-core`, Zeitwerk |
| `tamoz-scheduler` | Schedule and occurrence values, the store contract (never executes work) | `tamoz-core` |
| `tamoz-stream` | The supervised gRPC episode worker and the Situation boundary | `tamoz-core`, gRPC, protobuf |
| `tamoz-sqlite` | The durable adapter: checkpoints, request inbox, effect journal, leases, schedules, comms | `tamoz-graph`, `tamoz-scheduler`, `tamoz-stream`, `tamoz-approval`, `sqlite3` |
| `tamoz-tools` | The workspace toolbox, the skills compiler, the capability host | `tamoz-core` |
| `tamoz-context-engine` | Context-window management for agent loops: frozen request header, append-only surface, spill, pruner, compaction, cache accounting | `tamoz-core` |
| `tamoz-harness` | The coding-harness protocol: prompt pack, persona and preferences, project guidance, living plan, tool-call parsing, loop budgets, finish contract | `tamoz-context-engine`, `tamoz-core` |
| `tamoz-mcp` | Governed MCP client/host | `tamoz-core`, `tamoz-cancellation`, the official MCP SDK |
| `tamoz-mcp-websearch` | Governed operator-side websearch egress adapter | `tamoz-mcp`, `tamoz-core` |
| `tamoz-comms` | Channel values, admission policy, rendering, transport seam, store contract | `tamoz-core` |
| `tamoz-comms-gateway` | Long-running gateway and delivery drainer over injected Comms transport/store seams | `tamoz-comms`, `tamoz-core` |
| `tamoz-approval` | Policy-as-data approval engine: digest-pinned YAML documents, ask/park/deny ladder, scoped grants, durable decision log | `tamoz-core` |
| `tamoz-telegram` | Telegram Bot API transport adapter | `tamoz-comms` |
| `tamoz-observability` | Closed signal catalog, correlation, bounded recorders, metrics and trace projection | `tamoz-core` |
| `tamoz-otel` | Optional governed OTLP/HTTP exporter | `tamoz-observability` |
| `tamoz-agent-kernel` | The deliberation substrate: episode records and receipts, the plan/review/execute/verify engine, the effect seam, catalogs, error taxonomy, request routes and projections | `tamoz-core`, `tamoz-tools` |
| `tamoz-agent-capabilities` | The sealed capability catalog: bindings over toolbox/skills/MCP/browser/database sources, child-task dispatch | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-mcp`, `tamoz-tools` |
| `tamoz-agent-memory` | Durable memory: `Memory::Engine` — admission, retrieval, lifecycle with deletion receipts, consolidation into wisdom, behavior transitions | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-sqlite`, `tamoz-tools` |
| `tamoz-agent-healing` | Bounded self-healing: typed failure model, classification with abstention, immutable rules, reviewed remediation protocol | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-tools` |
| `tamoz-agent-profile` | Trusted profiles: document/authority/egress/check-spec validation, secure files, adoption/transition registries | `tamoz-agent-kernel`, `tamoz-core` |
| `tamoz-agent-session` | The durable deliberation session: versioned records, planning context, graph nodes, effects, routing, adaptive machinery | `tamoz-agent-kernel`, `tamoz-agent-capabilities`, `tamoz-agent-memory`, `tamoz-agent-profile`, `tamoz-agent-healing`, `tamoz-cancellation`, `tamoz-core`, `tamoz-graph`, `tamoz-tools` |
| `tamoz-agent-improvement` | Bounded self-improvement: candidate provenance, heuristic generator, paired evaluation reports, human-gated promotion/rollback | `tamoz-agent-kernel`, `tamoz-agent-memory` |
| `tamoz-agent-cli` | The `tamoz` executable: worker/schedule/profile/session/comms command groups over the runtime | `tamoz-agent`, `tamoz-comms-gateway` |
| `tamoz-agent` | The deliberative agent runtime (library): worker and durable execution, capability/model wiring, the bundled approval default | `tamoz-agent-session`, `tamoz-agent-improvement`, `tamoz-agent-healing`, `tamoz-agent-profile`, `tamoz-agent-capabilities`, `tamoz-agent-kernel`, `tamoz-cancellation`, `tamoz-concurrency`, `tamoz-tools`, `tamoz-graph`, `tamoz-sqlite`, `tamoz-comms`, `tamoz-approval`, `tamoz-observability` |
| `tamoz-evals` | Artifact schemas, canonical digests, verification and release evidence | `tamoz-core` (development/release only) |
| `tamoz-evals-runner` | Evaluation harnesses, scorecards, treatments and benchmarks with explicit external inputs | `tamoz-evals`, runtime gems used by the selected runner |

Each gem installs and runs with only its declared dependencies, proven per gem
by an isolated install into its own `GEM_HOME`. `tamoz-evals` verifies evidence;
`tamoz-evals-runner` owns executable evaluation runtime and receives its
corpora, scripted inputs, and benchmark adapters from explicit external inputs.
No production gemspec may depend on either evaluation gem.

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
Approvals over the channel are deny-only and evidence-gated (ADR-049).

The full walkthrough — creating the bot, authenticating it, collecting the
allowlist, configuring the surface, and running the gateway and worker — is in
[`documentation/guides/telegram.md`](documentation/guides/telegram.md). The
approval and recovery operations are in
[`documentation/operations/operations.md`](documentation/operations/operations.md).
Both long-running processes exit cleanly on `SIGINT`/`SIGTERM` and restart
safely at any point; add `--once` to either for a single supervised pass.

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
rbenv exec bundle exec tamoz-eval-runner scorecard agent-smoke --input-manifest PATH
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
