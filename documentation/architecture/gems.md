# Gem map

Tamoz is a monorepo of seventeen independently publishable gems, all at `0.1.0.alpha.1` (pre-release), MIT-licensed, and pinned to `required_ruby_version >= 3.3 < 5.0`. This page maps each gem's responsibility, its runtime dependencies, and the bottom-up dependency chain.

## The dependency chain

Dependencies run one way, bottom-up: everything eventually rests on `tamoz-core`, and nothing may reach down into `tamoz-evals`.

```mermaid
flowchart BT
    CORE["tamoz-core<br/>values · context · secrets · JCS · DR-2 circuit"]

    CAN["tamoz-cancellation<br/>token · trap · process group"]
    CON["tamoz-concurrency<br/>pool · stream sink · event stream · drain"]
    G["tamoz-graph<br/>BSP engine · interrupts · replay"]
    SCH["tamoz-scheduler<br/>schedule values + store contract"]
    STR["tamoz-stream<br/>EpisodeWorker (gRPC)"]
    T["tamoz-tools<br/>toolbox · skills compiler · capability host"]
    M["tamoz-mcp<br/>governed MCP + websearch"]
    C["tamoz-comms<br/>channel contract"]
    O["tamoz-observability<br/>signal catalog · journal"]

    SQL["tamoz-sqlite<br/>SQLite persistence"]
    OTEL["tamoz-otel<br/>OTLP/HTTP exporter"]
    TG["tamoz-telegram<br/>Telegram transport"]

    AK["tamoz-agent-kernel<br/>deliberation substrate"]
    ACAP["tamoz-agent-capabilities<br/>sealed capability catalog"]
    ASESS["tamoz-agent-session<br/>the durable deliberation session"]
    AGENT["tamoz-agent<br/>agent runtime + tamoz CLI"]

    EVALS["tamoz-evals<br/>evaluation · release evidence"]

    G --> CORE
    SCH --> CORE
    STR --> CORE
    STR --> CAN
    T --> CORE
    M --> CORE
    M --> CAN
    C --> CORE
    O --> CORE

    CAN --> CORE
    CON --> CAN

    SQL --> G
    SQL --> SCH
    SQL --> STR
    OTEL --> O
    OTEL --> CON
    TG --> C

    AK --> T
    ACAP --> AK
    ASESS --> AK
    ASESS --> ACAP
    AGENT --> AK
    AGENT --> ACAP
    AGENT --> ASESS
    AGENT --> G
    AGENT --> SQL
    AGENT --> C
    AGENT --> O
    AGENT --> CON

    EVALS -. none .- AGENT
```

Two edges deserve emphasis:

- **`tamoz-agent` is the only layer that knows RubyLLM** (`ruby_llm ~> 1.16.0`). It accepts a `RubyLLM::Agent`, `RubyLLM::Chat`, or a callable that produces a chat, and reuses their public messages and tools.
- **Nothing depends on `tamoz-evals`.** It is a development/release gem that depends on the runtime gems it exercises (`tamoz-core`, `tamoz-agent`, `tamoz-sqlite`, `tamoz-mcp`, `tamoz-graph`, `tamoz-scheduler`); the one-way rule is the inverse edge — no production gem depends on it — enforced by `test/dependency_isolation_test.rb`. Evaluation code can never reach a production path.

## The gem-by-gem map

| Gem | Responsibility | Runtime dependencies |
|---|---|---|
| `tamoz-core` | Shared values, context, secrets, canonical/JCS digesting, the worker pool, and the DR-2 durable-circuit engine | stdlib, Zeitwerk |
| `tamoz-graph` | Deterministic checkpointed graph runtime: BSP super-steps, interrupts, replay, subgraphs, durable-runner contracts. Never loads an LLM client (invariant 11) | `tamoz-core` |
| `tamoz-scheduler` | Durable scheduling values and the `ScheduleStore` contract (the SQLite implementation lives in `tamoz-sqlite`). Never executes work itself | `tamoz-core` |
| `tamoz-stream` | The supervised gRPC `EpisodeWorker`: containment host, snapshot verification, typed Decision builder, reverse channel for evidence/outcomes/approvals, artifact manifest. One sealed, digest-verified Situation snapshot per episode (the old streaming-input engine was retired by `MIGRATION_13`) | `tamoz-core`, `grpc ~> 1.83`, `google-protobuf ~> 4.35` |
| `tamoz-sqlite` | SQLite persistence: checkpoints, request inbox, effect journal, leases, schedules, comms, circuit, memory index, backup/restore. Migrator `CURRENT_VERSION = 13` | `tamoz-graph`, `tamoz-scheduler`, `tamoz-stream`, `sqlite3 ~> 2.9` |
| `tamoz-tools` | Workspace toolbox, the skills compiler, and the sealed capability host | `tamoz-core` |
| `tamoz-mcp` | Governed MCP client/host over the official Ruby SDK, plus governed websearch (an MCP server with the reserved id `websearch`) | `tamoz-core`, `mcp ~> 1.1` |
| `tamoz-comms` | Channel contract gem: values, identity/admission policy, rendering, the `Transport` seam, and the structural `CommsStore` contract. Never opens a socket | `tamoz-core` |
| `tamoz-observability` | Closed versioned signal catalog, correlation identity, immutable signals, bounded recorders, local journal, content/secret policy, metrics and trace projection. `SCHEMA_VERSION = 1` | `tamoz-core` |
| `tamoz-otel` | Bounded OTLP/HTTP exporter for observability signals | `tamoz-observability` |
| `tamoz-telegram` | Telegram Bot API transport implementing the `Tamoz::Comms::Transport` seam; stdlib-only HTTP | `tamoz-comms` |
| `tamoz-agent-kernel` | The deliberation substrate: episode records/receipts, reasoning documents, the plan/review/execute/verify engine, `EffectDispatcher`, witness gateway/verifier, catalogs, the agent error taxonomy, and the provider/env-key catalog | `tamoz-core`, `tamoz-tools` |
| `tamoz-agent-memory` | Durable memory: `Memory::Engine` assembling admission, retrieval, lifecycle (deletion with receipts), consolidation into wisdom, behavior transitions | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-sqlite`, `tamoz-tools` |
| `tamoz-agent-healing` | Bounded self-healing: typed failure contract, classification with abstention, immutable digest-bound rules, reviewed remediation protocol, promotion gate | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-tools` |
| `tamoz-agent-profile` | Trusted profiles: document/authority/egress/check-spec validators, secure files, adoption and transition registries | `tamoz-agent-kernel`, `tamoz-core` |
| `tamoz-agent-improvement` | Bounded self-improvement: candidate provenance, heuristic generator, paired evaluation reports, human-gated promotion/rollback | `tamoz-agent-kernel`, `tamoz-agent-memory` |
| `tamoz-agent-cli` | The `tamoz` executable: worker/schedule/profile/session/comms command groups over the runtime; the family's only executable | `tamoz-agent` |
| `tamoz-agent` | The deliberative agent runtime as a library: session state machine over the graph, worker/durable execution, capability and model wiring (`RubyLLMModel`) | `tamoz-agent-kernel`, `tamoz-agent-memory`, `tamoz-agent-healing`, `tamoz-agent-profile`, `tamoz-agent-improvement`, `tamoz-tools`, `tamoz-graph`, `tamoz-sqlite`, `tamoz-comms`, `tamoz-approval`, `tamoz-observability`, `ruby_llm ~> 1.16.0` |
| `tamoz-evals` | Evaluation and release evidence: conformance suites, scorecards, release gates. Development/release gem; nothing depends on it | `tamoz-core`, `tamoz-agent`, `tamoz-sqlite`, `tamoz-mcp`, `tamoz-graph`, `tamoz-scheduler` |

## Dependency rules that are enforced, not suggested

- `tamoz-core` has no runtime dependency beyond the standard library and Zeitwerk.
- `tamoz-graph` never references RubyLLM, an HTTP client, a provider SDK, or an adapter — a clean process requiring `tamoz/graph` loads none of them and opens no socket.
- Adapters implement published contracts and depend on contracts, never on runner internals.
- Optional dependencies load only when their feature is selected. Fiber execution, OTLP export, and Telegram transport must not affect a minimal boot.
- No mutable process-global runtime state: boot-time registries freeze after configuration; per-run state travels through `Context`; per-thread durable state travels through the checkpointer.
- Optional persistence protocols (schedule, stream, comms) are structural and versioned: the feature gem owns the contract documentation; `tamoz-sqlite` implements it without a reverse runtime dependency.

## Next reads

- [overview.md](overview.md) — the layered stack these gems form
- [../overview/compatibility.md](../overview/compatibility.md) — versions and supported surfaces
- [data-model.md](data-model.md) — what `tamoz-sqlite` persists
- [../getting-started/install.md](../getting-started/install.md) — installing the gems
