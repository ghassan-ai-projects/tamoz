# Existing-usage and contract-boundary audit

Date: 2026-08-20

Focus: whether the repository uses its existing APIs, contracts, effects, stores,
codecs, policies, lifecycle helpers, and public gem boundaries correctly.

Scope: all 13 production gems under `gems/`, all Ruby code under `script/` and
`test/`, the `scripts/` launcher, `apps/` and `bin/`, and the relevant gemspec,
Gemfile, Rakefile, quality, design, and boundary documents. This is a read-only
audit. No production code or tests were changed.

## Executive summary

The dominant architecture is coherent: durable session model/tool/MCP work is
routed through `SessionEffects` and `EffectDispatcher`; MCP capability policy is
caller-owned; communication delivery uses the durable outbox; stream code uses
injected ports and does not depend on `tamoz-agent`; and SQLite owns durable
implementations rather than leaking them into the contract gems.

I confirmed four issues and two review candidates:

| ID | Classification | Severity | Confidence | Short description |
|---|---|---:|---:|---|
| EU-001 | Confirmed defect | P2 | High | MCP source preflight omits methods that the session later calls. |
| EU-002 | Confirmed defect | P2 | High | `ScheduleStore` contract, SQLite adapter, and clients have drifted apart. |
| EU-003 | Confirmed defect | P1 | High | A known MCP ambiguous outcome escapes the journal completion path. |
| EU-004 | Confirmed boundary inconsistency | P2 | High | `tamoz-evals` eagerly loads runtime packages despite its stdlib-only boundary. |
| EU-005 | Review candidate | P2 | High for code path, Medium for live impact | Healing defaults to an in-memory circuit instead of the existing durable circuit seam. |
| EU-006 | Review candidate | P3 | High | Agent memory describes a structural store contract but directly constructs a concrete SQLite implementation. |

The most important operational issue is EU-003. The MCP layer correctly types a
post-send transport failure as `AmbiguousOutcomeError`, but the production
adapter maps it to `Tamoz::EffectUnknownError`. `EffectDispatcher` only converts
`ToolError` into a terminal journal receipt; the unknown error propagates after
the attempt is started. The repository already supports `complete(status:
:unknown)`, so the existing lifecycle seam is not being used for this case.

The current focused tests pass for capability binding, schedule behavior, MCP
adversarial behavior, and effect-journal recovery. The dependency-isolation test
reproduces two failures caused by EU-004.

## Method and evidence

I used:

- `rg --files` and targeted `rg` searches for inventory, cross-gem references,
  contract declarations, `bind_*` seams, `respond_to?` guards, direct external
  calls, and effect/journal entry points.
- Source and caller tracing from construction through execution and persistence.
- The existing Enola architecture snapshot, without regenerating it. It reports
  537 files seen, 495 parsed, 0 parse errors, 9,659 facts, and 52 insights. The
  snapshot is a structural aid, not a substitute for semantic review; its one
  cycle insight has confidence 0.40 and its exported-surface insight has
  confidence 0.60.
- Ruby 3.3.11 through `rbenv`, because the system Ruby is 2.6 and cannot activate
  the locked Bundler 4.0.12.
- Focused tests, all read-only:

  ```text
  test/agent_capability_binding_test.rb       14 runs, 61 assertions, 0 failures
  test/sqlite_schedule_store_test.rb          19 runs, 67 assertions, 0 failures
  test/agent_mcp_adversarial_test.rb           8 runs, 41 assertions, 0 failures
  test/sqlite_effect_journal_test.rb           8 runs, 35 assertions, 0 failures
  test/dependency_isolation_test.rb           12 runs, 98 assertions, 2 failures
  ```

The first attempt with plain `bundle exec` used `/usr/bin/ruby` and failed before
running tests because Bundler 4.0.12 is not installed for Ruby 2.6. The documented
fallback, `rbenv exec bundle exec ...`, ran the tests successfully and is the
result reported above.

## Confirmed findings

### EU-001 — MCP source preflight is not the contract the session consumes

Severity: P2

Confidence: High

Status: Confirmed defect at a public caller boundary.

Evidence:

- `gems/tamoz-agent/lib/tamoz/agent/session.rb:138-153` advertises a duck-typed
  source and checks `mcp_catalogs`, `catalogs`, `names`, `read_only_names`,
  `name?`, `read_only?`, `approval_required?`,
  `maximum_effect_output_bytes`, `validate`, `effect_intent`, `preview`, and
  `execute`.
- `gems/tamoz-agent/lib/tamoz/agent/capability_binding.rb:66-69` immediately
  calls `grouped_mcp_descriptors`, and
  `gems/tamoz-agent/lib/tamoz/agent/capability_binding.rb:182-187` calls
  `@mcp.descriptors`.
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb:233-238` later calls
  `source.name?`, `source.descriptor_for(name)`, and `source.catalogs[...]`.
- `gems/tamoz-agent/lib/tamoz/agent/mcp_capability_source.rb:47` exposes both
  `descriptors` and the catalog-backed `descriptor_for` method at lines 108-110.
- The test double in `test/agent_capability_binding_test.rb:28-50` happens to
  implement `descriptors` and `descriptor_for`, so the happy-path test does not
  expose the incomplete preflight list.

A source implementing exactly the contract named by `verify_mcp_source!` can pass
the guard and then fail with `NoMethodError` during session construction or
planning. That turns a caller error into an untyped internal failure and makes
the advertised duck-typed seam materially smaller than the actual seam.

Five whys:

1. Why can a conforming source fail late? The preflight list omits two methods
   used by capability binding and session effects.
2. Why are they omitted? The validation list was maintained separately from the
   consumers.
3. Why is that risky? The source is intentionally a public dependency-inversion
   boundary, so callers are expected to implement it without importing MCP.
4. Why was the test insufficient? It covers one complete recording source but no
   negative source with each required method removed.
5. Root cause: the duck-typed contract has no single executable completeness
   check shared by validation and its callers.

Recommendation:

- Add `descriptors` and `descriptor_for` to the existing `required` list in
  `Session#verify_mcp_source!`; do not introduce a second source abstraction.
- Add a negative construction test that removes each of those methods and asserts
  the typed `ArgumentError` before graph construction.
- Keep the descriptor-value contract separate: the existing
  `McpCapabilitySource#validate_descriptors!` and MCP invocation checks correctly
  govern descriptor fields and should not be broadened merely to fix this method
  list.

### EU-002 — `ScheduleStore` contract drift breaks adapter interchangeability

Severity: P2

Confidence: High

Status: Confirmed contract defect. Current SQLite execution works because its
clients know the implementation extension; the documented interchangeable
adapter boundary does not hold.

Evidence:

- `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:5-8` says this is a
  versioned structural contract and that conforming adapters are interchangeable.
- Its `materialize_due` declaration at
  `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:35-44` accepts only
  `now`, `owner`, `lease_for`, `limit`, and `request_template`.
- The first adapter instead requires `current_grant` and accepts
  `include_provenance` at
  `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:214-225`.
- The production worker knows this non-contract extension and passes both at
  `gems/tamoz-agent/lib/tamoz/agent/worker.rb:131-145`.
- The same SQLite implementation adds `enable_schedule` at
  `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:138-169`, but the public
  contract has `disable_schedule` at lines 29-33 and no `enable_schedule`.
- The CLI calls the undeclared method at
  `gems/tamoz-agent/lib/tamoz/agent/cli_schedule_commands.rb:163-172`.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb:18-24` exposes the schedule
  binding, but there is no separate lifecycle extension seam that tells a client
  it is receiving a SQLite-only implementation.

The current adapter cannot be substituted behind the contract without either
accepting undeclared keywords or implementing a method that the contract does not
mention. A caller using only `Tamoz::Scheduler::ScheduleStore` cannot implement
the same worker/CLI behavior reliably.

Five whys:

1. Why do the public contract and caller disagree? Policy grant and provenance
   were added to SQLite after the original structural method was declared.
2. Why was the contract not updated? The adapter and its callers evolved in
   lockstep, so the concrete path stayed green.
3. Why does `enable_schedule` drift separately? Lifecycle symmetry was added to
   SQLite/CLI but not to the scheduler contract module.
4. Why is this a production concern? A public contract is explicitly documented
   as interchangeable, so alternative storage or test adapters can fail at
   runtime.
5. Root cause: the versioned contract is not the single source of truth for all
   operations and policy inputs used by its clients.

Recommendation:

- Make one deliberate, versioned contract decision. The simplest path is to
  update `Tamoz::Scheduler::ScheduleStore` to declare `enable_schedule`,
  `current_grant`, and `include_provenance`, then increment the contract version
  because the public method shape changes.
- Alternatively, if provenance or grants are deliberately SQLite-only, expose a
  clearly named policy/lifecycle extension and stop claiming full adapter
  interchangeability. Do not leave the current implicit extension.
- Add a contract test that exercises every declared operation against the SQLite
  implementation and a minimal conforming fake. Include the exact keyword shape
  and both lifecycle directions.

This recommendation follows the repository’s no-backwards-compatibility rule:
make the contract change cleanly and update all in-repository callers rather than
adding compatibility shims.

### EU-003 — MCP ambiguous outcomes are not completed as journal `unknown`

Severity: P1

Confidence: High

Status: Confirmed durability/lifecycle defect in the production adapter path.

Evidence:

- `gems/tamoz-mcp/lib/tamoz/mcp/errors.rb:97-106` defines
  `AmbiguousOutcomeError` for a non-idempotent request sent before transport
  failure and says it must be marked `:unknown`.
- `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:440-455` raises that exact error
  after a request was sent for a non-read-only descriptor.
- The production mapper at
  `gems/tamoz-agent/lib/tamoz/agent/mcp_source_builder.rb:108-130` maps it to
  `Tamoz::EffectUnknownError`.
- `gems/tamoz-agent/lib/tamoz/agent/effect_dispatcher.rb:153-177` starts the
  effect, rescues only `ToolError` at lines 157-170, and otherwise completes the
  effect as `:succeeded` only after `perform` returns. `EffectUnknownError` is
  `Tamoz::EffectUnknownError` from
  `gems/tamoz-core/lib/tamoz/error.rb:166-169`, not a `ToolError`.
- The dispatcher’s intended unknown branch exists at
  `gems/tamoz-agent/lib/tamoz/agent/effect_dispatcher.rb:133-141`, but it is
  reachable only when journal preparation/reconciliation returns `:unknown`; the
  synchronous exception path never constructs that `Outcome`.
- SQLite explicitly supports terminal unknown completion at
  `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_completion.rb:25-39`.
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb:39-46` routes the MCP
  execution through `EffectDispatcher`, and
  `gems/tamoz-agent/lib/tamoz/agent/session_steps.rb:154-168` has the correct
  blocked-state handling for an `Outcome` whose status is `:unknown`.

A minimal Ruby 3.3 contract harness using the real `EffectDispatcher`, a started
fake effect, and `Tamoz::EffectUnknownError` observed `prepare`, `start`, then
the exception; `complete` was not called. Thus the current synchronous path leaves
the attempt running until a later recovery/fence pass, instead of recording the
known semantic fact that the external outcome is unknown and returning the
session’s blocked/unknown path.

The focused adversarial test does not close this gap. Its helper at
`test/agent_mcp_adversarial_test.rb:80-100` catches
`Tamoz::Mcp::AmbiguousOutcomeError` and maps it to `Tamoz::Agent::ToolError`, and
the test at lines 290-325 asserts `:failed`. That exercises a custom test executor,
not `McpSourceBuilder`’s production mapping or the terminal journal receipt.

Five whys:

1. Why does the request not become `unknown` immediately? The mapped exception is
   outside `EffectDispatcher`’s only handled failure taxonomy.
2. Why was it mapped to a core error? The MCP adapter correctly wanted to prevent
   retry/repair, but it used an exception path rather than the journal’s unknown
   outcome contract.
3. Why does recovery eventually hide the problem? SQLite recovery can fence an
   old unsafe running attempt and mark it unknown, but that is a later lifecycle
   event, not the result of this failed call.
4. Why did tests not catch it? The adversarial test supplies a different mapper
   and checks non-retry rather than the actual journal row/status.
5. Root cause: the semantic “unknown external effect” type is not integrated at
   the durable effect boundary where all terminal effect states are normalized.

Recommendation:

- Handle `Tamoz::EffectUnknownError` at the existing `EffectDispatcher` boundary
  (or convert it in the existing MCP executor before it returns) by completing the
  started attempt with `status: :unknown` and returning the existing `Outcome` with
  `status: :unknown`. Preserve the error as bounded evidence if the journal
  contract permits it; do not convert it to a repairable `ToolError`.
- Add a production-path test that uses the `McpSourceBuilder` mapping, a started
  unsafe effect, and verifies: one attempt, terminal journal status `unknown`, no
  second invocation, and the session’s blocked evidence update.
- Keep the existing recovery tests: they cover process death and late truth, which
  is a distinct path from a synchronous adapter-known ambiguity.

### EU-004 — `tamoz-evals` violates its own stdlib-only load boundary

Severity: P2

Confidence: High

Status: Confirmed repository boundary inconsistency and failing quality gate.

Evidence:

- `gems/tamoz-evals/README.md:3-4` says the artifact verifier is stdlib-only and
  never a runtime dependency of a production Tamoz gem. Lines 16-19 describe the
  agent-smoke profile as optional and lazily loading an installed agent.
- `gems/tamoz-evals/lib/tamoz/evals.rb:6-12` eagerly requires `tamoz/core`,
  `tamoz/agent`, `tamoz/sqlite`, and `tamoz/mcp` before loading the verifier or
  CLI.
- `gems/tamoz-evals/tamoz-evals.gemspec:6-18` declares all four as runtime
  dependencies, including `tamoz-agent`, `tamoz-sqlite`, and `tamoz-mcp`.
- The CLI has an ordinary verifier path at
  `gems/tamoz-evals/lib/tamoz/evals/cli.rb:48-58` and `:100-117`, but it cannot
  reach that path in a minimal install because the root require has already loaded
  the runtime packages.
- The repository’s own boundary test at
  `test/dependency_isolation_test.rb:52-67` requires `tamoz/evals` to load no
  `tamoz/core`, `tamoz/graph`, `tamoz/sqlite`, or `tamoz/agent`. It fails with the
  runtime feature list showing those packages.
- The same test at `test/dependency_isolation_test.rb:175-186` prohibits a
  production gemspec from depending on `tamoz-agent` except the explicitly
  allowed agent dependents. It fails for `tamoz-evals`.
- `docs/design-v0.1/DECISIONS.md:488-490`, `docs/M0.md:3-8`, and
  `docs/P12_SELF_HEALING_PLAN.md:67-68` all preserve the separation between
  evaluation and runtime load paths.

This is not merely a stale comment: the focused test reproduces two failures,
12 runs, 98 assertions. Ordinary `tamoz-eval verify` is coupled to the entire
agent/store/MCP load graph and package dependency set, defeating the stated
optional profile boundary.

Five whys:

1. Why does `require "tamoz/evals"` load runtime packages? The root initializer
   requires every harness dependency unconditionally.
2. Why is that initializer unconditional? Harness classes reference runtime
   constants directly and the gemspec was made to guarantee their availability.
3. Why is that wrong? Artifact verification is supposed to be usable without the
   runtime; only optional scorecards/treatments need those classes.
4. Why did the inconsistency survive? The root-load test and gemspec policy were
   not kept in sync with the harness packaging decision.
5. Root cause: one package initializer is serving two incompatible dependency
   surfaces: stdlib-only artifact verification and runtime integration harnesses.

Recommendation:

- Restore a stdlib-only root path: load artifact schemas, verifier, result types,
  and the CLI’s `verify` command without agent/SQLite/MCP requires.
- Lazy-load the scorecard/treatment harness and its runtime packages only inside
  those explicit commands, with a typed missing-optional-runtime error.
- Align package metadata with the chosen ownership. If the optional harness must
  ship independently, split it into an evaluation-runtime package or otherwise
  make the runtime prerequisite explicit; do not retain unconditional runtime
  dependencies while claiming stdlib-only operation.
- Re-run `test/dependency_isolation_test.rb`, packaging tests, and ordinary
  `tamoz-eval verify` in a process whose load path contains only core eval files.

## Review candidates (not counted as confirmed live defects)

### EU-005 — Healing defaults to an in-memory circuit despite the durable circuit seam

Severity: P2 if healing is invoked in production without an injected circuit.

Confidence: High for the code path; Medium for live impact because no production
caller of `Healing::Remediation.run` was found outside tests/evaluation harnesses.

Evidence:

- `gems/tamoz-agent/lib/tamoz/agent/healing/remediation.rb:62-105` accepts an
  optional `circuit:` and defaults it at line 91 to
  `Seams::MemoryCircuitStore.new`.
- `gems/tamoz-agent/lib/tamoz/agent/healing/seams.rb:11-17` describes that
  in-memory object as a default while saying a durable implementation will “drop
  in”; its implementation is at lines 37-97.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb:5-20` says SQLite is the
  durable adapter over the single `Tamoz::Circuit` engine. The adapter explicitly
  states at lines 40-44 that it is the shared interface for the healing and MCP
  call sites.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb:119-151` provides the
  durable CAS-backed `record_failure`, `record_success`, and authority-gated
  `reset` operations.
- `docs/P12_SELF_HEALING_PLAN.md:55-65` says there must be one durable circuit
  record and “No second circuit engine under any resolution.”
- No `Adapter#bind_circuit_store` or production worker/session wiring was found;
  the current production-facing remediation entry point can therefore silently
  run with process-local circuit state if callers omit `circuit:`.

The contract itself intentionally supports a testable in-memory default, so this
is not proven to be a current production incident. It is nevertheless a risky
default for a durable healing protocol: restart loses the failure counter and the
authority/evidence history.

Recommendation:

- Trace the intended production owner and add an explicit adapter binding for
  `Tamoz::SQLite::CircuitStore`, or make the production remediation entry point
  require a circuit while keeping the in-memory object in a test-only helper.
- Add an integration test that exercises a verification failure, closes/reopens
  the adapter, and proves the circuit remains open with the same scope/evidence.
- Do not add a third circuit abstraction; reuse `Tamoz::Circuit` plus the existing
  SQLite adapter as required by the design.

### EU-006 — Agent memory calls a concrete SQLite repository through a claimed structural contract

Severity: P3 maintainability/boundary risk.

Confidence: High for the mismatch between the claim and implementation; Medium
that alternate storage is an intended supported use case today.

Evidence:

- `gems/tamoz-agent/lib/tamoz/agent/memory/surface.rb:6-10` says the agent owns
  memory semantics and depends on a structural `Tamoz::SQLite::MemoryStore`
  contract.
- `gems/tamoz-agent/lib/tamoz/agent/memory/surface.rb:55-72` directly constructs
  `Tamoz::SQLite::MemoryStore` from `adapter.store` at line 65.
- `gems/tamoz-agent/lib/tamoz/agent/memory/surface.rb:102-124` directly constructs
  the SQLite-owned `MemoryStore::IndexRow` at line 105.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb:7-30` calls itself the
  SQLite-owned structural repository; lines 37-80 define the SQLite-owned value
  type; lines 102-110 require the exact `Tamoz::SQLite::Store` class; and lines
  116-169 call private/shared SQLite transaction primitives.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb:13-61` exposes several explicit
  `bind_*` seams but no `bind_memory_store` seam.

The agent gemspec is allowed to depend on SQLite, so this is not a forbidden
dependency edge and no current SQLite path is broken. The concern is that the
word “contract” and the direct class/type checks promise more interchangeability
than the code provides.

Recommendation:

- If SQLite is the only supported memory backend, document and name this as the
  concrete SQLite implementation rather than an interchangeable contract.
- If alternate stores are a real requirement, introduce the narrowest existing
  adapter binding/value seam needed by two real consumers, and test it with a
  non-SQLite conformer. Do not create a new gem or duplicate storage machinery
  preemptively.

## End-to-end usage traces

### Durable agent session

`WorkerRuntime`/CLI constructs a durable SQLite adapter and session. `Session`
rejects a non-durable checkpointer at
`gems/tamoz-agent/lib/tamoz/agent/session.rb:90-94`. Session construction creates
`CapabilityBinding`, then graph nodes. Model calls and tool calls enter
`SessionEffects` (`model_call` at `session_effects.rb:17-29`, tool dispatch at
`:39-46`), which calls `EffectDispatcher.run`. The SQLite adapter provides the
effect journal and checkpoint store. Normal `:unknown` journal decisions flow to
`SessionSteps#handle_outcome` and blocked evidence. This path is correct except
for the synchronous MCP ambiguity escape in EU-003.

### MCP capability path

The caller builds a catalog/supervisor/source in `McpSourceBuilder`; the source
holds pinned catalogs and descriptors. `CapabilityBinding` groups descriptors by
source and uses `McpDispatcher` to forward validation, preview, policy, and
execution. `SessionEffects#dispatch` wraps execution in the ordinary effect
journal. `Tamoz::Mcp::Invocation` owns SDK invocation and classifies post-send
transport failure. This is the correct ownership shape: `tamoz-agent` does not
depend on `tamoz-mcp`, and MCP does not own agent approval policy. The contract
preflight and ambiguous completion are the two defects identified above.

### Communications and delivery

`CommsGateway` polls a `Tamoz::Comms::Transport`, admits through the SQLite
`CommsStore`, persists the inbound offset, and drains the durable outbox.
`OutboxDeliverySink` creates delivery rows; `DeliveryDrainer` claims/reserves,
binds the effect key, calls transport delivery, and records success/failure or
unknown. Approval prompts use `DecisionStore` and authority evidence. The direct
thread-profile write in `CommsGateway#bind_thread_profile` at
`gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb:373-381` was reviewed and is
intentional agent-owned authority state, not channel transport state; it is not a
finding.

### Scheduler

The worker calls the SQLite schedule store’s single atomic `materialize_due`
operation, passing the worker grant and closed-session payload option. The store
claims, creates, and enqueues in one transaction and returns occurrences. CLI
pause/resume uses the same store but calls the SQLite-only `enable_schedule`.
The atomic path is sound; the public contract drift is EU-002.

### Memory

The agent memory engine owns admission, retrieval, lifecycle, consolidation, and
promotion policy. It builds a repository over `adapter.store`, and the SQLite
repository atomically writes the Store record and search index. The atomic storage
seam is used correctly; EU-006 is about the claimed abstraction boundary, not a
proven data-integrity failure.

### Stream, tools, observability, and transports

`tamoz-stream` episode and situation paths use injected decision, evidence,
verification, artifact, and approval ports. Its capability host allowlist is
enforced inside the stream gem. `tamoz-tools` owns local tool execution, file
effect preparation, checks, and skills. `tamoz-telegram` implements the Comms
transport contract; `tamoz-otel` implements the Observability exporter contract
with endpoint/credential policy; `tamoz-mcp` owns SDK/network process adapters.
No direct durable-node bypass was confirmed in these paths. Direct `__send__`
uses in SQLite/graph/evaluation code are internal implementation or fault-probe
accesses, not external callers bypassing a public seam.

## Component coverage checklist

The inventory covered 441 production Ruby files and 78,127 production Ruby lines.
The table accounts for every production gem; the symbol groups are the seams
traced, not a sample selection.

| Component | Inventory | Usage/contracts traced | Result |
|---|---:|---|---|
| `tamoz-agent` | 128 files / 25,615 lines | Session construction, durable runner, graph nodes, effects, capability binding, MCP source, worker/scheduler, CLI, comms gateway/outbox, memory, healing, episode/model ports, profiles, runtime | EU-001, EU-003, EU-005, EU-006 |
| `tamoz-comms` | 22 / 2,339 | Transport, CommsStore, DecisionStore, DeliverySink, admission, binding, approval, rendering, wire values | No confirmed misuse |
| `tamoz-core` | 30 / 4,623 | Error taxonomy, `EffectUnknownError`, StateCodec, Context, Store values, Circuit value/registry, capability descriptors, pool, canonicalization | Supports EU-003 evidence; no separate misuse |
| `tamoz-evals` | 44 / 12,431 | Root loader, CLI, verifier, scorecard/treatment harnesses, subprocesses, SQLite probes, agent/MCP harnesses | EU-004; private calls are intentional eval probes |
| `tamoz-graph` | 48 / 5,516 | Definition/compiler, checkpoint codec, durable runner/executor, Context, effects, leases, lifecycle, fork/subgraph, stream | No confirmed misuse |
| `tamoz-mcp` | 17 / 3,407 | Catalog, descriptors, Invocation, Supervisor, SDK process lifecycle, circuit seam, websearch/HTTP egress | EU-003 producer; no authority bypass |
| `tamoz-observability` | 18 / 1,869 | Signal/catalog, recorder/producer, trace/metrics, telemetry reader, content policy | No confirmed misuse |
| `tamoz-otel` | 5 / 418 | Exporter contract, HTTPS/credential policy, HTTP exporter, async lifecycle | No confirmed misuse |
| `tamoz-scheduler` | 8 / 927 | ScheduleStore contract, Schedule/Occurrence, grants/intersection, scheduler errors and consumers | EU-002 |
| `tamoz-sqlite` | 67 / 13,350 | Adapter bind seams, Store/StateCodec, checkpoint/request inbox, EffectJournal/recovery, CircuitStore, CommsStore/outbox, ScheduleStore, MemoryStore, leases and migrations | EU-002, EU-005, EU-006; storage paths otherwise coherent |
| `tamoz-stream` | 25 / 4,237 | Episode/situation protocol, generated protobuf, CapabilityHost, SSE, worker server, approval relay, injected stores/clients | No confirmed misuse |
| `tamoz-telegram` | 5 / 371 | Comms transport and Telegram HTTP boundary | No confirmed misuse |
| `tamoz-tools` | 24 / 3,024 | CapabilityHost, Toolbox, LocalDispatcher, file operations, checks, skills, staging/reaper | No confirmed misuse |

Additional in-scope inventory:

- `apps/`: 0 Ruby production files (`apps/tamoz-agent` is a directory-level
  entry point area).
- `bin/`: 0 Ruby files.
- `script/`: 3 Ruby files.
- `scripts/`: 1 shell launcher, `start-tamoz-comms.sh`.
- `test/`: 212 Ruby test files. Relevant contract, dependency, MCP, schedule,
  effect, circuit, memory, stream, packaging, and public-API tests were traced;
  five focused test files were executed as listed above.
- Relevant configuration/docs included `.ruby-version`, `Gemfile`,
  `Gemfile.lock`, `Rakefile`, every gemspec, `AGENTS.md`,
  `docs/CODING_STANDARD.md`, `docs/QUALITY_PROGRAM.md`,
  `docs/QUALITY_PROGRAM_STATE.md`, package/design boundary documents, and the
  existing Enola snapshot. There are 253 Markdown files under `docs/`; the audit
  used targeted boundary/design documents rather than treating historical review
  prose as executable evidence.

## Confirmed non-findings and false positives

- `Tamoz::Agent::Runtime` directly executes model/tools because it is explicitly
  the ephemeral API. `Session` rejects non-durable checkpointers and directs users
  to `Runtime` at `session.rb:90-94`; this is not a durability bypass.
- `McpSourceBuilder` directly calls `Tamoz::Mcp::Invocation` inside its injected
  executor. That call is reached through `SessionEffects` and the effect journal;
  it is the adapter seam, not a raw durable-node call.
- Evaluation harnesses directly invoke agent/MCP/SQLite code and private SQLite
  methods for fault injection, convergence probes, and subprocess evidence. Those
  are intentionally outside production runtime; EU-004 is about the package root
  loading them unconditionally.
- SQLite and graph `__send__` calls are internal access to transaction, lease,
  checkpoint, and reconciliation primitives owned by those gems. No external
  public caller was found bypassing the corresponding adapter.
- The Comms gateway’s generic Store write for thread profiles is agent authority
  state, while channel data uses `CommsStore`; it is not accidental transport/store
  duplication.
- The Enola cycle and exported-surface insights were treated as review signals,
  not defects, because their confidence is below a semantic verdict and source
  tracing found no corresponding confirmed boundary violation.

## Coverage and blind spots

Coverage counts:

- 13 production gems: all 13 inventoried; 441 Ruby files / 78,127 lines counted.
- 212 test Ruby files inventoried; 5 focused test files executed.
- `apps/` and `bin/`: 0 Ruby files each; `script/`: 3 Ruby files; `scripts/`: 1
  shell launcher.
- Enola snapshot: 537 files seen, 495 parsed, 0 parse errors, 9,659 facts, 52
  insights.
- The report contains 4 confirmed findings, 2 review candidates, and 0 confirmed
  authority/approval bypasses outside the contract/lifecycle defects listed.

Blind spots and limits:

- Enola’s existing snapshot skips configuration/docs and generated/ignored areas;
  it also skips `agenteval/` and other non-production material. Those areas were
  inventoried or read as relevant, but were not graph-parsed.
- No live Telegram, MCP server, model provider, OTLP endpoint, or external
  network was contacted. Transport and egress conclusions are source- and
  focused-test-based.
- The full `rake ci` quality program was not run in audit mode because the repo’s
  quality workflow can generate or update state/baseline artifacts. This report
  does not claim a full CI pass; it reports the focused test evidence and the
  reproducible dependency-isolation failures.
- The MCP production ambiguity finding is proven at the dispatcher/journal seam,
  but an end-to-end live MCP server was not used. The recommended production-path
  test should close that remaining integration-evidence gap.
- EU-005’s live impact remains conditional because no production caller of
  `Healing::Remediation.run` without `circuit:` was found. The default behavior is
  nevertheless documented because it is an exposed lifecycle choice.
- Existing untracked directories outside this assigned report were preserved.
  Only this Markdown report was added in the requested audit folder.

## Recommended priority order

1. Fix EU-003 and add the production-path unknown-outcome test before enabling or
   relying on unsafe remote effects.
2. Align EU-002’s scheduler contract and add a contract-level adapter test.
3. Fix EU-001’s preflight completeness and negative coverage.
4. Resolve EU-004’s evaluation package split/lazy-loading policy, then restore the
   dependency-isolation gate.
5. Decide and wire the production owner for EU-005; clarify EU-006 before adding
   another memory backend or abstraction.
