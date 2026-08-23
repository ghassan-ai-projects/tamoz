# Pattern usage audit

Date: 2026-08-20  
Repository: `/Users/ghassan/my-projects/tamoz`  
Scope: architectural and implementation patterns, including ports and
adapters, durable effects, immutability, capability boundaries, validators,
stores, builders, dispatch tables, error taxonomy, and observer/outbox flows.

This is a read-only audit. No production or test code was changed.

## Executive assessment

Tamoz uses its main patterns deliberately and, in the important paths,
consistently. The strongest examples are the durable effect journal,
capability-host boundary, SQLite adapter seams, immutable protocol values, and
explicit validation pipelines. Enola found no enforced layer violation and no
high-confidence dependency cycle.

The main pattern risks are not absence of patterns. They are a few places where
an existing pattern is bypassed or where a pattern is present only implicitly:

| ID | Severity | Finding |
|---|---|---|
| P-01 | High | Memory consolidation calls the model directly instead of using the durable effect journal. |
| P-02 | High | The situation-recall contract is placed in `tamoz-stream` but consumed directly by `tamoz-agent`, crossing the package boundary. |
| P-03 | Medium | Stream episode identity uses an ad hoc `Struct` where the repository's immutable protocol-value pattern is clearer. |
| P-04 | Medium | Some policy phases are encoded as long branch accumulators instead of named pipeline steps. |
| P-05 | Medium | Canonicalization has multiple protocol-specific implementations without one contract map. |

These findings overlap with the existing-usage, duplication, missing-
abstraction, and gem-boundary reports. The purpose here is to assess whether
the chosen patterns are being applied consistently, not to count every long
method as a pattern violation.

## Method and evidence

I reviewed the repository rules and architecture documents, all 13 gem roots and
gemspecs, entrypoints under `apps/`, `bin/`, and `script/`, test support and
boundary tests, and the key implementation seams named below. I also used the
Enola snapshot:

- 537 files seen, 495 parsed, 0 parse errors;
- 9,659 facts and 52 heuristic insights;
- layer check passed;
- the only cycle insight had confidence 0.40, below the enforcement threshold.

Ruby behavior checks used the pinned Ruby 3.3.11 runtime through `rbenv`. The
full CI run has separate failures documented in `code-quality.md`; those are
not treated as pattern evidence unless the failure isolates a pattern seam.

## Patterns that are working well

### Durable effects and replay

`Tamoz::Agent::EffectDispatcher` is the correct central seam for non-
deterministic tool and model effects. `SessionEffects#model_call` routes
durable session model calls through it, and session routing consumes the
service rather than reaching directly into a provider. The dispatcher records
prepare/start/complete transitions and supports an explicit unknown outcome.

This is a strong pattern because request identity and deduplication are based
on the request, while the provider result is recorded as a receipt. The pattern
also aligns with the repository rule that replay must not issue a fresh model or
tool call.

The pattern is not universal: `Tamoz::Agent::Runtime#model_generate` is an
ephemeral runtime path and may call its injected model directly when it is not
inside a durable graph. That distinction should remain explicit in tests and
documentation.

### Ports and adapters

The scheduler, stream, effect, communication, observability, and SQLite seams
use injected collaborators rather than hard-wiring concrete storage everywhere.
`Tamoz::Scheduler::ScheduleStore`, stream artifact/verification stores, and
communication outbox interfaces are the right shape for test doubles and
alternate adapters. The SQLite implementation owns transactions and durable
state; contract gems do not reach downward into SQLite.

The boundary is strongest where `test/dependency_isolation_test.rb` loads gems
in clean subprocesses. The main weakness is contract drift, not the pattern
choice: `ScheduleStore`'s declared keywords and lifecycle methods do not fully
match the SQLite adapter and its callers. That is recorded as EU-002 in
`incorrect-existing-usage.md`.

### Closed-world capability and authority boundaries

`Tamoz::Agent::CapabilityBinding`, `McpCapabilitySource`, the capability host,
and MCP invocation validation implement a closed-world pattern: descriptors are
catalogued, validated, bound to an authority, and then executed through the
approved operation. Preview/effect-intent/execute are separate surfaces, which
helps prevent an informational path from silently becoming an effect path.

MCP websearch also keeps egress policy and circuit state at the adapter boundary
instead of letting arbitrary model output choose a URL or credential. The
duplicated agent/MCP policy vocabulary is a maintenance risk, but the separation
of authority ownership is correct and should not be replaced with a generic
cross-gem base class without a third consumer.

### Immutable protocol values

`Data.define` is used broadly for schedules, stream envelopes, receipts, rows,
traces, and other stable values. This is the right pattern for values that cross
process, storage, or gem boundaries: fields are visible, mutation is limited,
and validation can live close to construction.

The repository also uses mutable `Struct` intentionally for parser state, such as
the YAML scanner frame. That is appropriate because parser frames are internal
working state rather than protocol values.

### Explicit validator pipelines

Profile, session-record, MCP descriptor, artifact, and stream request validation
generally follows a staged pattern: shape checks, authority/security checks,
canonicalization/digest checks, and semantic checks. This is easier to review
than implicit coercion and supports fail-closed behavior.

The main risk is branch growth in `Evals::Verifier`,
`Deliberation.structural_issues`, and `EpisodeRequestEnvelope#validate!`; the
pattern remains sound, but named policy phases would keep future additions from
changing ordering accidentally.

### Lookup tables and explicit dispatch

Recent refactors use simple lookup tables for CLI commands and eval actions.
This is a good local pattern: it removes repetitive conditionals without hiding
authority or introducing a dynamic plugin registry. `Toolbox#execute` is a
candidate for the same narrow technique if more operations are added, but its
effect-intent and preview methods should stay explicit.

### Outbox and observer flows

Communication delivery uses durable outbox records and separate delivery/drain
logic. Observability and OTEL are split into a contract gem and optional
exporter. This prevents an external exporter from becoming a runtime
requirement and keeps delivery retry behavior in a durable store.

## Findings

### P-01 — Memory consolidation bypasses the durable effect pattern

Severity: High  
Confidence: High  
Status: confirmed

Evidence:

- `gems/tamoz-agent-memory/lib/tamoz/agent/memory/consolidation.rb:182` calls
  `model.generate(stage: :consolidate, system:, prompt:)` directly.
- The method is reached by `Consolidation#consolidate`, which receives a model
  but no `EffectDispatcher` or `SessionEffects` seam.
- The method writes a preimage, invokes the non-deterministic model, then marks
  the source records consumed. A process failure between the model response and
  the consumed transition can issue a different response on retry.
- The repository rule explicitly requires model/tool calls that affect durable
  graph state to go through `EffectDispatcher.run`.

Why it matters: this is exactly the failure mode the effect journal exists to
prevent. The code's local “provider boundary” naming does not provide request
identity, receipt replay, or a durable unknown state.

Recommendation: route consolidation through the existing effect service with a
deterministic logical key derived from owner/scopes/candidate preimage and a
request payload digest. Record the provider receipt before applying consumed or
promoted state. Add a replay test and a failure-injection test between provider
completion and state application. Keep the existing consolidation domain logic;
do not invent a second journal.

### P-02 — Situation recall violates the declared dependency-inversion pattern

Severity: High  
Confidence: High  
Status: confirmed package-boundary defect

Evidence:

- `gems/tamoz-agent-memory/lib/tamoz/agent/memory/situation_recaller.rb:4` requires
  `tamoz/stream/situation_recall`.
- The agent gemspec does not declare `tamoz-stream` as a dependency.
- `gems/tamoz-agent-memory/lib/tamoz/agent/memory.rb` eagerly loads the recaller, so a
  standalone `require "tamoz/agent"` can fail under package-isolated load paths.
- The agent directly references `Tamoz::Stream::SituationRecall::Result` and
  `Projection`, although the design describes the recaller as an injected port.

Why it matters: the implementation looks like a port but imports the concrete
contract from an upper integration gem. This breaks package isolation and makes
the lower-level runtime depend on stream load behavior.

Recommendation: place the storage-agnostic recall value/port in `tamoz-core` or
another narrowly owned contract gem, or define the agent-owned port without a
stream require and adapt stream at composition time. Add a clean-process test
for `require "tamoz/agent"` and a contract test for a non-stream recaller. Do
not add a direct agent→stream dependency merely to make the require pass; that
would hide the misplaced abstraction.

### P-03 — Immutable episode identity is built with an ad hoc `Struct`

Severity: Medium  
Confidence: Medium  
Status: review candidate

Evidence: `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:470`
constructs an anonymous `Struct.new(:episode_id, :attempt_id, :fence)` for an
identity value. The same file uses `Data.define` for public envelope and stream
values, and `Data.define` is the established pattern across stream, scheduler,
observability, and core protocol values.

The distinction matters: `Struct` is appropriate for mutable parser frames, but
this identity is passed to episode execution and participates in ordering and
fencing. An anonymous type also makes inspection and contract pinning weaker.

Recommendation: use a named `Data.define` value if the identity is public or
crosses the runner boundary. Preserve fields and equality semantics, then add a
small value test. If the identity is intentionally ephemeral and never escapes
the method, document that local choice and leave it alone.

### P-04 — Policy phases are implicit inside long branch accumulators

Severity: Medium  
Confidence: High  
Status: review candidate

The pattern is visible in:

- `Tamoz::Agent::Deliberation.structural_issues` (complexity 21), which combines
  plan, step, and ordering checks;
- `Tamoz::Evals::Verifier` status/provenance methods (complexity 16–21), which
  combine shared artifact loading with family-specific semantic policy;
- `Tamoz::Stream::EpisodeRequestEnvelope#validate!`, which combines identity,
  catalog, budget, risk, and trace checks.

These are validators/orchestrators, not arbitrary “god classes.” The concern is
that new policy rules have no named phase and can change error ordering or
authority semantics.

Recommendation: extract pure phase methods or narrow policy objects only when a
second caller or a materially independent test axis exists. Preserve the
existing order and exact error contracts. Avoid generic validation frameworks
and callback pipelines.

### P-05 — Canonicalization patterns have no visible ownership map

Severity: Medium  
Confidence: High  
Status: contract/documentation gap

The repository has several valid formats: `Tamoz::Core::JCS`, Evals artifact
canonical JSON, MCP catalog/invocation canonical JSON, Comms canonical values,
and SQLite wire digests. They intentionally differ on floats, `Time`, key
normalization, and digest domains, but their names and tree-walk shapes are easy
to confuse.

Recommendation: document a small contract table naming the owner, accepted
types, byte format, digest domain/prefix, and permitted consumers. Add parity
vectors for the common subset and explicit divergence vectors for floats,
invalid encodings, non-string keys, and time values. Do not merge formats merely
to remove repeated code; durable bytes are the contract.

## Full component coverage

All 13 production gems were checked for the patterns above and their entrypoint
and dependency behavior:

1. `tamoz-agent` — effect dispatcher, session ports, capability binding,
   validators, memory consolidation, CLI dispatch.
2. `tamoz-comms` — canonical values, outbox/delivery, immutable records.
3. `tamoz-core` — errors, JCS, immutable values, circuit and shared primitives.
4. `tamoz-evals` — artifact verifier, harness, subprocess lifecycle, semantic
   policies.
5. `tamoz-graph` — durable graph runner, checkpoints, circuit/storage ports.
6. `tamoz-mcp` — capability server, invocation, egress policy, circuit,
   bounded output.
7. `tamoz-observability` — content policy, trace/record values, sink boundary.
8. `tamoz-otel` — optional exporter adapter.
9. `tamoz-scheduler` — schedule values and `ScheduleStore` contract.
10. `tamoz-sqlite` — transaction/store adapters and durable effect completion.
11. `tamoz-stream` — wire envelopes, workers, capability host, artifact ports.
12. `tamoz-telegram` — optional comms transport adapter.
13. `tamoz-tools` — tool policy, receipt boundary, explicit operation dispatch.

Repository surfaces `apps/`, `bin/`, `script/`, `test/`, gemspecs, architecture
docs, quality docs, and public API manifests were included in the boundary and
pattern checks. Generated fixtures were treated as data, not as production
pattern implementations.

## Non-findings

- The Enola cycle heuristic is low confidence and is not evidence that the
  repository's layering pattern is broken.
- High fan-in of `Tamoz::Core.digest`, `Tamoz::Core.jcs`, and `Tamoz::Error` is
  expected for foundational primitives. It is not a reason to add interfaces.
- `Struct` in the YAML scanner is appropriate mutable parser state.
- Separate agent/MCP egress policy copies preserve gem isolation; test them with
  shared vectors before considering extraction.
- SQLite stores are correctly kept behind adapter seams; their size alone does
  not justify new gems.

## Blind spots

The audit uses static tracing and focused tests. Dynamic operator modes, rare
process crashes, and provider-specific behavior require runtime or mutation
tests. Enola does not parse all docs/JSON/YAML or every test body. The full CI
suite is currently not green for independent package, benchmark-fixture, and
time-sensitive fixture reasons recorded in `code-quality.md` and
`incorrect-existing-usage.md`.

