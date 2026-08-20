# Gem boundaries and placement audit

Date: 2026-08-20  
Repository: `/Users/ghassan/my-projects/tamoz`  
Branch: `sonnet-refactoring`  
Scope: gem/module placement, dependency direction, public API surfaces, cross-gem coupling, gemspec/package completeness, load-time isolation, and cohesion.

## Executive assessment

The repository has a generally sound layered gem architecture. The lower-level direction is consistent: `tamoz-core` is the base, `tamoz-tools`, `tamoz-graph`, `tamoz-scheduler`, `tamoz-stream`, and the adapter gems do not depend upward on `tamoz-agent`. `tamoz-agent` is the composition/runtime gem, and optional MCP/Telegram integrations are loaded at their seams rather than from every entrypoint.

The audit found:

- 2 confirmed defects affecting packaging or executable architecture gates.
- 2 additional confirmed metadata/test-contract defects that make the intended boundaries unreliable.
- 2 evidence-backed extraction candidates, both requiring deliberate migration work.
- No evidence that the remaining gems should be merged or split now.

The most urgent issue is that `tamoz-stream` reads a runtime contract from `contracts/`, but the shared gemspec file list excludes that directory. The installed gem therefore does not contain a file required by a real notification path. Separately, `tamoz-evals` is documented and tested as stdlib-only while its entrypoint intentionally loads four production gems; the current isolation test fails in two places. These are inconsistent contracts, not merely stylistic concerns.

## Method and evidence

I inspected all 13 gem roots and gemspecs, all runtime Ruby files under `gems/`, `apps/`, `bin/`, and `script/`, the complete `test/` inventory, shared test loading, packaging tests, dependency-review generation, public API tests, architecture documentation, and relevant root configuration.

Architecture evidence came from the enola snapshot and check:

- 537 files seen, 495 parsed, 0 parse errors, 9,659 facts, and 52 heuristic insights.
- `enola check --fail-on=cycles,layers --min-confidence=0.8 .` passed.
- The only cycle insight was a low-confidence 0.40 coupling-density signal, explicitly not a confirmed cycle defect.
- The only exported-surface insight was `gems/tamoz-stream/contracts`, where all 35 symbols are generated protobuf surface; this is expected wire-contract exposure, not evidence for a move by itself.

Behavioral validation used the repository's bundled Ruby through `rbenv exec`. The focused isolation test ran 12 tests and 98 assertions, with 2 failures described below. Plain `bundle` selected the system Ruby 2.6 and could not use the locked Bundler version, so `rbenv exec bundle exec` was the documented fallback for the available toolchain.

## Runtime dependency map

The direct internal runtime dependencies declared by the gemspecs are:

| Gem | Direct internal dependencies | Placement assessment |
|---|---|---|
| `tamoz-core` | none | Correct foundation. Zeitwerk is its only runtime dependency. |
| `tamoz-tools` | core | Correct lower-level tool layer. |
| `tamoz-graph` | core | Correct graph/orchestration layer; no LLM or HTTP dependency observed. |
| `tamoz-comms` | core | Correct communication contract layer. |
| `tamoz-observability` | core | Correct instrumentation contract layer. |
| `tamoz-scheduler` | core | Correct scheduling contract layer. |
| `tamoz-stream` | core | Correct stream/worker boundary, but its runtime contract packaging is incomplete. |
| `tamoz-mcp` | core | Correct MCP adapter boundary; websearch is already excluded from the main entrypoint. |
| `tamoz-sqlite` | graph, scheduler, stream | Cohesive SQLite adapter, but it inherits unnecessary stream worker load-time dependencies. |
| `tamoz-otel` | observability | Correct optional exporter adapter. |
| `tamoz-telegram` | comms | Correct optional transport adapter. |
| `tamoz-agent` | tools, graph, sqlite, comms, observability | Correct composition/runtime layer. Optional SQLite, Telegram, and MCP paths are loaded at their use sites. |
| `tamoz-evals` | core, agent, sqlite, mcp | It is a runtime-coupled evaluation harness, contrary to its current stdlib-only documentation/test contract. It also directly uses graph/scheduler APIs without declaring them. |

All 13 gems currently use the same `0.1.0.alpha.1` version and pin internal sibling dependencies to that version. This is a deliberate lockstep release model, but it means any new contract gem or move has a coordinated gemspec, Gemfile, package-test, and documentation cost.

## Findings

### GB-01 — Required stream contract is absent from the packaged gem

Status: confirmed defect  
Severity: High  
Confidence: 1.0

Evidence:

- `gems/tamoz-stream/lib/tamoz/stream/notification_contract.rb:46-60` computes a path under `gems/tamoz-stream/contracts/notification-contract-v1.json` and reads it with `File.read`.
- The file exists in the workspace at `gems/tamoz-stream/contracts/notification-contract-v1.json`.
- `gems/gemspec_helper.rb:24-30` includes `lib/**/*.rb`, selected JSON directories, `exe/*`, and metadata, but no `contracts/**` pattern.
- Loading `tamoz-stream.gemspec` and filtering `spec.files` for `contracts/` returns an empty list.
- `gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb:41` and `outcome_subscriber.rb:133,152` call the notification contract path in real runtime flows.
- The current stream package test exercises snapshot/artifact behavior but does not install the package and validate `NotificationContract` from the installed artifact. The workspace contract test therefore does not catch this failure.

Why it matters: the development checkout works because the source tree contains the JSON. A built or installed `tamoz-stream` cannot satisfy a notification path that validates the contract, and the resulting failure is likely wrapped as a stream conformance error. This is a release-boundary failure, not a possible future cleanup.

Recommendation: include the required runtime contract JSON in `spec.files`, preferably with an explicit per-gem runtime-contract pattern rather than broadening every gem's package contents. Add an installed-artifact isolation test that requires `tamoz/stream` and validates a known notification contract. Keep protobuf sources, goldens, and development vectors out of the package unless a production caller proves it needs them.

Expected cost: low to medium. It requires one gemspec/helper change, a package test, and a review of which stream contract files are runtime inputs. No gem move is necessary.

### GB-02 — `tamoz-evals` has a contradictory package contract and a failing isolation gate

Status: confirmed architecture/test-contract defect  
Severity: High  
Confidence: 1.0

Evidence:

- `gems/tamoz-evals/lib/tamoz/evals.rb:9-12` requires `tamoz/core`, `tamoz/agent`, `tamoz/sqlite`, and `tamoz/mcp` at entrypoint load time.
- `gems/tamoz-evals/tamoz-evals.gemspec:16-20` declares those four runtime dependencies.
- A clean process requiring `tamoz/evals` loads `tamoz/core`, `tamoz/graph`, `tamoz/sqlite`, and `tamoz/agent` in addition to evals.
- `test/dependency_isolation_test.rb:56-63` names the rule `test_evals_is_stdlib_only_and_loads_no_runtime_package` and asserts that core, graph, sqlite, and agent are not loaded. This test fails.
- `README.md`, `documentation/architecture/gems.md:55,73`, `documentation/architecture/overview.md:80`, and `documentation/getting-started/install.md:68-71` describe evals as stdlib-only or as depending on nothing.
- `test/packaging_test.rb:57-66` explicitly acknowledges that the eval harness references agent, SQLite, MCP, core, graph, scheduler, stream, and other runtime gems and manually installs a broad package set.

The root cause is a conflation of two different properties: “no production gem depends on evals” and “evals has no runtime dependencies.” The first can be a valid architecture rule; the second is false in the current implementation.

Recommendation: choose and document one executable contract. The simple, evidence-backed option is to treat `tamoz-evals` as a development/release meta-gem: keep its declared runtime dependencies, change the isolation test to assert that production gems do not depend on evals, and update the README and architecture/install docs. If a genuinely stdlib-only verifier or artifact reader is required by a real consumer, extract only that proven seam into a separate `tamoz-evals-core` and leave the harness in a runtime-coupled gem. Do not split the 44-file, 12,431-LOC harness speculatively.

Expected cost: low to medium for correcting the contract and tests; high for a real split because the CLI, harness, fixtures, package tests, public API, and documentation all need migration.

### GB-03 — The evals gem directly uses graph and scheduler APIs without direct declarations

Status: confirmed dependency metadata defect  
Severity: Medium  
Confidence: 0.95

Evidence:

- `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb:2781-2794` requires `tamoz/sqlite` and `tamoz/scheduler`, then uses `Tamoz::Scheduler` and `ScorecardSummaryConsumer`.
- `gems/tamoz-evals/lib/tamoz/evals/harness/sqlite_scenario_runtime.rb:69,418,656` directly references `Tamoz::Graph::Task`, `Tamoz::Graph::Interrupt`, and `Tamoz::Graph`.
- `tamoz-evals.gemspec:16-20` declares core, agent, SQLite, and MCP, but not `tamoz-graph` or `tamoz-scheduler`.
- The package tests install graph and scheduler manually, which masks whether evals' gemspec is complete. The dependency-review test checks third-party closure, not internal direct API ownership.

Why it matters: the current install succeeds only because graph and scheduler arrive transitively through other gems. A future internal dependency cleanup can break evals without changing evals code. The gemspec should describe the APIs the gem directly imports or reference only a declared higher-level seam.

Recommendation: either add direct runtime dependencies on graph and scheduler, or remove the direct imports and route through a declared public API. Add a regression check for direct internal `require` and constant ownership versus gemspec declarations. This should be decided together with GB-02.

Expected cost: low to medium: gemspec/version updates, package isolation coverage, and dependency documentation.

### GB-04 — Dependency review inventory covers 9 of 13 gemspecs

Status: confirmed provenance/maintenance defect  
Severity: Medium-Low  
Confidence: 1.0

Evidence:

- `script/generate_dependency_review:13-18` describes a nine-gem review.
- Its `GEMS` constant at `script/generate_dependency_review:27-30` includes core, graph, scheduler, stream, SQLite, tools, agent, MCP, and evals, but excludes `tamoz-comms`, `tamoz-telegram`, `tamoz-observability`, and `tamoz-otel`.
- `docs/DEPENDENCY_REVIEW.md:3-7` repeats the nine-gem scope.
- The repository actually contains 13 gemspecs, and `test/test_helper.rb:15-17` inventories all 13.
- The four excluded gems currently have no third-party runtime dependencies, so the generated report happens to agree with the current dependency set. That coincidence does not make the inventory complete.

Why it matters: the script's output is presented as a repository dependency review, but adding a third-party dependency to any excluded adapter will not update the generated source set. This creates a latent packaging/license/provenance blind spot and makes the review scope diverge from the actual monorepo.

Recommendation: derive the gem list from `gems/tamoz-*/tamoz-*.gemspec`, or maintain an explicit 13-gem list with a test that fails when any gemspec is absent. If evals is intentionally treated separately, encode that policy as a category rather than silently omitting four production gems.

Expected cost: low. Update the generator, regenerate the report, and add an inventory regression test.

### GB-05 — SQLite inherits the stream worker's gRPC/protobuf load surface

Status: architecture candidate, not current functional defect  
Severity: Medium  
Confidence: 0.9

Evidence:

- `gems/tamoz-sqlite/lib/tamoz/sqlite.rb:3-6` requires graph, scheduler, stream, and sqlite3 at top level.
- `gems/tamoz-stream/lib/tamoz/stream.rb:3-16` eagerly requires stream contracts, notification handling, transports, and `worker_server`.
- `gems/tamoz-stream/lib/tamoz/stream/worker_server.rb` reaches generated RPC code through `gems/tamoz-stream/lib/tamoz/stream/gen.rb:3-5`, which requires `grpc` and `google/protobuf`.
- The only SQLite source references to stream are the storage contracts in `gems/tamoz-sqlite/lib/tamoz/sqlite/artifact_store.rb:3-16` and `verification_store.rb:5-22`; the stores use `Tamoz::Stream::StreamError`, `Tamoz::Stream::VerificationStore::Row`, verdict/state constants, and its error type.
- In a clean SQLite require, `$LOADED_FEATURES` includes the gRPC C extension, many `google/protobuf` files, and the full stream worker/load surface.
- `tamoz-sqlite.gemspec:11-15` declares stream directly, so the package also inherits stream's gRPC/protobuf dependency footprint.
- `documentation/architecture/gems.md:82` says the persistence protocols are structural and SQLite implements them without a reverse dependency; the current direct stream dependency is therefore a meaningful implementation coupling.

Why it matters: consumers that only need SQLite persistence pay for and load the stream worker/RPC stack. It also makes the storage adapter depend on a runtime integration gem rather than a narrow contract package. This is a cohesion and load-time isolation concern, not proof that the current behavior is broken.

Recommendation: first measure whether lightweight SQLite consumers are a real supported use case. If yes, extract the narrow shared storage/notification/situation contracts and runtime JSON into a `tamoz-stream-contracts` gem, preserving the `Tamoz::Stream` namespace initially if that reduces migration risk. Make `tamoz-stream` depend on it and keep gRPC worker code in `tamoz-stream`; make SQLite depend on contracts instead of the worker gem. If no such consumer exists, the simpler choice is to document the intentional gRPC dependency and add a load-surface test rather than create a new gem.

Expected cost: high. `ArtifactStore` and `VerificationStore` are pinned public API (`test/public_api_test.rb:243,263` and `docs/public-api.json`), so the move requires API/require-path decisions, lockstep gemspec changes, package/isolation tests, stream/SQLite/evals/bin load-path updates, and architecture documentation. Do not execute this move without a measured consumer need.

### GB-06 — MCP websearch is a clean candidate for an adapter gem

Status: architecture candidate  
Severity: Medium  
Confidence: 0.95

Evidence:

- `gems/tamoz-mcp/lib/tamoz/mcp.rb:5-19` loads the MCP SDK, core, and MCP's core capabilities but does not load websearch.
- `gems/tamoz-mcp/lib/tamoz/mcp/websearch.rb:3-10` explicitly states that it is not required by `tamoz/mcp.rb`; only the operator script and tests load it.
- The websearch implementation is an HTTP egress/policy/circuit-breaker adapter under `gems/tamoz-mcp/lib/tamoz/mcp/websearch/`, four files and about 832 LOC, rather than an MCP protocol primitive.
- Production callers are `script/websearch_adapter` and the eval harness (`gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb:2001` and its websearch call sites). No main MCP entrypoint caller was found.
- `gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_policy.rb:9-14` calls out a deliberate websearch-side policy copy so MCP does not depend on agent.
- Existing adapter precedent is `tamoz-comms`/`tamoz-telegram` and `tamoz-observability`/`tamoz-otel`, both independently packaged with the optional integration isolated.

Why it matters: websearch has a distinct HTTP egress policy, client, circuit, and external-service lifecycle. Keeping it in the MCP gem increases the conceptual and release surface of the protocol adapter even though the main MCP require path is already isolated.

Recommendation: consider a new `tamoz-mcp-websearch` gem depending on `tamoz-mcp` and core. Preserve the `Tamoz::Mcp::Websearch` namespace initially; a namespace rename would create migration cost without improving the boundary. Update the operator script, eval harness, Gemfile, package tests, install documentation, and any public API decision. Because websearch is not pinned in the current public API manifest, the move is lower risk than moving `ArtifactStore` or `VerificationStore`.

Expected cost: medium: four files, two production consumers, gemspec/version wiring, package/isolation tests, and documentation. This is a recommendation for when independent installation or HTTP dependency isolation is valuable, not an urgent defect.

## Boundaries that should remain unchanged

The following were examined and have evidence for their current placement:

| Area | Decision and evidence |
|---|---|
| `tamoz-core` | Keep foundational. The isolation tests show it loads without graph, scheduler, stream, SQLite, agent, or `ruby_llm`; its gemspec has only Zeitwerk. |
| `tamoz-tools` and `tamoz-graph` | Keep separate and below agent. `test/dependency_isolation_test.rb:8-44` and packaging tests confirm core-only lower layers. No clean extraction target was found. |
| `tamoz-scheduler` | Keep as a core contract/adapter layer. It does not depend on agent, and its storage-facing API is consumed by SQLite. |
| `tamoz-stream` | Keep the worker/RPC implementation together for now. Fix package contents first; consider only the narrow contracts extraction in GB-05. Do not infer a move from enola's generated-surface signal. |
| `tamoz-comms` and `tamoz-telegram` | Keep split. Comms owns contracts; Telegram owns the optional transport. `documentation/design/comms.md:9-16` documents this two-gem design, and isolation tests show Telegram loads comms and `net/http` without graph/SQLite/agent/LLM. |
| `tamoz-observability` and `tamoz-otel` | Keep split. Observability owns the contract and OTEL owns the optional exporter. Isolation tests confirm the exporter separation. |
| `tamoz-sqlite` | Do not split by directory or file count now. Its checkpoint, effects, inbox, memory, schedule, and communication stores share connection, transaction, and adapter infrastructure. A future split would need transaction-preserving characterization tests. The only clear boundary issue is its stream worker load surface (GB-05). |
| `tamoz-agent` | Keep as the composition/runtime gem. It owns the domain orchestration, CLI, healing, memory, and model-facing behavior. It lazily loads SQLite, Telegram, and MCP-related paths at use sites; adding direct dependencies would reduce isolation. |
| `tamoz-mcp` core | Keep protocol support in MCP. Extract only the websearch adapter if independent packaging is justified (GB-06). |
| `tamoz-evals` | Keep outside the production dependency direction, but correct its declared/documented role. Do not split the harness until a real stdlib-only consumer exists. |
| `apps/tamoz-agent` | No application code is present; `app.json` points at `tamoz-agent`. There is no misplaced implementation to move. |
| `bin/` | The four entrypoints are composition/operational surfaces and correctly sit outside individual domain gems. `bin/tamoz-eval` is the expected consumer of the eval harness. |
| `script/` | The 32 scripts are repository tooling and operators, not reusable gem APIs. `script/websearch_adapter` would be updated if GB-06 is adopted. |
| `test/` and `test/support/` | These are workspace-level integration and packaging harnesses. They intentionally load all gem roots in `test/test_helper.rb:15-35`; isolated subprocess tests remain necessary to validate real package boundaries. |

No new gem is justified for the large `tamoz-agent` or `tamoz-sqlite` areas solely because they are large. Their code has domain cohesion and shared lifecycle/transaction seams; splitting without a concrete consumer would add public API and migration cost without evidence of a better boundary.

## Packaging and public API observations

All 13 gemspecs validate successfully and package metadata is structurally valid. The shared helper's file patterns are the important exception: it packages selected JSON directories but omits the stream runtime contract directory, producing GB-01.

The current public API pinning is useful evidence for move cost. `Tamoz::Stream::ArtifactStore` and `Tamoz::Stream::VerificationStore` are pinned in `test/public_api_test.rb` and `docs/public-api.json`. Any stream-contract extraction must preserve those constants or make an explicit, reviewed API break under the repository's no-backwards-compatibility policy. Websearch is not pinned in that manifest, so GB-06 has less API migration risk.

The root test process requires all 13 gems together. That is convenient for integration tests but can hide undeclared internal dependencies and accidental load-time coupling. The subprocess checks in `test/dependency_isolation_test.rb` and installed-package checks in `test/packaging_test.rb` are the appropriate boundary tests; their coverage should be extended for the specific gaps above.

## Recommended order of work

1. Fix the `tamoz-stream` package file list and add an installed-artifact notification-contract test (GB-01).
2. Decide the actual `tamoz-evals` contract; update its isolation test and contradictory docs, then declare graph/scheduler directly if the current harness remains (GB-02, GB-03).
3. Make dependency-review inventory all 13 gemspecs (GB-04).
4. Measure whether SQLite-without-gRPC is a supported consumer before considering `tamoz-stream-contracts` (GB-05).
5. Consider `tamoz-mcp-websearch` when independent HTTP dependency/release isolation has a concrete consumer or operational benefit (GB-06).

## Coverage and blind spots

### Component checklist

All 13 runtime gems were inventoried and their gemspecs, entrypoints, direct internal dependencies, relevant callers, package behavior, and isolation evidence were reviewed:

1. `tamoz-agent`
2. `tamoz-comms`
3. `tamoz-core`
4. `tamoz-evals`
5. `tamoz-graph`
6. `tamoz-mcp`
7. `tamoz-observability`
8. `tamoz-otel`
9. `tamoz-scheduler`
10. `tamoz-sqlite`
11. `tamoz-stream`
12. `tamoz-telegram`
13. `tamoz-tools`

Repository surfaces covered:

- `gems/`: 13 gem roots, 441 runtime Ruby files, approximately 78,127 lines of Ruby, plus the shared `gems/gemspec_helper.rb`.
- `apps/`: 2 files; manifest/README only.
- `bin/`: 4 executable entrypoints.
- `script/`: 32 scripts, including the dependency-review generator and websearch adapter.
- `test/`: 220 files, including 212 Ruby tests/support files and 8 fixture files.
- Relevant root/config/docs: `Gemfile`, `Gemfile.lock`, `Rakefile`, `.ruby-version`, gemspecs, `mcp-arch.yaml`, `docs/CODING_STANDARD.md`, `docs/QUALITY_PROGRAM.md`, `docs/DEPENDENCY_REVIEW.md`, public API files, architecture/design/install documentation, packaging and isolation tests.

### Blind spots

- Enola intentionally skips many docs/JSON/YAML files and most test-file parsing; those files were reviewed directly where they define package, contract, or architecture policy.
- The full CI suite was not run for this read-only boundary pass. Validation was targeted at gemspec loading, package file lists, clean require load surfaces, enola, dependency isolation, and the relevant static callers.
- Dynamic `require` behavior and runtime paths not exercised by the focused tests may contain additional coupling. The report identifies the dynamic paths found by search but does not claim exhaustive runtime execution of every CLI/operator mode.
- No `config/` directory exists in the repository; there was therefore no application config tree to audit.
- The working tree was already dirty with unrelated untracked documentation/audit directories. This audit added or updated only the assigned report.

## False positives and non-findings

- Enola's 0.40 cycle insight is below the configured 0.80 enforcement threshold and is a coupling-density heuristic, not a confirmed dependency cycle.
- The 35 exported symbols under `tamoz-stream/contracts` are generated protobuf/wire-contract surface. Export count alone is not evidence that the contracts belong in another gem.
- Lazy Telegram and MCP loads in `tamoz-agent` are intentional optional-adapter seams. Adding hard dependencies would worsen package isolation.
- The size of `tamoz-agent` and `tamoz-sqlite` is not, by itself, evidence for new gems. Their current domain and lifecycle cohesion outweighs a speculative split.
