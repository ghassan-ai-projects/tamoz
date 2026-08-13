# The observability bar

What Tamoz must be able to answer about itself, how good that answer has to be, and where
the current implementation actually stands.

Status: proposed standard, not yet accepted. This document sets the acceptance criteria
BEFORE any observability design, so that the design in
[`OBSERVABILITY_DESIGN.md`](OBSERVABILITY_DESIGN.md) can be graded rather than admired.
Section 7 is an audit of the repository as it exists on this branch, with file and line
evidence, and it is the reason the design exists.

## 1. Why the bar comes first

Observability work fails in a recognizable way. Someone adds spans, then metrics, then a
dashboard, and at the end nobody can name a question that was unanswerable before and is
answerable now. The volume of telemetry becomes the deliverable. Cost grows, a collector
gets a copy of every prompt, and the first real incident is still debugged by reading
source code.

Tamoz has an unusual advantage here and a matching obligation. The advantage: this system
already writes down what it did. Checkpoints, the request inbox, the effect journal, plans,
reviews and decisions are durable, ordered and content-addressed. Most agent frameworks
have to *infer* what happened from logs; Tamoz can *read* what happened from storage.

The obligation follows from the same fact. A framework whose entire pitch is "nothing acts
without a reviewed plan, and ambiguous work stops rather than repeating" must be able to
show that this was true on a specific Tuesday, for a specific thread, to somebody who does
not trust the claim. Observability here is not operational garnish. It is the evidence
layer for the safety claims the README already makes.

So the bar is not "we have traces". The bar is a set of questions, a required quality for
the answers, and a proof obligation for each.

## 2. The seven questions

An operator, on their own, without reading Ruby, must be able to answer these. Each names
the durable fact it should be answerable from.

| # | Question | Answerable from |
|---|---|---|
| Q1 | **Is it alive, and is it stuck?** Which processes hold leases, what is the oldest open occurrence, when did the worker last make progress, what is it waiting for | lease table, open occurrences, request inbox |
| Q2 | **What happened in this turn, in order, and why?** Discovery, plan, review, approval, each tool call, each effect, verification, outcome — as one ordered structure | checkpoints, plan/review records, effect journal, decision records |
| Q3 | **What did it cost, and who spent it?** Wall time, model calls, input/output/cache tokens, currency — attributed to thread, profile and turn, with estimates labeled as estimates | model call records (today: absent — see §7) |
| Q4 | **Did anything unsafe or unproven happen?** Auto-approvals, unknown effects, unverified completions, budget stops, repeated-action stops, denied tools | effect census, decision records, verification records |
| Q5 | **Where is work piling up or being lost?** Queue depth, lease waits, retries, backpressure, drops, throttles — and every drop counted, never silent | inbox census, telemetry drop counters |
| Q6 | **Why did this fail, and whose fault is it?** A typed error, whether it is retryable, whether it came from the provider, the store or Tamoz, with a correlation id that reaches the durable record | error taxonomy, correlation identity |
| Q7 | **Is behavior drifting?** Cache epoch changes, behavior versions, plan and repair rates, verification pass rate, tool denial rate over time | epoch records, behavior versions, aggregated history |

Q1, Q2 and Q4 are release-blocking: they are the operational and safety floor. Q3 and Q5
are operational necessities for anything unattended. Q6 and Q7 are what make the system
improvable rather than merely runnable.

Anything that does not serve one of these seven questions is not observability for this
project. It is data.

## 3. The five properties of an acceptable answer

A signal that answers a question in §2 is only acceptable if all five hold.

**P1 — Observer-only.** No observability path may change what the system does. Committed
checkpoint bytes, model-facing message order, control flow and outcomes must be identical
with observation fully enabled, fully disabled, and actively failing. This is invariant 15's
rule for streaming, applied to the third plane
([`design-v0.1/ARCHITECTURE.md`](design-v0.1/ARCHITECTURE.md) §7 already names the split:
state is load-bearing, stream parts are consumer-facing, instrumentation is observer-only
and may be dropped).

**P2 — Redacted by construction, not by scrubbing.** Invariant 24 forbids secret values in
checkpoints, streams and instrumentation, and forbids lossy key-name scrubbing. Telemetry
is where that rule is most often quietly broken, because a trace attribute feels like a
debug aid rather than a durable record. It is a durable record — usually on somebody else's
infrastructure. Prompts, tool arguments, tool results and plan text are content, not
metadata, and content requires an explicit named policy.

**P3 — Safety numbers are derived, never self-reported.** `tamoz status` already follows the
rule that a component must not be the only witness to its own safety: its counters are
computed from the effect census, not reported by the worker
([`cli_worker_commands.rb:259`](../gems/tamoz-agent/lib/tamoz/agent/cli_worker_commands.rb)).
Any counter that asserts a safety property must keep that shape. A component that says
"I performed zero unauthorized actions" is not evidence.

**P4 — Bounded, with visible loss.** Every queue, buffer, payload, attribute, label set,
file and export has a declared bound. Exceeding a bound produces an explicit, counted,
inspectable drop. Silent loss is worse than no telemetry, because it converts an absence of
evidence into an appearance of health. This is invariant 48's requirement for stream
channels, applied to the framework's own signals.

**P5 — Correlated by durable identity.** One identity spine joins the CLI output, the
worker's event stream, spans, metric exemplars and the durable record. Because Tamoz has
stable logical identity that survives crash and resume (invariant 52) and deduplicated
request identity (invariant 23), correlation must be *derived* from those ids rather than
freshly generated. A resumed turn is the same turn; a duplicated delivery is one turn. If
the telemetry says otherwise, the telemetry is wrong.

## 4. The levels

| Level | Meaning | Test |
|---|---|---|
| **L0 — Opaque** | Behavior is inferred from stdout and exit codes | — |
| **L1 — Inspectable state** | Durable state can be queried after the fact by a person who knows the schema | A status command answers Q1 and Q4 from storage |
| **L2 — Structured signals** | A stable, versioned, redacted event schema covers the lifecycle; every signal carries correlation identity | Q2 answerable offline for any thread; schema change breaks a test |
| **L3 — Measured** | Metrics with bounded cardinality, cost and latency attribution, derived safety gauges, and a shipped alert set | Q3 and Q5 answerable without reading events; token/cost budgets become enforceable |
| **L4 — Exportable and provable** | Standards-based export to an operator's stack, plus conformance evidence that observation cannot change execution, cannot leak, and cannot lie | Clause-level conformance tests and scorecard cases pass |

Levels are cumulative, and L4 is the target for a 1.0 that claims to be operable. The
design is required to state which level each of its phases reaches.

## 5. The criteria

Eighteen criteria, each with the proof that satisfies it. "Proof" means an executed test or
an executed command, in the repository's existing sense: a row is `pass` only because its
test ran.

### A. Semantics

| # | Criterion | Proof |
|---|---|---|
| A1 | **The signal catalog is closed and versioned.** Every event, span and metric name, and its required attributes, is registered in one place with a schema version. Names are a compatibility surface | A test enumerates every name emitted by every gem and fails on an unregistered name or a changed attribute set without a version bump |
| A2 | **One identity spine.** Every signal carries thread, request/occurrence, execution, activation and attempt identity, using the same values the durable record uses | Given a signal, a test resolves it to the exact checkpoint and effect rows |
| A3 | **The trace mirrors the durable structure.** Turn → plan → review → approval → step → model call / tool call / effect → verification → outcome, with interrupt and resume as first-class, not as gaps | A reconstructed trace for a killed-and-resumed thread has one root and no orphan spans |
| A4 | **Identity is derived, not generated.** Trace and span identity are pure functions of durable identity, so the same turn observed twice, or resumed after `kill -9`, is one trace | Deliver a duplicate request and crash mid-turn; assert one trace id, and assert the id is reproducible offline from storage alone |

### B. Safety

| # | Criterion | Proof |
|---|---|---|
| B1 | **No `Tamoz::Secret` can reach any signal.** Structural rejection on the emission path, not a regex over the output | Property test across events, spans, metric labels, exception text and the serialized export body |
| B2 | **Content capture is an explicit, named, digest-bound policy**, off by default, per content class, byte-bounded, and refused entirely for restricted classifications | Enable each class in turn and assert exactly that class appears; assert a restricted profile cannot enable any |
| B3 | **Omitted content is represented, not absent.** Where content is not captured, a content digest and size are emitted, so "capture was off" cannot be misread as "there was nothing" | Assert digest+size present and stable for identical inputs across runs |
| B4 | **The policy in force is recorded on the signal it governed** | Change the policy mid-run; assert each signal names the digest that governed it |
| B5 | **Export is a governed egress.** Fixed endpoint, no redirects, no proxy environment, TLS verification, private-address rejection unless explicitly declared, bounded bodies, deadlines, credential by reference only | Point the exporter at a redirect to a private address, a hanging server, and a 100 MB response; each is refused and counted |

### C. Non-interference

| # | Criterion | Proof |
|---|---|---|
| C1 | **Committed bytes are identical with observation on, off, and failing** | Run the same fixture three ways; assert byte-identical final checkpoints and identical model-facing message order |
| C2 | **A hung or hostile collector cannot stall a turn.** Bounded queue, non-blocking hand-off, export deadline, backoff, and self-disable after repeated failure | Run against a collector that accepts the connection and never responds; assert turn latency is unchanged and drops are counted |
| C3 | **A raising observer cannot fail a turn.** An exporter or subscriber that raises is isolated and counted | Install an observer that raises on every signal; the turn completes and the failure is visible |
| C4 | **Bounded memory under sustained load** | Emit at the maximum rate for a sustained period with no consumer; assert bounded memory and a monotonic drop counter |

### D. Cost and performance

| # | Criterion | Proof |
|---|---|---|
| D1 | **Per-call model accounting.** Provider, model, duration, time to first token, input/output/cache-read/cache-write tokens, attributed to thread, profile and turn | Assert accounting for a scripted provider matches the fixture exactly |
| D2 | **Estimated cost is labeled as an estimate**, with the pricing source and its version, and is never presented as a measurement | Assert every cost value carries an estimated/measured discriminator and a pricing source id |
| D3 | **Cardinality is bounded by construction.** No thread id, request id, effect key or execution id appears as a metric label; every metric declares its allowed label keys and value pattern | Fuzz label values; assert rejection and a counted violation rather than an emitted high-cardinality series |
| D4 | **Observation overhead is measured and declared** | Benchmark the reference workflow with observation off and on; publish the delta |

### E. Operability

| # | Criterion | Proof |
|---|---|---|
| E1 | **Local-first.** Full value with no collector, no network and no third-party service: a bounded local journal plus commands that answer Q1–Q4 | Answer Q1–Q4 on an air-gapped machine using only shipped commands |
| E2 | **Retention is bounded and cannot harm the runtime.** Journal rotation and size caps; telemetry never contends with the fenced writer for the runtime database | Fill the journal past its cap; assert rotation, a stable footprint, and no additional writer on the runtime database |
| E3 | **The framework ships its own golden signals.** A named, documented set of dashboards and alert conditions derived from §2, not left as an exercise | The document exists, each alert names the invariant or failure mode it detects, and each is reproduced by a fault-injection test |
| E4 | **A self-test command exists.** One command proves redaction, reports cardinality, shows the policy in force, exercises the exporter, and reports drops | Run it against a synthetic secret and assert the secret appears nowhere in its output or in the export body |

## 6. What the bar deliberately does not require

Stating the non-requirements prevents the design from being graded against somebody else's
product.

- **No agent-behavior analytics product.** Scoring, evaluation and regression detection
  belong to `tamoz-evals` and the autonomy scorecard. Observability feeds them; it does not
  duplicate them.
- **No prompt capture by default, ever.** Not as a convenience, not behind a "debug" flag
  that a hurried operator will leave on.
- **No second durability path.** If observability becomes load-bearing for correctness or
  recovery, the design has failed P1.
- **No plugin API for exporters.** ADR-014 rejected plugin APIs and nothing here changes
  that argument.
- **No real-time streaming of token-level output as telemetry.** That is the stream plane's
  job and it is already bounded (invariant 15).

## 7. Where Tamoz stands today

This is an audit of the working tree on `codex/telegram-communication`, not a summary of
the design documents.

### 7.1 What exists and works

**The durable record is the strongest observability asset in the project, and it is
underused.** `tamoz status`
([`cli_worker_commands.rb:259`](../gems/tamoz-agent/lib/tamoz/agent/cli_worker_commands.rb))
computes pending work, capability sources, the dispatchable catalog, memory summary, safety
counters, paused approvals, blocked effects and budget exhaustions — all derived from the
effect census and open occurrences rather than self-reported. This already satisfies P3 and
answers most of Q1 and Q4. It is L1, done properly.

**The stream plane is complete and bounded.** `Tamoz::StreamPart`, `StreamSink` and
`Graph::StreamEmitter` deliver a bounded, cancellable projection of one run, with the
type table in [`design-v0.1/CORE_DESIGN.md`](design-v0.1/CORE_DESIGN.md) §3 and the
backpressure rules of invariant 15. `tamoz ask --json` renders these parts
([`cli.rb:326`](../gems/tamoz-agent/lib/tamoz/agent/cli.rb)).

**The instrumentation seam exists and is carefully built.**
[`gems/tamoz-core/lib/tamoz/instrumentation.rb`](../gems/tamoz-core/lib/tamoz/instrumentation.rb)
normalizes and bounds the event name, copies the payload immutably, refuses a notifier that
runs the block twice, and re-raises the application's error rather than the notifier's.
`Context` and `Configuration` both validate that a notifier responds to `instrument`.

### 7.2 What is missing

**The instrumentation plane has no producers.** A repository-wide search for
`Tamoz.instrument(` finds the definition and nothing else. `Notifier::Null` is the only
implementation. The plane that `ARCHITECTURE.md` §7 designates as the observer-only path is
an empty pipe.

**Consequence: the stream plane is being used as telemetry, which the design explicitly
warns against.** [`CORE_DESIGN.md`](design-v0.1/CORE_DESIGN.md) §3 states that "a surface
that wants lossy telemetry uses instrumentation, not the stream". Today `--json` is the
only lifecycle signal a user gets, and it is the stream. The stream applies backpressure by
design, so a slow consumer of what an operator treats as logs slows the run — a direct P1
violation that exists precisely because the correct plane is empty.

**The worker's event surface is ad hoc.**
[`worker.rb:515`](../gems/tamoz-agent/lib/tamoz/agent/worker.rb) emits
`{"event", "ts", …}` through a callable installed by
[`cli_worker_commands.rb:412`](../gems/tamoz-agent/lib/tamoz/agent/cli_worker_commands.rb).
Three event names exist: `request.completed`, `request.failed`, `request.paused`. There is
no schema, no version, no registry, no correlation beyond thread and request id, and no
consumer other than stdout. [`OPERATIONS.md`](../documentation/operations/operations.md) §Observability describes
`--json` as emitting an event "for every plan, review, approval, tool call, receipt and
terminal transition"; that is true of the stream parts in the interactive CLI, and not true
of the worker's event stream.

**Nothing designed as observability has been built.** Three documents specify work that
does not exist in code:

| Specified in | Promises | Status |
|---|---|---|
| [`design-v0.1/GOAL.md:45`](design-v0.1/GOAL.md) | "Stable event schemas and an OpenTelemetry integration test" as the evidence for the Operable goal | not implemented |
| [`design-v0.1/EVALUATION_DESIGN.md:190`](design-v0.1/EVALUATION_DESIGN.md) §7 | An OTel bridge test asserting span relationships, lease/checkpoint/queue/effect metrics, no high-cardinality labels, no content under default policy | not implemented |
| [`M4_PLAN.md:482`](M4_PLAN.md) §13 | `tamoz.agent.model.*` and `tamoz.agent.tool.*` events with digests, usage and durations | not implemented; a search for those names returns nothing |

**There are no metrics of any kind.** No counters, no histograms, no gauges, no scrape
endpoint, no export. Q5 and Q7 are unanswerable except by hand-reading storage.

**Token and cost accounting do not exist, and this has already cost the product a
feature.** `Profile::BUDGET_KEYS` declares `cost_usd`, `input_tokens`, `output_tokens`,
`wall_clock_seconds`, `steps` and `model_calls`
([`profile.rb:83`](../gems/tamoz-agent/lib/tamoz/agent/profile.rb)), but
`WorkerRuntime#budget_usage`
([`worker_runtime.rb:213`](../gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb)) computes
only `model_calls` (counted from the effect census) and `wall_clock_seconds`.
[`LIMITATIONS.md:126`](../documentation/limitations.md) records the consequence honestly: "Only two budgets
are enforced… There is no spend cap in currency or tokens."

That limitation is not a budgeting bug. It is a measurement gap. The enforcement code is
willing; there is no measured number to enforce against. **Closing Q3 converts three
recorded-only budgets into enforceable ones**, which is the single largest concrete win
available here and the reason cost accounting is not deferred to a later phase.

**There is no correlation identity.** Errors do not carry a trace id. `Context` receives
`execution_id: SecureRandom.uuid` per CLI process
([`cli.rb:335`](../gems/tamoz-agent/lib/tamoz/agent/cli.rb)), so nothing today ties a signal
to a durable checkpoint without manual reasoning about thread and request ids.

### 7.3 The score

| Group | Criteria met | Notes |
|---|---|---|
| A. Semantics | 0 / 4 | No registry, no versioned schema, no correlation, no reconstructed trace |
| B. Safety | 2 / 5 | B1 and B2 hold *vacuously* — there is no telemetry to leak. They are unproven for any pipeline that emits |
| C. Non-interference | 1 / 4 | C1 holds for the stream (invariant 15 is tested); C2–C4 have no subject |
| D. Cost and performance | 0 / 4 | No accounting, no metrics, no cardinality control |
| E. Operability | 1 / 4 | E1 partially, through `tamoz status`; no journal, no golden signals, no self-test |

**Current level: L1.** Durable state is inspectable through one well-built status command.
There is no structured signal plane, no measurement, and no export.

The gap between L1 and the README's claim of an "observable" framework is the subject of
[`OBSERVABILITY_DESIGN.md`](OBSERVABILITY_DESIGN.md).

## 8. How the design will be graded

The design is accepted only if it states, for each of the eighteen criteria in §5, either
the mechanism that satisfies it and the test that proves it, or an explicit deferral with
the level it forfeits. A criterion that is neither satisfied nor explicitly deferred is a
defect in the design, not an implementation detail.

This is not decorative. Revision 1 of the design graded itself 18/18 and was rejected: an
adversarial review ([`reviews/OBSERVABILITY_DESIGN_REVIEW.md`](reviews/OBSERVABILITY_DESIGN_REVIEW.md))
found six critical defects, four in the machinery the grade depended on. Revision 2 grades
itself 14 met, 3 partial, 1 conditional. **A design that meets every criterion on the first
attempt has probably graded itself against its own intentions rather than against the code.**

Two failure modes are grounds for rejection regardless of anything else:

1. **Any observability path that can change execution.** P1 is not negotiable, and the
   current use of the backpressuring stream as a log surface is an existing instance of the
   failure this rule prevents.
2. **Any default that sends user content off the machine.** P2 is not negotiable.
