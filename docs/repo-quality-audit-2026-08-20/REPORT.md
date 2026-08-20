# Tamoz repository quality audit — consolidated report

Date: 2026-08-20  
Branch: `sonnet-refactoring`  
HEAD: `1a61066`  
Mode: read-only analysis; no production or test code changed.

## Audit status

The seven requested quality dimensions are complete for the current checkout.
Six passes were delegated to sub-agents. The patterns pass was completed in the
main thread because six sub-agent slots were available. Each pass covered all
13 gems plus `apps/`, `bin/`, `script/`, `test/`, gemspecs, configuration,
quality artifacts, and relevant architecture documentation. Each report records
its method, evidence, confidence, component checklist, and blind spots.

Reports:

1. [Code quality](code-quality.md)
2. [Duplication](duplication.md)
3. [Dead code and unreachable surfaces](dead-code.md)
4. [Missing abstractions](missing-abstractions.md)
5. [Incorrect use of existing code](incorrect-existing-usage.md)
6. [Gem boundaries and placement](gem-boundaries.md)
7. [Patterns and pattern usage](patterns.md)

## Executive verdict

Tamoz has a strong architectural direction. Layer enforcement passes, the
effect journal exists, package-isolation tests exist, capability boundaries are
explicit, and recent refactors have reduced duplication without adding broad
framework machinery.

The repository is not currently a trustworthy green quality gate. The highest
risks are control-plane and boundary defects, not generic style debt:

| Priority | Finding | Why it matters |
|---|---|---|
| P1 | MCP ambiguous outcomes can escape journal completion as `EffectUnknownError`. | A non-idempotent effect may remain running instead of being recorded as terminal `unknown`. |
| P1 | `tamoz-agent` directly requires the stream situation-recall contract. | Standalone agent package loading fails and the dependency-inversion boundary is false. |
| P1 | `tamoz-evals` has a runtime-coupled entrypoint but is documented/tested as stdlib-only. | The executable architecture contract and package role disagree. |
| P1 | Memory consolidation calls the model outside `EffectDispatcher`. | Replay or crash recovery can issue a fresh non-deterministic result. |
| P2 | The stream runtime contract JSON is absent from the packaged gem. | The checkout works while an installed `tamoz-stream` can fail in notification flows. |
| P2 | Benchmark/domain generated artifacts are stale; `cold-chain` cannot resolve. | The data-driven benchmark path is unreachable and protocol artifacts diverge. |
| P2 | Quality baselines and generated inventories are stale. | Static debt, deleted paths, and coverage no longer describe the current tree. |
| P2 | CI does not run the declared RuboCop, Reek, coverage, and baseline gates. | A green CI result does not mean the quality program is satisfied. |

No P0 finding was established. The P1 items should be resolved before broad
refactoring of large files or introducing new gems.

## Repository coverage

The audit covered:

- 13 runtime gems: `tamoz-agent`, `tamoz-comms`, `tamoz-core`, `tamoz-evals`,
  `tamoz-graph`, `tamoz-mcp`, `tamoz-observability`, `tamoz-otel`,
  `tamoz-scheduler`, `tamoz-sqlite`, `tamoz-stream`, `tamoz-telegram`, and
  `tamoz-tools`;
- approximately 441 Ruby library files under `gems/`, 220 test files (212 Ruby),
  4 `bin/` entrypoints, 32 `script/` files, and the two `apps/` files;
- gemspecs, dependency tests, packaging tests, public API manifests, quality
  baselines, Rake tasks, CI workflow, generated requirements, fixtures, and
  architecture/design documents;
- Enola snapshot: 537 files seen, 495 parsed, 0 parse errors, 9,659 facts, and
  52 heuristic insights.

The Enola gate passed:

```text
enola check --fail-on=cycles,layers --min-confidence=0.8 .
PASS — no architectural change
```

Its one cycle insight has confidence 0.40 and is a coupling-density heuristic,
not a confirmed dependency cycle. No layer violation was reported.

## Confirmed findings by dimension

### Code quality

The current configured RuboCop run reports 10,011 offenses across 708 files;
the current Reek run reports 4,950 smells across 286 files. These totals include
large amounts of existing style and test debt, but they establish that the
current raw gate is red. The committed baseline records an older commit and
cannot be used as a current-tree ledger.

`rake ci` and `ci_full` do not invoke all declared quality tasks. The GitHub
workflow runs `bundle exec rake ci`, which omits RuboCop, Reek, coverage, and
baseline drift. The baseline generator also discards RuboCop subprocess status,
so a cache or infrastructure failure can be recorded as zero inspected files.

Coverage in the committed baseline is 89.45% line and 69.22% branch, below the
declared 90%/80% target. Subprocess and killed-child coverage collation is still
deferred. See [code-quality.md](code-quality.md) for exact Rakefile, workflow,
baseline, and tool output evidence.

### Duplication

No confirmed behavior defect was caused by duplication. The highest-value
duplication findings are protocol-sensitive and should not be flattened into a
generic helper without byte-level tests:

- Evals and MCP canonical JSON walkers look similar but intentionally differ on
  floats, key handling, invalid strings, and digest semantics.
- Agent and MCP egress/security policy declarations are duplicated to preserve
  gem isolation.
- Three Comms wire-time decoders and three Evals artifact loaders are small,
  high-confidence maintenance extractions.
- Two agent-memory fixture generators share an envelope and should become a
  parameterized generator only if their corpus-specific data stays explicit.
- MCP byte truncation is only partly centralized.

Recent extractions of `BoundedText`, MCP canonical freezing, CLI dispatch, and
Evals action lookup are positive examples of the repository's preferred
incremental deduplication style. See [duplication.md](duplication.md).

### Dead code and stale surfaces

Three dead/unreachable surfaces are confirmed:

1. `bin/tamoz-stream-worker-learning` is a committed executable that only
   aborts with a retirement message and has no caller, test, task, or deployment
   reference.
2. Generated quality and requirements artifacts contain deleted or renamed
   paths, including old stream files and `test/memory_repository_test.rb` after
   the `MemoryStore` rename.
3. `test/fixtures/domains/cold-chain.json` is discovered by the generic loader
   but fails `Object.const_get("Cold-chainDomain")`, so the data-driven benchmark
   branch cannot execute.

The report also identifies stale P14/P15 documentation as a review candidate,
not executable dead code. No unused runtime dependency or uncalled gRPC route
was confirmed. See [dead-code.md](dead-code.md).

### Missing abstractions

The main missing seams are:

- artifact-family semantic policies inside `Tamoz::Evals::Verifier`;
- stream episode envelope, runner, artifact-retention, and capability-host
  boundaries in `situation_request.rb`;
- an explicit ownership map for multiple canonicalization/immutability
  contracts;
- named policy phases for `Deliberation.structural_issues`;
- a future session-record upgrade seam if the schema grows;
- a child-lifecycle decision seam in the eval subprocess runner.

These are targeted seams, not a reason to create generic service objects,
callback frameworks, or repository bases. The missing-abstraction report
classifies which are confirmed design gaps versus review candidates.

### Incorrect use of existing code

Four confirmed contract/lifecycle problems were found:

- MCP source preflight omits `descriptors` and `descriptor_for`, although later
  session code calls both.
- `ScheduleStore`, SQLite's schedule adapter, and their clients disagree on
  keyword arguments and lifecycle methods.
- MCP `AmbiguousOutcomeError` is mapped to `Tamoz::EffectUnknownError`, which
  is not handled by the synchronous `EffectDispatcher` rescue path; the started
  attempt is not completed as `unknown`.
- `tamoz-evals` eagerly loads runtime packages despite its documented stdlib-only
  contract.

Two review candidates are also important: healing defaults to an in-memory
circuit rather than the existing durable circuit seam, and agent memory
constructs a concrete SQLite implementation where the design describes a
storage port. See [incorrect-existing-usage.md](incorrect-existing-usage.md).

### Gem placement and boundaries

The lower-level dependency direction is generally sound. No new gem is justified
merely because `tamoz-agent` or `tamoz-sqlite` is large.

Confirmed packaging/metadata problems:

- `tamoz-stream` reads `contracts/notification-contract-v1.json` at runtime,
  but the shared gemspec file list does not include `contracts/**`.
- `tamoz-evals` declares core, agent, SQLite, and MCP dependencies and eagerly
  loads them, while root docs and dependency-isolation tests say it is stdlib-
  only. It also directly uses graph/scheduler APIs without declaring them.
- The dependency-review generator inventories only nine of the 13 gemspecs.

Two extraction candidates have evidence but are not urgent: a narrow stream
contracts gem if SQLite-without-gRPC is a real consumer, and a separate
`tamoz-mcp-websearch` adapter if independent HTTP/release isolation is valuable.
The simple current recommendation is to fix packaging and contract truth first.
See [gem-boundaries.md](gem-boundaries.md).

### Patterns

The correct patterns already in use are:

- `EffectDispatcher`/`SessionEffects` for durable non-deterministic work;
- injected ports and adapters for schedule, stream, effects, stores, comms, and
  observability;
- closed-world capability binding and explicit preview/effect/execute surfaces;
- `Data.define` for immutable wire/protocol values;
- staged validation pipelines and explicit lookup-table dispatch;
- durable outbox/observer flows and optional OTEL adapters.

The pattern audit found two material bypasses: memory consolidation's direct
model call and agent's hidden stream contract. It also recommends replacing one
anonymous episode `Struct` with a named immutable value and making policy phases
visible without introducing generic frameworks. See [patterns.md](patterns.md).

## Five-Whys root-cause themes

### 1. Generated evidence is not coupled tightly enough to source changes

1. Deleted/renamed paths remain in baselines and requirements artifacts.
2. Generators are run as separate maintenance steps rather than as a required
   post-change gate.
3. Some generators do not fail closed on analyzer failure.
4. CI omits the tasks that would expose the drift.
5. Root cause: generated evidence is treated as a report, not as a versioned
   build product with an executable freshness invariant.

### 2. Contracts drift because the owning seam is implicit

1. Schedule, MCP source, situation recall, and eval package behaviors disagree
   between declarations and callers.
2. Consumers evolved against concrete implementations or separately maintained
   method lists.
3. Boundary tests cover happy paths, not minimal conforming implementations or
   installed artifacts.
4. The architectural intent is documented in more than one place.
5. Root cause: the contract is not represented by one executable, package-level
   test that derives its required API from the same owner used by callers.

### 3. Durable and non-durable paths are not labeled at every model seam

1. Main session calls use the effect journal, but consolidation calls the model
   directly.
2. Consolidation predates or sits beside the session effect service.
3. Its API accepts a model rather than a durable effect capability.
4. No replay/failure-injection test covers the gap.
5. Root cause: the durable boundary is architectural policy, not yet an enforced
   type or test seam for every state-changing model call.

### 4. Protocol duplication is caused by real ownership differences plus missing
contract matrices

1. Multiple gems need canonical bytes, truncation, egress, and security policy.
2. Some consumers cannot depend upward and some formats intentionally differ.
3. Similar names make the differences easy to miss.
4. Shared parity fixtures are absent for the common subset and divergence cases.
5. Root cause: ownership is split correctly in places, but the differences are
   not made executable or obvious enough.

## Recommended order of work

1. Restore a trustworthy gate: fix `rake ci` scope, fail closed on analyzer
   errors, regenerate current inventories, resolve `cold-chain`/protocol drift,
   and make the quality baseline current.
2. Fix package boundaries: include the stream runtime contract, make
   `SituationRecall` a correctly owned contract, and decide the real Evals
   package role.
3. Correct effect lifecycle: route memory consolidation through the existing
   dispatcher and complete MCP ambiguous outcomes as `unknown`.
4. Make contract tests executable: standalone agent require, installed stream
   artifact, minimal ScheduleStore fake, MCP source negative preflight, and
   production-path unknown-outcome journal tests.
5. Add parity vectors for canonicalization, egress/security policy, truncation,
   and wire-time parsing.
6. Only after the gate is meaningful, refactor complexity hotspots in this order:
   Evals verifier, stream situation request, SQLite schedule/memory stores,
   agent CLI, and the subprocess runner. Preserve ordering and error contracts.
7. Reconsider new gems only after measuring a real consumer for stream contracts
   or MCP websearch isolation.

## Validation record and limitations

Validated during this audit:

- Enola snapshot, receipt, baseline, and layer/cycle check;
- pinned Ruby 3.3.11 syntax and focused contract checks;
- current RuboCop and Reek inventories;
- focused package/isolation, benchmark, stream approval, agent model, and eval
  tests, with failures classified in the reports.

The full pinned-Ruby CI run is not green on this checkout. Confirmed failures
include the invalid `cold-chain` constantization, stale benchmark protocol
artifacts, expired approval fixtures relative to 2026-08-20, hidden agent→stream
requires, and selector-control timing/lease failures. Initial sandbox socket
`EPERM` failures are environment limitations and were not counted as product
defects.

Static analysis cannot prove every dynamic operator path, provider behavior, or
rare crash interleaving. The reports call out partial file-by-file reads in the
largest gems and distinguish confirmed defects from review candidates. No
production or test code was modified; only this dedicated documentation folder
was added/updated.
