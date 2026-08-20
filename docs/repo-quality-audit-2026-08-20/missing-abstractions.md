# Missing-abstractions audit

Date: 2026-08-20  
Repository: `/Users/ghassan/my-projects/tamoz`  
Audited ref: `sonnet-refactoring` / `1a61066` (`refactor(mcp): extract Tamoz::Mcp::BoundedText, dedup catalog/elicitation's text bounder`)  
Assigned focus: missing abstractions

## Executive summary

The repository has good deliberate seams around durable transactions, wire codecs, public value objects, and gem boundaries. The main abstraction debt is concentrated in policy-heavy orchestration, not in a lack of generic services or repositories.

I confirmed one high-priority design defect and one medium-priority production seam:

1. `Tamoz::Evals::Verifier` is both a public verification facade and the owner of three artifact-family semantic policies. Its evidence and result status validators repeat the same five-status decision structure with different inputs, and three methods exceed the repository's complexity targets. This is a high-confidence missing-abstraction defect in a release/evidence gate.
2. `Tamoz::Stream::EpisodeRunner` is co-located with `EpisodeRequestEnvelope` in an 857-line file and mixes boundary validation, context construction, durable delivery, artifact retention, journal-backed event projection, decision projection, and terminal cleanup. Its ordering must remain cohesive, but the isolated artifact and capability-host seams should be named and tested rather than remaining private method clusters.

The remaining findings are review candidates, not observed runtime defects. In particular, the repository already has explicit decisions to keep SQLite transaction cores, graph wire codecs, evaluation corpora, and public value objects cohesive. Splitting those would be harmful unless their contracts change.

## Method and evidence standard

I used:

- A complete `rg --files` inventory for `gems/`, `apps/`, `bin/`, `script/`, and `test/`, with per-gem file and LOC counts.
- Definition, branch/case, file-size, and repeated-responsibility sweeps across every production Ruby file.
- The Enola architecture snapshot, symbol exploration, impact analysis, and complexity insights.
- Direct reading of the candidate implementations and their callers/tests, including public API and packaging tests.
- The governing design documents: `AGENTS.md`, `docs/CODING_STANDARD.md`, `docs/QUALITY_PROGRAM.md`, `docs/QUALITY_PROGRAM_STATE.md`, architecture documents, `Rakefile`, `.rubocop.yml`, and `.reek.yml`.
- Focused tests and Ruby syntax checks. No production code or tests were changed.

Severity means the likely risk if the seam remains hard to change: High affects a correctness/security/evidence boundary; Medium affects maintainability and future contract drift; Low is a localized clarity or refactoring opportunity. Confidence is confidence that the abstraction boundary is real, not confidence that a production failure has already occurred.

## Findings

### MA-001 — Artifact-family semantic policy is missing from `Evals::Verifier`

Status: confirmed design defect; no current behavior failure observed  
Severity: High  
Confidence: 0.98

#### Evidence

- `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:39-67` exposes one `verify` pipeline that reads the artifact, validates references and digests, dispatches semantics, and constructs the public `Verification` value.
- `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:153-188` dispatches case, evidence, and result semantics from one class. The result branch also performs result-specific reference, score, provenance, and timing checks.
- `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:325-379` implements five status cases for evidence (`passed`, `failed`, `invalid`, `infrastructure_error`, `insufficient_evidence`).
- `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:473-525` implements the same five status cases for results. The positive/negative collections differ (`claims` versus `hard_gates`), as do the exact contract messages, but the status partition and diagnostic exclusivity rules are structurally duplicated.
- Enola reported cyclomatic complexity 21 for `verify_provenance!`, 19 for `verify_evidence_status!`, 18 for `verify_decision_evidence!`, and 16 for `verify_evidence_process!`.
- The public path is used by `gems/tamoz-evals/lib/tamoz/evals.rb:62-63`, the evaluation CLI, and the `Case`, `Evidence`, and `Result` convenience surfaces. Coverage callers include `test/evals_verifier_test.rb`, `test/evidence_artifact_test.rb`, `test/m1_evidence_test.rb`, `test/m2_evidence_test.rb`, and `test/release_evaluation_manifest_test.rb`.

#### Why it matters

The class has a valid shared pipeline, but semantic ownership is not represented in the design. A new status, diagnostic category, or evidence invariant requires coordinated edits in multiple branches. The duplicated status matrices can drift silently: evidence may accept a combination that result rejects, or the two surfaces may develop inconsistent “insufficient” semantics. High-branch methods are also harder to mutation-test at the exact contract boundary.

The five statuses are not identical enough for a generic status DSL. The evidence path reasons over claims and process evidence; the result path reasons over hard gates and referenced evidence. The missing abstraction is therefore the two semantic policies, not a universal “status handler.”

#### Five Whys

1. `Verifier` is difficult to change because file access, digest/reference checks, and artifact semantics live in one class.
2. Artifact semantics live there because the original public API needed one verification entry point.
3. Case, evidence, and result rules then accumulated behind that entry point without separate owners.
4. The repeated five-status policy was kept as method-local branching rather than an explicit semantic boundary.
5. There is no named artifact-family policy abstraction to make the shared facade thin and the divergent rules independently testable.

#### Recommendation

Keep `Tamoz::Evals::Verifier#verify` and the existing `Verification = Data.define(...)` public value unchanged. Extract isolated, schema-specific semantic owners behind the current facade:

- `CaseSemantics` for case-only rules.
- `EvidenceSemantics` for claims, measurements, process, timing, provenance, and evidence status.
- `ResultSemantics` for hard gates, score/reference linkage, provenance, and result status.

Each owner can be a small class or module in its own file with a narrow `verify!`/`decision` API. This qualifies as an isolated responsibility under the coding standard even though each currently has one direct caller. Keep the already-shared `assert_unique_ids!`, file reader, digest verification, and reference loader at the facade or in a narrowly named shared verifier utility. Do not introduce a generic `StatusPolicy` DSL or a base verifier: the input collections and error contracts are intentionally different.

Before extraction, add characterization assertions for every status and for the exact exception class/message contract that the existing tests pin. Add mutation checks that independently break each evidence and result status branch. Run the evaluation evidence suites, `rake ci`, RuboCop, Reek, and Enola after the slice. No compatibility branch or legacy tolerance should be added.

### MA-002 — The stream runner has unnamed boundary abstractions inside an ordering-critical method

Status: confirmed missing seam; no current behavior failure observed  
Severity: Medium  
Confidence: 0.96

#### Evidence

- `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:38-304` defines the public `EpisodeRequestEnvelope`.
- The same file defines the public `EpisodeRunner` at `:312-857`. The file therefore contains two public classes and two distinct responsibilities despite the one-class/module-per-file standard.
- `EpisodeRunner#run` at `:333-463` validates the envelope and verified snapshot, checks tenant/situation identity, constructs `EpisodeStream` and `Tamoz::Context`, creates a capability host, delivers to the durable graph, reads the checkpoint, builds and retains artifacts, verifies journal-backed model events, opens verification rows, translates the terminal decision, and guarantees one typed terminal in both rescue paths.
- `build_artifact_manifest` at `:676-696`, `retain_manifest_artifacts` at `:709-738`, and `verify_manifest_digest!` at `:744-759` form a distinct artifact-manifest/retention protocol.
- `build_capability_host` at `:788-822` is a separate capability-host factory that chooses unavailable adapters versus evidence-tool adapters and applies the tighter result cap.
- `EpisodeRequestEnvelope#validate!` at `:202-277` is itself a complete wire-boundary contract: identity/fence, catalog requirements, budgets, tracing headers, kind/lane/risk checks. It should not be merged into the runner.
- The public callers are `test/stream_episode_fixed_graph_test.rb:49`, `test/stream_episode_crash_matrix_test.rb:119`, `test/stream_invariants_test.rb:44,84`, `test/stream_episode_real_model_test.rb:74`, and `test/support/episode_composition.rb:97`. Public surface and packaging coverage is in `test/public_api_test.rb`, `test/packaging_test.rb`, and `documentation/reference/public-api.md`.

#### Why it matters

The runner is necessarily an orchestrator, and its event ordering is safety-critical: artifact retention must precede model-event emission, journal receipts must be checked before projection, and exactly one terminal must be emitted. That is a reason to preserve the core ordering, not a reason to leave every boundary policy as private method clusters. Artifact retention, capability-host construction, fallback identity, and wire-envelope validation have separate change/test axes. Without named seams, a change to one can accidentally alter the durable-delivery or terminal path.

#### Recommendation

Make the file boundary first: move `EpisodeRequestEnvelope` to `episode_request_envelope.rb` and `EpisodeRunner` to `episode_runner.rb`, preserving constant paths, requires, public API documentation, and load-order tests.

Then extract only cohesive, isolated objects:

- An artifact-manifest assembler/retainer boundary for the `:676-759` protocol. Keep the exact digest verification and “retain before emit” ordering visible from `run`.
- A capability-host factory for `:788-822`, with the unavailable-adapter and evidence-client paths covered independently.
- A named immutable episode identity value for the fallback stream construction currently produced by `identity_for`, rather than creating an ad hoc `Struct` at runtime.

Do not extract `run` into a generic workflow framework, hide the durable barrier in middleware, or split the terminal rescue/ensure sequence into callbacks. Add characterization tests for event ordering, retention failure, journal mismatch, and exactly-one-terminal behavior before moving code. Run the stream crash matrix, artifact manifest, fixed-graph, invariants, worker, packaging, and public API tests; the real-model suite must remain clearly labeled as real-model evidence.

### MA-003 — Canonicalization and immutability need an explicit contract map, not one universal abstraction

Status: review candidate / architecture gap, not a confirmed defect  
Severity: Medium  
Confidence: 0.95

#### Evidence

There are several independently named implementations of conceptually related responsibilities:

- `gems/tamoz-core/lib/tamoz/core.rb:69-158` owns general key sorting, RFC 8785/JCS bytes and digests, digest normalization, and a copy-and-freeze JSON-shaped value.
- `gems/tamoz-comms/lib/tamoz/comms/canonical.rb:8-59` owns a channel-specific scalar encoder that supports `Time`, uses a custom delimiter format, and returns an unprefixed SHA-256 hex digest. It is public and used by delivery, approval, and agent comms gateway/drainer code.
- `gems/tamoz-evals/lib/tamoz/evals/canonical_json.rb:8-82` owns versioned evidence-artifact canonical JSON: string-only keys, NFC normalization, no floating point, a depth limit, and an eval-specific digest prefix/domain.
- `gems/tamoz-evals/lib/tamoz/evals/deep_freeze.rb:5-17`, `gems/tamoz-mcp/lib/tamoz/mcp/canonical_json.rb:23-...`, `gems/tamoz-agent/lib/tamoz/agent/mcp_capability_source.rb:249-...`, `gems/tamoz-observability/lib/tamoz/observability/content_policy.rb:104-...`, and `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb:594-...` each implement related normalization/freezing/canonicalization behavior for different trust or evidence boundaries.
- The public API test explicitly exposes both `Tamoz::Core.canonical` and `Tamoz::Comms::Canonical` (`test/public_api_test.rb:34,50,91`), and evaluation artifact tests pin `Tamoz::Evals::CanonicalJSON`.

#### Why it matters

The risk is not that every implementation should be merged. The formats are observably different and some differences are intentional wire contracts. The risk is that a future caller sees “canonical” and chooses the wrong authority, or a new implementation is added without stating which contract it satisfies. This is a missing contract-level abstraction/registry rather than a request for a common base class.

#### Recommendation

Create a small contract matrix in the relevant architecture/evidence documentation and tests. For each authority, state accepted types, mutation/copy behavior, Unicode/float/Time rules, digest prefix/domain, and permitted consumers:

- New durable JSON/replay values should use `Tamoz::Core.jcs`/`digest` unless they are explicitly an eval artifact or comms wire contract.
- Keep `Tamoz::Comms::Canonical` and `Tamoz::Evals::CanonicalJSON` separate; do not create a generic `Canonicalizer` or replace one with the other without a deliberate wire-format decision.
- Add contract tests for intentional non-equivalence and route new code through a named authority. Only consolidate a freezer or primitive after proving that its copy/mutation and unsupported-value behavior are identical at all callers.

This recommendation belongs partly to the duplication pass; this report records the missing ownership/contract abstraction and deliberately does not claim that the existing format differences are defects.

### MA-004 — `Deliberation.structural_issues` contains three policy phases without named seams

Status: review candidate  
Severity: Medium  
Confidence: 0.99

#### Evidence

- `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb:186-238` accumulates plan-level issues at `:188-191`, per-step shape/tool/argument issues at `:192-225`, and action/repair ordering rules at `:227-236`.
- Enola reports cyclomatic complexity 21 for `Tamoz::Agent::Deliberation.structural_issues`.
- Enola impact analysis found 22 transitive dependents within two hops, including `Runtime`, session routing/planning, MCP capability validation, and five test references.
- Direct callers include `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:531-532`, `session_routing.rb:84`, `session_plan_attempt.rb:121`, and `test/agent_mcp_capability_source_test.rb:552,566`.

#### Why it matters

The method is pure and its behavior is coherent, but the accumulator makes three independent policy families look like one growing branch. A future plan rule can be added to the wrong phase or change the ordering of issue messages, which is observable feedback to the model and tests.

#### Recommendation

Start with three named pure methods—`plan_level_issues`, `step_issues`, and `ordering_issues`—and concatenate their frozen results in the existing order. If a second plan validator or a richer policy object appears, promote those phases to a narrow `PlanStructurePolicy` value/validator. Do not table-drive the rules or introduce a generic validation framework: the checks have different inputs and failure semantics. Characterize issue order and preserve the existing capability-dispatch seam.

### MA-005 — `SessionRecords.load!` mixes durable shape loading, upgrade, defaults, and security rejection

Status: review candidate; current cohesion is defensible  
Severity: Medium  
Confidence: 0.93

#### Evidence

- `gems/tamoz-agent/lib/tamoz/agent/session_records.rb:275-351` performs root/kind/version validation, a migration loop at `:301-312`, session legacy-default filling at `:318-346`, schema validation, sensitive-value rejection, and credential scanning.
- The schema family itself is declared at `:32-233`, and `load_state!`, `reject_sensitive!`, `reject_credential_values!`, `validate_fields!`, and `check_type!` follow at `:354-...`.
- Callers include `session_plan_attempt.rb`, `session_plan_outcomes.rb`, session resume paths, and legacy/session healing tests such as `test/healing_failure_contract_test.rb:568-602`.
- `docs/QUALITY_PROGRAM_STATE.md:271` currently classifies this as a cohesive session-record family to keep for now.

#### Why it matters

The method has four distinct reason-to-fail phases. As another record kind or explicit schema version arrives, migration/default logic can become entangled with security validation. The risk is especially high because rejection order is load-bearing: newer unsupported versions must fail before fields are inspected.

#### Recommendation

Do not add new compatibility behavior. Keep the current durable record boundary and its rejection ordering. If the next schema change materially expands `MIGRATIONS`, extract a private `SessionRecordUpgrade`/`SessionDefaults` responsibility with tests that prove: version rejection precedes field access; defaults are applied only to the session kind; security scans occur after the final shape is established. Do not split each validator into generic schema services or alter the existing legacy sentinel semantics.

### MA-006 — Evaluation memory measurement is an untyped report assembled by a long boolean expression

Status: review candidate; evaluation-only  
Severity: Low  
Confidence: 0.97

#### Evidence

- `gems/tamoz-evals/lib/tamoz/evals/harness/memory_cell.rb:87-142` gathers captures, event IDs, audit counts, and expected deltas; computes a ten-term `correct` expression at `:100-110`; then builds a 29-key raw hash at `:112-141`.
- `MemoryCell#run` at `:40-49` treats this hash as the stable measurement returned from a case/treatment cell.
- Callers and coverage include `gems/tamoz-evals/lib/tamoz/evals/harness/memory_treatment_profile.rb:127` and `test/memory_treatment_profile_test.rb:200-256`.

#### Why it matters

The measurement is a stable internal protocol, but the raw hash and conjunction make it easy to add a field without updating the correctness explanation or to confuse “not run,” “crashed,” and “incorrect.” This is not production runtime risk, but it affects evidence quality and harness maintenance.

#### Recommendation

Introduce an internal `Measurement = Data.define(...)` only if its field set is stable across the memory corpus. Otherwise first extract named predicates such as `injection_matches?`, `store_is_unchanged?`, and `audit_is_clean?`, preserving the existing output keys and freeze behavior. Keep corpus/domain knowledge in the JSON fixtures and do not move expected deltas into Ruby policy.

### MA-007 — Subprocess child termination is a state machine without a named lifecycle policy

Status: review candidate; current cohesion is defensible  
Severity: Medium  
Confidence: 0.92

#### Evidence

- `gems/tamoz-evals/lib/tamoz/evals/harness/subprocess_runner.rb:151-213` owns process creation, pipe capture, child waiting, reader draining, result construction, and failure cleanup.
- `wait_for_child` at `:255-...` polls for exit/stop, invokes intervention, validates the intervention return, escalates KILL, and handles TERM/KILL timeout paths.
- `Stream` and `Result` are already appropriate `Data.define` values at `:23-71`; the missing seam is the child-lifecycle decision, not another result wrapper.
- Callers include `test/subprocess_runner_test.rb`, `test/sqlite_scenario_driver_test.rb:583`, and selector-control tests.
- `docs/QUALITY_PROGRAM_STATE.md:261` deliberately defers this file because process/error semantics are tightly coupled.

#### Why it matters

Intervention, timeout, and escalation are distinct transitions with safety-sensitive ordering. Keeping them as anonymous branches makes it harder to audit the transition matrix and to test each path independently.

#### Recommendation

If this harness changes, extract a small `ChildTermination` decision/value or lifecycle collaborator that owns only the transition decision; keep `Process.waitpid2`, signals, grace periods, and reaping visible in the runner. Characterize ordinary exit, stop/intervention, TERM success, TERM escalation, and missing-child races before moving code. Do not create a general process manager or callback framework.

### MA-008 — `Toolbox#execute` is a narrow dispatch-table candidate, not a generic command abstraction

Status: low-priority review candidate  
Severity: Low  
Confidence: 0.88

#### Evidence

- `gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:118-132` normalizes and validates, then dispatches `read_file`, `list_files`, `search`, `apply_patch`, `run_check`, `create_file`, and skill/resource operations through a branch chain.
- The same class already composes named collaborators at `:49-76`, and `effect_intent`/`preview` at `:134-167` intentionally expose operation-specific authority and payload shapes.
- `docs/QUALITY_PROGRAM_STATE.md:241` identifies the toolbox as an authority-bearing dispatch hotspot and records a completed `CheckReceipt` extraction.

#### Why it matters

The execute branches are uniform enough that adding another operation can require edits in several methods. However, the operation-specific effect intent and preview logic must not be erased behind a uniform command object.

#### Recommendation

If another operation is added, use a static, explicit operation-to-executor map for the uniform `execute` delegation only. Keep validation, effect intent, preview, and receipt construction explicit. Do not introduce a metaprogrammed command registry, plugin framework, or generic `ToolManager`; the existing facade and named operation collaborators are the right boundary.

### MA-009 — Schedule claiming has internal policy phases, but the transaction must remain one unit

Status: review candidate with explicit keep-together constraint  
Severity: Medium  
Confidence: 0.95

#### Evidence

- `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:271-368` intersects grants, resolves the request template, selects due/misfire occurrences, reads overlap state, records skips/coalesces, and enqueues materialized occurrences.
- The method is called from `materialize_due` at `:224-266` inside the caller's transaction. Its comments explicitly tie grant, misfire, overlap, and durable occurrence semantics together.
- The public storage contract is `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:17-...`; coverage is in `test/sqlite_schedule_store_test.rb` and `test/agent_scorecard_test.rb:338`.
- `docs/QUALITY_PROGRAM_STATE.md:248` classifies this as a durable transaction boundary to defer.

#### Why it matters

There are recognizable pure decisions inside the method, but moving writes or state reads into separate objects can obscure the consistency boundary and reintroduce process-local scheduling decisions. The abstraction risk is larger than the line-count benefit today.

#### Recommendation

Keep the transaction and occurrence loop together. If future policy growth makes review difficult, extract only a pure `ClaimDecision`/policy calculation that receives an immutable schedule snapshot and returns materialize/skip/coalesce decisions; leave all durable reads/writes and enqueue ordering in `ScheduleStore`. Never wrap this in a generic repository or hide the transaction in middleware.

## Explicit non-findings and harmful abstractions to avoid

These areas were examined and should not be reported as missing abstractions merely because they are large, have many parameters, or have a high fan-in score.

| Area | Evidence and decision |
|---|---|
| `Tamoz::Core` and `Tamoz::Core.canonical` | `gems/tamoz-core/lib/tamoz/core.rb:66-158` is the intentional shared kernel for canonical/JCS/digest/freeze primitives. Enola's high fan-in is expected ownership, not a god-class defect. Do not add another “common utilities” layer. |
| `Tamoz::Context` | `gems/tamoz-core/lib/tamoz/context.rb:20-87` is one immutable execution-context contract with `with`/`child` at `:89-106`. Its identity, lifecycle, collaborators, and cancellation semantics are deliberately carried together. A nested identity value would add ceremony without a second consumer. |
| Comms `Delivery` and `SurfaceDescriptor` | `gems/tamoz-comms/lib/tamoz/comms/delivery.rb:1-170` and `surface_descriptor.rb:1-275` are persisted/wire value contracts. Their comments and validation phases explain why the whole value remains together. Splitting field fragments would obscure serialization and identity. |
| Comms `Admission` | `gems/tamoz-comms/lib/tamoz/comms/admission.rb:27-133` is a deterministic decision table. Its branch count is policy data, not a missing strategy hierarchy. |
| SQLite checkpoint/effect/adapter stores | `checkpoint_store.rb`, `effect_journal.rb`, and `adapter.rb` are explicit transaction/composition boundaries. The quality state documents them as cohesive exceptions. Generic repositories or hidden transaction objects would violate `AGENTS.md`. |
| Graph compiler/executor/compiled/checkpoint codec | Compilation, execution, checkpoint reconstruction, and wire/digest encoding have different contracts, but the codec and execution ordering are intentionally held at their boundaries. Do not extract methods merely to satisfy LOC thresholds. |
| `SQLite::BoundarySourceAudit` | `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb:594-...` is one private audit unit with private constants and one public entry point. The quality state explicitly rejected a file-only split. |
| `Tamoz::Evals` corpora and scenario registries | `agent_smoke_corpus.rb`, `agent_memory_corpus.rb`, `sqlite_scenario_registry.rb`, and related harness data are declarative/evidence fixtures, not ordinary production classes. Moving domain data into Ruby abstractions would violate the JSON-only domain-data rule. |
| `Tamoz::Core::JCS` dispatch | `gems/tamoz-core/lib/tamoz/core/jcs.rb` type dispatch is codec logic. Extracting a class per JSON type would increase machinery without reducing a boundary risk. |
| MCP invocation/supervisor and stream event adapters | `mcp/invocation.rb`, `mcp/supervisor.rb`, `stream/episode_stream.rb`, and `stream/episode_worker.rb` contain wire/effect/concurrency ordering. Their apparent mixed responsibilities are trust-boundary behavior; any extraction needs a contract-first slice and must not hide ordering. |
| Skills and healing nested values | The current branch already extracted skills value families and healing classification/protocol collaborators. Adding another generic policy layer would duplicate the completed Q3 work. |
| Websearch gem placement | `tamoz-mcp` websearch is a self-contained optional integration candidate for the separate gem-extraction pass. That is a placement question, not evidence that this missing-abstractions pass should add an integration framework. |

## Recommended order of work

1. Characterize and extract the three `Evals::Verifier` semantic owners. This is the clearest high-risk seam and has focused tests already.
2. Split `situation_request.rb` into its two public class files without changing constants or behavior; then isolate only the artifact and capability-host protocols after event-order characterization.
3. Add the canonicalization contract matrix and negative conformance tests before touching any implementation. This prevents a well-intended deduplication from changing a wire digest.
4. Extract named pure phases from `Deliberation.structural_issues` when the next plan-rule change provides a natural slice.
5. Revisit `SessionRecords`, subprocess lifecycle, schedule claiming, and the memory measurement only when their respective protocol grows; their current cohesive boundaries are safer than speculative decomposition.

Every production extraction should follow the repository program: characterize first, keep durable barriers visible, preserve public constants and error bytes, add behavior/failure-path tests, run changed-line coverage and mutation checks, then run RuboCop, Reek, Enola, and the applicable `rake ci` slice.

## Coverage and blind spots

### Repository inventory

All 13 gem `lib/` trees were enumerated and included in the structural sweep. Counts below are current at the audited ref.

| Component | Ruby files | LOC | Coverage notes |
|---|---:|---:|---|
| `tamoz-agent` | 128 | 25,615 | Runtime/worker/session graph, CLI, profile, memory, healing, improvement, MCP and comms adapters; hotspot callers traced. |
| `tamoz-comms` | 22 | 2,339 | Channel values, admission, rendering, transports, stores, and public contracts. |
| `tamoz-core` | 30 | 4,623 | Context, immutable values, JCS/digests, codecs, pool, circuit, errors, and shared boundary helpers. |
| `tamoz-evals` | 44 | 12,431 | Verifier, evidence/case/result APIs, subprocess harness, memory harness, SQLite harness, and declarative corpora. |
| `tamoz-graph` | 48 | 5,516 | Compiler, compiled graph, executor, checkpoint codec, reducers, replay, subgraphs, and memory checkpointer. |
| `tamoz-mcp` | 17 | 3,407 | Catalog/configuration, invocation, supervisor, elicitation, websearch, and canonical JSON helpers. |
| `tamoz-observability` | 18 | 1,869 | Content policy, catalog, correlation, recorders, metrics, traces, and signals. |
| `tamoz-otel` | 5 | 418 | OTEL exporter/resource adapters. |
| `tamoz-scheduler` | 8 | 927 | Schedule values, recurrence/misfire/overlap policy, grants, and store contract. |
| `tamoz-sqlite` | 67 | 13,350 | Adapter/store, checkpoints, request inbox, leases, effect journal, schedules, comms, stream, memory, migrations, backup, and boundary audits. |
| `tamoz-stream` | 25 | 4,237 | Worker, episode request/envelope/runner, stream projection, decisions, evidence, artifacts, replay, and reconsideration. |
| `tamoz-telegram` | 5 | 371 | Telegram transport and normalization adapter. |
| `tamoz-tools` | 24 | 3,024 | Toolbox facade, capability host, path/read/search/patch/check operations, skills, and receipts. |
| **Gem total** | **441** | **78,184** | `gems/gemspec_helper.rb` is outside the gem `lib/` totals and has no Ruby `lib` files. |

Additional in-scope areas:

- `apps/`: 2 files (`tamoz-agent/README.md`, `tamoz-agent/app.json`); application metadata only, no Ruby implementation.
- `bin/`: 4 entrypoints (`tamoz-eval`, stream subscriber/worker/learning worker); checked as thin entrypoint/composition surfaces.
- `script/`: 32 files, including 3 `.rb` files and executable extensionless generators, conformance drivers, benchmark/release tools, fixture generators, the SQLite oracle, and websearch adapter. These were classified as tooling/oracle/generator code rather than production gem abstractions.
- `test/`: 218 files, 212 Ruby files, 59,774 Ruby LOC. The full area inventory covered agent, comms, core, evals, graph, MCP, observability/OTEL, scheduler, SQLite, stream, Telegram, subprocess, packaging, public API, dependency isolation, and quality-gate tests. Relevant caller tests are named with each finding.
- Configuration and documentation reviewed: `AGENTS.md`, `README.md`, all gemspecs, `Gemfile`, `Rakefile`, `.rubocop.yml`, `.reek.yml`, `docs/CODING_STANDARD.md`, `docs/QUALITY_PROGRAM.md`, `docs/QUALITY_PROGRAM_STATE.md`, `docs/repo-quality-audit-2026-08-20/README.md`, architecture/gem dependency docs, data/invariant/security docs, `documentation/reference/public-api.md`, and the stream implementation plan.

### Architecture tooling and test results

- Fresh Enola snapshot: 9,659 facts, 52 insights, 537 files seen, 495 parsed, 599 skipped, 9 skipped directories, and 0 parse errors. The snapshot included Ruby/gRPC extractors and was used for hotspot, complexity, symbol, and impact analysis.
- Enola identified 25 god-class candidates, 15 complexity outliers, one low-confidence coupled-module cycle, and no layer findings. These were treated as triage signals and verified against source/callers; the cycle was not promoted because the explainer itself identifies Ruby autoloading as a likely explanation.
- The Enola shell CLI was unavailable, so the MCP architecture server was used for snapshot/explore/impact work. Tests/docs/config were outside the source snapshot's parsed scope and were separately inventoried/read.
- With the pinned Ruby 3.3.11 selected through rbenv, all `.rb` files under `gems/`, `test/`, and `script/` passed `ruby -cw` syntax checks (`syntax_failures=0`). The system Ruby was 2.6 and could not parse the repository's Ruby syntax; it was not used for conclusions.
- Focused semantic tests passed: `test/evals_verifier_test.rb`, `test/stream_situation_request_test.rb`, and `test/agent_session_records_test.rb`: 23 runs, 294 assertions, 0 failures.
- Focused boundary tests passed: `test/sqlite_schedule_store_test.rb`, `test/subprocess_runner_test.rb`, `test/agent_mcp_capability_source_test.rb`, and `test/core_context_test.rb`: 19 runs, 67 assertions, 0 failures.
- `test/stream_artifact_manifest_test.rb` was attempted but its local fixture endpoint could not bind `127.0.0.1:0` under the sandbox (`Errno::EPERM`). This is an environment blind spot; it is not counted as a pass or a code failure.

### Remaining blind spots

The inventory and architecture sweeps covered every in-scope file, but not every line was manually read line-by-line across the 78,184 production LOC and 59,774 test LOC. The residual risk is a file-local missing seam that produces no size, branch, fan-in, caller, or contract signal. Generated/declarative corpora and extensionless scripts received ownership/classification review rather than exhaustive semantic refactoring review. No finding above relies solely on those blind areas.

The working tree was already dirty with untracked study/audit directories. No tracked production or test files were changed, and this audit writes only the assigned report.
