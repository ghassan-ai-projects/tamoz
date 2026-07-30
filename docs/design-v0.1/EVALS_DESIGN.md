# `tamoz-evals` — conformance, behavioral evaluation, and release gates

`tamoz-evals` is Tamoz's development and release quality system. It is a first-class gem in
the monorepo, but it is not a runtime layer and no production gem depends on it.

```text
tamoz-evals
    ├── exercises tamoz-core contracts
    ├── exercises tamoz-graph semantics
    ├── exercises tamoz-sqlite conformance
    ├── exercises tamoz-agent behavior
    ├── exercises tamoz-stream conformance when selected
    └── benchmarks Tamoz Agent

tamoz-core / graph / sqlite / agent / stream ──X──▶ tamoz-evals
```

This direction matters. Evaluation may observe every public boundary, but deleting the eval
gem from a production bundle must not change execution, loading, or behavior.

## 1. Purpose and limits

The gem owns:

- the executable form of the 55 invariants;
- reusable conformance suites for engines, checkpointers, leases, effects, requests, stores,
  schedule stores, stream stores, capability catalogs, and codecs;
- agent cases for planning, semantic review, replanning, evidence, verification, safety,
  durability, efficiency, and bounded self-improvement;
- versioned case, run, score, comparison, and gate artifacts;
- recorded/replay and live evaluation profiles;
- baseline comparison and release decisions;
- the `tamoz-eval` CLI.

It does not own:

- production telemetry storage;
- model training or fine-tuning;
- a hosted dashboard or multi-tenant service;
- a generic benchmark marketplace;
- runtime policy, authorization, or behavior;
- an LLM provider abstraction.

The first release is deliberately Tamoz-specific. Generalizing the runner before Tamoz
Agent has a stable corpus would create an evaluation framework whose abstractions have no
demanding consumer.

The artifact/schema/runner core uses the Ruby standard library. RSpec support is an adapter
for conformance authors. Model SDKs, Tamoz runtime gems, databases, and report integrations
are loaded only by the selected subject or profile; they are not unconditional gem
dependencies.

## 2. Rules that cannot be configured away

1. **Outcome evidence outranks self-report.** Tests, state, effect receipts, policy records,
   and independent observations decide success. An agent saying “done” is not an oracle.
2. **Deterministic scorers run first.** Exact values, schemas, tests, diffs, state machines,
   and policy checks are preferred to model judgment.
3. **Safety and correctness are hard gates.** They are not weights in an average.
4. **No single quality score controls release.** Reports expose a scorecard and every hard
   gate; strong task success cannot hide a secret leak or unreviewed action.
5. **Every input to judgment is versioned.** Case, split, corpus, fixture, scorer, rubric,
   judge prompt/model, subject behavior, graph, tools, policy, and environment have stable
   identities and content digests.
6. **Baseline and candidate use paired cases.** They run under equivalent environments and
   configured repetition policies. One lucky completion is not evidence.
7. **Evaluator changes start a new lineage.** New thresholds or easier cases cannot
   retroactively validate an old candidate.
8. **Protected holdouts stay unavailable to the subject.** The subject cannot read their
   inputs, expected outputs, judge prompts, case-level results, or release thresholds.
9. **Model judges are fallible evidence.** They are blinded where possible, calibrated
   against human labels, and never override deterministic safety failures.
10. **Raw content is protected by default.** Reports contain safe references and digests;
    prompt, trajectory, secret, and tool-output capture requires an explicit content policy.

These are gem-level governance contracts. Project configuration may add stricter rules but
cannot weaken them.

## 3. Minimal public surface

The v0.1 vocabulary is five concepts:

| Concept | Responsibility |
|---|---|
| `Case` | One versioned input, environment, definition of done, budgets, and scoring contract |
| `Suite` | A named, versioned set of comparable cases and split policy |
| `Runner` | Executes a subject under an isolated profile and records observations |
| `Result` | Immutable case/run evidence and scorer decisions |
| `Gate` | Converts a complete result set and baseline into pass, fail, or insufficient evidence |

`Scorer`, `Judge`, artifact storage, reporters, and statistical methods are protocols behind
those concepts, not additional introductory abstractions.

```ruby
# Illustrative
suite = Tamoz::Evals::Suite.load("evals/planning.v1.json")

result = Tamoz::Evals::Runner.new(
  subject: TamozAgentFactory.new(behavior: candidate),
  profile: :recorded,
  artifacts: "./tmp/eval-artifacts"
).run(suite)

decision = Tamoz::Evals::Gate.release(
  candidate: result,
  baseline: Tamoz::Evals::Result.load("baselines/tamoz-agent-v0.1.json")
)
```

`tamoz-eval run`, `tamoz-eval compare`, and `tamoz-eval verify` expose the same operations.
The CLI returns distinct exit codes for gate failure, invalid evidence, infrastructure
failure, and insufficient sample size.

## 4. Canonical case contract

JSON is the canonical durable format. A Ruby authoring DSL may compile to the same schema,
but only the canonical artifact is hashed and executed.

Each case contains:

```text
format_version
case_id, case_version, suite_id, split
title, purpose, tags, risk_class
input plus fixture digests/references
environment and isolation contract
allowed and prohibited capabilities/actions
definition_of_done
required and optional evidence
scorers, rubrics, judges, and their versions
budgets: turns, steps, tools, tokens, cost, time
repetitions and comparison method
content/sensitivity policy
```

Cases are immutable. Correcting a case creates a new version and records which result
lineages are no longer comparable.

## 5. Suite taxonomy

### Deterministic conformance

- v0.1 invariants 1–27 and 52–55; v0.2 invariants 29–31 and 41–43; v0.3 invariants 28
  and 32–34; conditional MCP/scheduler invariants 35–40 before feature promotion;
  conditional streaming invariants 44–51 before `tamoz-stream` promotion;
- state/reducer, scheduler, and stream/Situation reference-model equivalence;
- persistence, lease, effect, request-inbox, StreamStore, Store, and codec contracts;
- crash, replay, fork, migration, streaming, and resource cleanup;
- plan/review authorization and behavior-version pinning.

These suites perform no live model or network call. The first adapter is RSpec-friendly, but
the suite semantics belong to `tamoz-evals`, not to individual gem specs.

### Deliberative behavior

- goal and definition-of-done coverage;
- assumption, unknown, and evidence classification;
- structural and semantic plan-review defect detection;
- exact plan-digest authorization;
- proportional one-step plans for simple work;
- replan/re-review when evidence changes;
- correct clarification when ambiguity is material;
- independent verification and honest unverifiable outcomes.

### Task competence

v0.1 centers on repository work because it has strong oracles:

- inspect and explain;
- diagnose without mutation;
- make a constrained code/document change;
- run targeted verification;
- recover from a stale assumption;
- stop when the definition of done is satisfied.

Fixtures are hermetic repositories with deterministic tests and explicit allowed diffs.

### Safety and adversarial behavior

- prompt injection in user input, files, tools, skills, and retrieved memory;
- path/scope escape, forged approval, and capability widening;
- sensitive-data exfiltration;
- ambiguous effect, cancellation, and duplicate delivery;
- budget exhaustion and pressure to skip review;
- malicious cases asking the subject to edit its evaluator or reveal a holdout.

### Durability and long-horizon behavior

- crash at every plan, review, action, verification, and persistence seam;
- compaction without losing decisions, evidence, or unresolved risk;
- resume under pinned graph and behavior versions;
- queued/redirected concurrent input;
- repeated sessions with bounded memory and resource use.

### Bounded self-improvement

- candidate provenance and train/holdout separation;
- evaluator and threshold immutability;
- no self-approval or capability widening;
- paired baseline improvement;
- turn-boundary activation and checkpoint pinning;
- monitoring, regression detection, and rollback.

### Three-layer memory

- no-memory, Experience, Knowledge, and Wisdom treatment comparison;
- authorization-before-ranking and zero unauthorized/sensitive recall;
- provenance, epistemic-kind, contradiction, and token-budget preservation;
- consolidation taint gates, recalled-content exclusion, and source preservation;
- correction, supersession, quarantine, decay, and deletion propagation;
- protected-holdout Wisdom promotion and behavior-version pinning.

### Bounded self-healing

- typed detection and abstention on unknown/low-confidence failures;
- exact reviewed remediation plans, preconditions, authority, and budgets;
- effect ambiguity, reconciliation, verification, compensation, circuits, and escalation;
- replay, shadow, 250-case isolated fault injection, canary, active, and retirement modes;
- hard-zero unsafe action, unauthorized scope, duplicate effect, and false recovery gates.

### MCP

- official conformance for every advertised protocol profile;
- source-qualified schema/catalog snapshot and exact-epoch replay;
- stdio/HTTP supervision, OAuth/SSRF/token/credential isolation, and teardown;
- malicious metadata/content, elicitation, remote tasks, disconnect, and effect ambiguity;
- hard-zero remote authority gain, fabricated consent, credential leak, and blind retry.

### Durable scheduling

- reference calendar/occurrence histories across timezone, DST, clock, and downtime;
- crash/race equivalence for due claim, outbox, request delivery, and completion;
- bounded misfire, overlap, jitter, backlog, and concurrency policies;
- delayed grant revocation, headless approval, behavior/catalog change, and self-edit;
- hard-zero duplicate logical turn, authority widening, and false-green delivery.

### Skills

- Agent Skills format and canonical tree-digest conformance;
- source collision, catalog epoch, exact snapshot, progressive load, and token budget;
- selection positive/confusable-negative cases and no-skill/current-skill comparisons;
- archive/path/link/script/dependency/secret/egress and content-injection attacks;
- staged install/update/removal and isolated self-proposed candidate evaluation.

### Streaming input and physical-world behavior

- channel/source/schema/event identity and application dedup conformance;
- event-time, watermarks, idleness, bounded windows/timers, corrections, and virtual-time
  replay;
- partition atomicity, overload/backpressure/gap observability, and restart recovery;
- Situation/trigger/admission precision, latency, supersession, and cognition economics;
- raw-event/window/Situation treatment comparison on identical protected scenarios;
- typed intent, current-state policy, approval/interlock, command/outcome, and ambiguity;
- hard-zero silent loss, direct actuation, stale dispatch, real replay effect, safety bypass,
  and self-promoted physical authority.

## 6. Scoring hierarchy

Scoring follows this order:

1. deterministic oracle;
2. rule/rubric scorer over structured evidence;
3. blinded pairwise or absolute model judge;
4. human adjudication for sampled calibration or unresolved consequential cases.

Later layers cannot overturn a failure from an authoritative earlier layer. Model judges
must return a structured decision, cited evidence locations, confidence, and abstention.
Invalid or unparseable judgments are recorded as invalid evidence, never silently retried
until they pass.

Judge calibration reports agreement and disagreement by case class. A judge that falls
below its configured agreement threshold becomes ineligible for release gating until
reviewed. The subject and judge should not share hidden chain-of-thought; only observable
artifacts and permitted evidence cross the boundary.

## 7. Scorecard and hard gates

Reports keep dimensions separate:

| Dimension | Representative measures |
|---|---|
| Runtime correctness | conformance passes, deterministic state equality, crash outcomes |
| Planning | completion/risk/verification coverage, ordering, proportionality |
| Review | seeded-defect recall, harmless-plan false rejection, digest binding |
| Task success | machine-verified definition of done |
| Smart action | evidence quality, calibrated uncertainty, unnecessary action, replan quality |
| Safety | policy violations, secret recall/leak, unsafe or duplicated effect |
| Durability | recovery, resume, compaction, behavior pinning |
| Efficiency | turns, tools, tokens, cost, latency, cache behavior |
| Improvement | holdout delta, no-harm gates, activation and rollback correctness |

Initial non-negotiable release gates:

- all applicable deterministic conformance cases pass;
- zero critical safety violations;
- zero task actions without an accepted exact plan version;
- zero successful-completion records when required verification failed or is absent;
- zero blind retry of an ambiguous non-idempotent effect;
- zero self-approved capability, policy, evaluator, prompt-hierarchy, or code change;
- no statistically meaningful regression against the released baseline on protected cases;
- complete, schema-valid evidence for every reported result.

Absolute quality thresholds are frozen only after a named corpus and baseline exist. Until
then, the gate is baseline-relative plus the hard requirements above. Threshold changes
require an ADR-like evaluation decision record with rationale and a new lineage.

## 8. Comparison and stochasticity

Every comparison records paired case outcomes, repetitions, invalid runs, infrastructure
failures, model/provider identifiers, and cost. The configured method must match the metric:
paired binary outcomes are not analyzed as independent averages, and latency/cost outliers
remain visible.

Release reports include point estimates, uncertainty intervals, and the raw denominator.
They never report only “percent improved.” A result is `insufficient_evidence` when the
sample cannot support the configured decision; it is not coerced into pass or fail.

Provider nondeterminism is handled through repetitions and distribution comparison. Seeds
are recorded when supported but are never treated as universal determinism.

## 9. Public corpora and protected holdouts

The public gem ships:

- deterministic conformance suites;
- documented authoring examples;
- a public development/smoke corpus;
- synthetic adversarial fixtures.

Tamoz Agent release holdouts live outside the public repository under a separate access and
retention policy. The evaluation worker receives them at run time. The subject sees only the
case input and granted environment; a self-improvement worker receives only an aggregate,
policy-filtered promotion result.

Holdout access, case export, scoring, and deletion are audited. Cases derived from private
user activity require explicit rights, minimization, and de-identification; synthetic
fixtures are preferred.

### Evaluation trust boundary

Behavioral and release evaluation is controller/subject separated:

```text
controller (trusted)
  holds case, holdout, oracle, scorer, gate, baseline
       │ materializes only granted input/fixture/capabilities
       ▼
subject sandbox (untrusted)
  runs Tamoz Agent; cannot read controller files, expected result, or sibling runs
       │ returns observable artifacts through a bounded channel
       ▼
controller scores, verifies digests, compares, and decides
```

The controller never passes holdout paths, scorer credentials, expected outputs, or release
secrets through the subject environment. The sandbox has a fresh worktree/filesystem,
explicit egress, bounded CPU/memory/time, and only the capabilities declared by the case.
The subject cannot write evaluator code or result records. Deterministic conformance may run
in-process when no subject-controlled code crosses this boundary; protected behavioral
evaluation may not.

## 10. Execution profiles

| Profile | Trigger | Network/model | Purpose |
|---|---|---|---|
| `pr` | every change | none; recorded fixtures only | conformance, schemas, safety rules, deterministic regressions |
| `nightly` | scheduled | pinned live models plus replay | behavior distributions, cost, latency, provider drift |
| `adversarial` | weekly/on demand | isolated live environment | prompt injection, policy pressure, fault injection |
| `release` | candidate release | full matrix + protected holdout | baseline comparison and signed gate decision |

Infrastructure failure is separate from subject failure. Automatic rerun is allowed only
for a classified infrastructure failure and retains both attempt records.

## 11. Result and provenance artifact

Every run emits an immutable manifest containing:

- eval gem, suite, case, corpus, scorer, judge, and gate versions/digests;
- subject gem versions, git revision, graph digest, and `behavior_version`;
- model/provider/settings, capability catalog, skill snapshot, schedule/occurrence, memory
  snapshot, policy, and cache-epoch digests;
- environment, fixtures, isolation, seeds, repetitions, and timing;
- trace/result/evidence references and content-policy metadata;
- scores, hard-gate outcomes, invalid evidence, cost, and latency;
- baseline id, comparison method, decision, and decision authority.

The manifest is canonical JSON. Detailed events are JSONL. JUnit is an export for CI, not the
source of truth. A verification command checks all referenced digests and fails closed on an
unsupported format or missing artifact.

The release profile signs the canonical gate manifest with the configured CI/release
identity. Signature metadata identifies the mechanism and signer without entering the
signed payload. Unsigned local results remain useful for development but are ineligible as
release evidence.

## 12. Implementation sequence

M0 creates the gem skeleton, schemas, CLI, artifact verifier, baseline fixture, and twelve
golden cases before agent behavior is implemented. Each later milestone adds its release
evidence to the same system:

- M1–M3: deterministic runtime, persistence, fault, and safety conformance;
- M4: recorded provider and minimal tool-agent cases;
- M5a: discovery/action planning, evidence, verification, and CLI cases;
- M5b: memory and portable-skill treatment/supply-chain cases;
- M6: healing/improvement governance, roughly 50–75 representative Tamoz Agent cases, and
  a protected holdout;
- M7: complete release profile, signed comparison report, and human audit sample.
- Post-v0.1: streaming event-time/Situation/physical-simulator suites first; then MCP
  official/host conformance and scheduler reference-model/fault suites before those
  capabilities are promoted. Portable skill supply-chain/selection suites become
  release-blocking for v0.2.

A suite may not become release-blocking until its cases, scorer behavior, false-positive
cost, and ownership have been reviewed. Once blocking, weakening it requires an explicit
evaluation decision and new lineage.

## 13. External design evidence

OpenAI Evals demonstrates versioned eval registries, reusable templates, custom evaluators,
and private evaluation data:
<https://github.com/openai/evals>.

Inspect separates tasks, datasets, solvers, scorers, and rich evaluation logs containing
dataset, scorer, source revision, model, and usage metadata:
<https://inspect.aisi.org.uk/> and <https://inspect.aisi.org.uk/eval-logs.html>.

Tamoz adopts those durable ideas, not either framework's Python API. The Ruby design remains
small, artifact-first, and specific to the runtime and agent it must prove.
