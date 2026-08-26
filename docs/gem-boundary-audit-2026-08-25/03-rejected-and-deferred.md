# Rejected and deferred splits

The following areas were inspected because their size, fan-in, or naming makes
them look extractable. They fail the audit bar for a new gem today.

| Area | Decision | Why it fails the boundary bar |
|---|---|---|
| `tamoz-core` JCS/digest/deep-freeze | Keep in core | These are canonical shared contracts with high fan-in (`Core` 193 dependents, `Core.digest` 55, `deep_freeze` 32). Splitting them would add a dependency layer to the foundation and multiply digest/codec ownership risk. Narrower APIs may be a later internal refactor, not a new gem. |
| `tamoz-core` durable circuit engine | Keep in core | `circuit.rb`, `record.rb`, `evidence.rb`, and `registry.rb` are explicitly the one DR-2 engine. SQLite's `CircuitStore` is its storage adapter. A new circuit gem would separate the invariant-bearing record from the foundation without reducing a consumer's footprint. |
| Individual `tamoz-sqlite` stores | Keep together | Checkpoints, inbox, effects, leases, schedules, comms, memory and circuit share `Adapter`, `DatabaseKernel`, `Migrator`, wire codecs and transaction boundaries. Splitting them would obscure atomic operations and multiply migration/package coordination. |
| `tamoz-sqlite` comms or schedule adapter | Keep in SQLite | The contracts live in `tamoz-comms`/`tamoz-scheduler`; SQLite intentionally implements them without reverse dependencies. This is an established contract/adapter boundary, not a missing gem. |
| `tamoz-agent` worker/runtime | Defer | `Worker`, `WorkerRuntime`, `RuntimeDirectory`, child environments and durable recorder compose SQLite, comms, approval, profiles, sessions, capabilities and scheduling. A worker gem may become sensible after the provider adapter is removed, but today it is an application composition root, not a low-coupling leaf. |
| `tamoz-agent` runtime vs one-shot path | Keep together for now | `Runtime` and its step/plan helpers share the kernel/session/tool contracts and public construction path. A split would be a runtime API redesign, not an independent external adapter. |
| `tamoz-agent-cli` command groups | Keep together | Worker, session, profile, schedule and comms commands share argv parsing, authority, rendering, runtime-directory resolution and signal/process lifecycle. Moving each group into domain gems would make contract gems depend upward on the application shell. |
| `tamoz-agent-capabilities` sources | Keep catalog together; spike MCP bridge | The sealed catalog and source protocol stay together, but the MCP-dependent builder/source cluster is a credible optional bridge. It needs a tighter public-constant and composition map before implementation. |
| `tamoz-agent-session` subtrees | Keep together | Session lifecycle, routing, effects, memory, evidence and graph nodes form one durable state machine with ordering and digest contracts. File size is a refactor signal, not evidence for another gem. |
| `tamoz-agent-memory` / healing / profile / improvement | Keep as focused gems | These are the successful prior decomposition: cohesive verticals with one-way dependencies and explicit contracts. Further splitting would create smaller packages without an independent consumer or load payoff. |
| `tamoz-tools` Skills | Defer | See [02-candidate-assessments.md](02-candidate-assessments.md#deferred-tamoz-tools-skills). A child gem that remains eagerly loaded is packaging theatre. |
| `tamoz-graph` compiler/executor/checkpointer | Keep together | The compiler, deterministic execution, checkpoint reconstruction, durable requests, replay and stream emission are one runtime. Splitting them would separate mutually recursive graph invariants and leave every consumer depending on both halves. |
| `tamoz-stream` gRPC worker/reverse channel | Keep together; investigate SSE optionalization | The EpisodeWorker, typed Decision builder, evidence/outcome/approval reverse channel, notification contract and generated protobufs share one protocol/runtime. SSE is independently shaped, but no production consumer is visible in-tree, so do not move it until deployment evidence exists. SQLite should first narrow its stream requires to the contracts it actually uses. |
| `tamoz-comms` gateway/rendering/store contract | Keep contracts; conditional gateway package | Values, admission, identity, rendering, transport and structural store contracts define one channel boundary. Gateway/drainer are a separate edge-process seam, but the undeclared Telegram error rescue must be removed before packaging it. |
| `tamoz-observability` signal plane | Keep together | Catalog, correlation, bounded recorders, metrics, traces and content policy are one closed signal contract. OTLP/HTTP is already isolated in `tamoz-otel`. |
| `tamoz-approval` policy engine | Keep together | Policy documents, evaluator, grants, decision log and engine are one authority boundary. Splitting policy parsing from evaluation would risk policy-as-data drift and does not reduce external dependencies. |
| `tamoz-evals` canonical JSON/deep-freeze helpers | No new gem; separate duplication review | The evals implementations appear to overlap `tamoz-core` semantics. That is a correctness/duplication question, not a package boundary. Resolve byte-compatibility and ownership before proposing a codec gem. |
| `tamoz-agent-ruby-llm` | Defer | The adapter is technically movable, but provider credential vocabulary, worker factories, CLI construction, evals, and public API consumers are coupled today. Do not split it until that composition is made explicit. |
| `tamoz-scheduler` scorecard consumer | Move into eval runner, not a new scheduler dependency | `ScorecardSummaryConsumer` and `ScorecardResult` execute eval-specific work. Keep scheduler independent by moving that code to the runner or injecting a consumer protocol; never add `tamoz-scheduler -> tamoz-evals`. |

## False positives from the architecture tool

Enola's 0.40-confidence “41-module mutual-reference cluster” includes the
shared `Tamoz`/`Tamoz::Agent` namespace and eager/autoloaded references across
the focused agent gems. It is a coupling-density signal, not evidence of a
dependency cycle. The receipt reports all 51 insights as heuristic, and the
source review did not promote this cluster into a blanket “split the agent”
recommendation.

The same caution applies to high fan-in symbols. `Tamoz::Core`, `Core.digest`,
`SQLite::Adapter`, and `Agent::Deliberation` are high-risk shared points, but
high fan-in is correct for canonical contracts and composition seams. The
question is whether a narrower contract can be extracted without creating a
new owner or changing byte/event/transaction semantics; none met that bar in
this scan beyond the four accepted candidates.

## Blind spots

- This is a static source and package audit. It does not measure boot time,
  memory, gem install size, release cadence, or runtime call frequency.
- The worktree is dirty with unrelated/concurrent edits. Enola therefore
  describes the current working tree, not a clean historical revision.
- A production consumer outside this repository could use `SseTransport`,
  `RubyLLMModel`, or any public constant. The report treats current in-tree
  source as the consumer inventory and flags public API risk rather than
  claiming external usage is impossible.
- The current public architecture page is stale. The inventory uses the source
  tree and gemspecs as authority, not that page's old 17-gem count.
- No tests were run, so this report does not claim behavioural preservation or
  prove that any proposed extraction is implementation-ready.
