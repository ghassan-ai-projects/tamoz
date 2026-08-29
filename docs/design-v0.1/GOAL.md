# Goal

Status: correction-reviewed candidate — physical deployment profile still open
Date: 2026-07-30
Names: framework **Tamoz**, reference application **Tamoz Agent** (see the [ADR catalog](../../documentation/adr/README.md), ADR-001)

## The one-sentence goal

Build a small, readable, Ruby-native durable agent runtime over `ruby_llm` that is safe
under crash, resume, concurrency, and human approval; prove every guarantee with an
executable conformance suite and a real Tamoz Agent CLI session. Tamoz Agent plans and
reviews before acting, verifies material outcomes, and improves only through an evaluated,
versioned, reversible promotion loop.

## The two halves, and why they are one project

**Half one — the framework.** RubyLLM now provides providers, messages, tools, streaming,
and a first-class `RubyLLM::Agent` configuration surface. The remaining high-value gap is a
checkpointed, interruptible, branchable execution runtime with explicit crash and effect
semantics. Tamoz fills that gap; it does not recreate RubyLLM's agent configuration layer.

**Half two — the agent.** A Hermes/OpenClaw-class personal agent is not a demo. It needs
sessions that survive restarts, human approval gates mid-tool-call, subagent delegation,
context compaction, skills, MCP tools, scheduled runs, and one agent core shared across a
CLI, a TUI, and a messaging gateway. Its physical-world profile also needs continuous
sensor evidence, Situation detection, and governed intent without placing an LLM in a
hard real-time safety loop.

These are one project because the agent is the only honest specification of the framework.
Every framework primitive in this design exists because half two needs it, and any
primitive half two does not need is cut. A framework designed without a demanding consumer
becomes LangChain: forty concepts, three API rewrites, and abstractions nobody asked for.

## What "good" means

| Property | Target | How it is measured |
|---|---|---|
| Small | ≤ 12 core concepts a user must learn | Concept count in the public API reference (see [RUBY_TRANSLATION.md](RUBY_TRANSLATION.md)) |
| Readable | The super-step loop fits in one file a person reads in one sitting | Engine core ≤ ~400 lines excluding adapters |
| Correct | All applicable invariants hold under parallelism, resume, replay, version change, replanning, capability change, scheduling, memory promotion, healing, and behavior promotion | [INVARIANTS.md](INVARIANTS.md) as an executable RSpec suite |
| Ruby | Nothing in the public API exists only because Python needed it | The refusal list in [RUBY_TRANSLATION.md](RUBY_TRANSLATION.md) |
| Durable | Committed barriers survive crash; replay-safe effects do not duplicate; ambiguous effects stop as `:unknown` | Fault injection at every barrier and effect/receipt seam |
| Sufficient | Tamoz Agent runs on it without reaching around the framework | Traceability matrix in [TAMOZ_AGENT_DESIGN.md](TAMOZ_AGENT_DESIGN.md) |
| Safe | One fenced writer per thread; secrets are excluded or explicitly protected; fatal failures never become model text | Lease, security, and error-boundary conformance |
| Operable | Runs, tasks, checkpoints, interrupts, and effects are attributable without logging prompts or secrets by default | Stable event schemas and an OpenTelemetry integration test |
| Evaluated | Runtime correctness and agent behavior are compared against versioned evidence and a released baseline | `tamoz-evals` deterministic, behavioral, protected-holdout, and release profiles |
| Continuous | Experience becomes Knowledge and evaluated Wisdom without losing provenance or crossing authority | Memory treatment tests and promotion/recall/deletion hard gates |
| Self-healing | Known failures recover only through reviewed bounded rules and independent invariant verification | Typed fault injection, effect reconciliation, compensation, circuit, and escalation suites |
| Extensible | MCP, scheduled work, and portable skills add capability without redefining local authority or graph semantics | Protocol/calendar/skill conformance plus capability-intersection hard gates |
| World-aware | Unbounded physical/digital evidence becomes bounded immutable Situations; every physical intent is fresh, complete enough, typed, interlocked, and replay-governed | Stream clauses 44–51, protected simulations, and independent deployment safety review |

## Success criteria (definition of done for v0.1)

1. A graph with fan-out, conditional routing, approval, cancellation, and SQLite durability
   survives process termination at every injected failure seam and converges to the
   expected committed state.
2. Foundation clauses 1–27 and correction clauses 52–55 pass under inline and threaded
   execution.
   Persistence conformance
   passes for in-memory and SQLite adapters; SQLite additionally passes lease, restart, corruption, and
   file-descriptor tests. Memory/skill clauses 29–31 and 41–43 become mandatory for v0.2;
   improvement/healing clauses 28 and 32–34 for v0.3. MCP clauses 35–37, scheduling clauses
   38–40, and streaming clauses 44–51 become mandatory before their optional packages are
   promoted.
3. A replay-safe tool call does not duplicate under crash. A deliberately non-idempotent
   tool killed after effect success resumes as `:unknown` and does not run again until a
   reconciler or human resolves it.
4. `Tamoz::Agent.react(llm:, tools:)` accepts a RubyLLM Agent or Chat factory and adds
   pause, checkpoint, effect safety, and graph-wide streaming without wrapping away
   RubyLLM message/tool fidelity.
5. Tamoz Agent, the reference agent, runs a real multi-turn coding/assistant session end to end
   on one surface (CLI), with tool approval, session resume, and compaction working.
6. Requiring `tamoz/graph` in a clean process does not load RubyLLM, an HTTP client, or an
   optional adapter.
7. Resuming with a changed graph definition fails with an actionable compatibility error
   unless an explicit migration exists.
8. No task action runs without an accepted review of the exact persisted plan version;
   material plan changes invalidate that review and verification evidence determines
   whether the task is complete.
9. `tamoz-evals` can reproduce a signed release decision from immutable case, subject,
    environment, evidence, scorer, baseline, and gate artifacts; no runtime package depends
    on the eval gem.

The accepted v0.2 gate additionally proves Experience, Knowledge, Wisdom, and portable skill
value independently with zero unauthorized recall. The accepted v0.3 gate proves one
bounded behavior promotion/rollback and one independently verified self-healing rule without
self-approval, duplicate effects, or false recovery.

## Accepted post-v0.1 promotion criteria

1. `tamoz-mcp` supports one real server through the official SDK, passes official and Tamoz
   host/security conformance, pins its catalog, and preserves effect uncertainty and
   durable consent.
2. `tamoz-scheduler` produces deterministic bounded occurrence history across restart,
   races, DST/misfire/overlap cases, and delivers one logical request without retaining
   revoked authority.
3. Skills pass Agent Skills portability, content-addressed replay, selection/value,
   resource/script containment, supply-chain, and self-proposed-candidate gates.
4. `tamoz-stream` deterministically converts one real read-only physical source into
   immutable Situations and routes commands only to a simulator; event loss is visible,
   replay has no production effect authority, and clauses 44–51 pass.

## Explicit non-goals for v0.1

- **Not a LangChain concept-for-concept port.** We clone the *capabilities*, not the
  vocabulary. `Runnable`'s sixteen-method matrix, the `a*` async twins, the memory class
  family, and the chain subclass zoo are deliberately not built.
- **Not a multi-tenant hosted platform.** Single operator, many sessions. No auth server,
  no billing, no team workspace.
- **Not a general training or eval platform.** The bounded evaluation needed to promote
  Tamoz Agent behavior is in scope; fine-tuning infrastructure and arbitrary benchmark
  hosting are not.
- **Not an integration warehouse.** Core ships zero provider integrations of its own.
  Provider and tool integration stays in RubyLLM or optional adapters.
- **Not a rewrite of `ruby_llm`.** It is a dependency of the agent layer and an upstream we
  contribute to, not a thing we fork.
- **Not an exactly-once distributed transaction system.** Tamoz cannot atomically commit an
  arbitrary remote side effect and its local receipt. It provides idempotency keys,
  journaling, reconciliation, and a safe `:unknown` state.
- **Not a general chain library in v0.1.** The chain proposal is retained, but it ships only
  after a real consumer proves `tamoz-graph` plus ordinary Ruby composition is insufficient.
- **No runtime implementation in this phase.** Illustrative DSL sketches pin down
  ergonomics; a stdlib-only design linter may enforce document consistency.
- **Not certified or hard real-time control.** Tamoz may supervise and propose bounded
  physical intents, but emergency stops, guarding, motion/PLC loops, and functional-safety
  controllers remain external and authoritative.

## The bet being made

The bet is that **LangGraph's invariants are the product, and its Python is an accident.**
The BSP super-step loop is small in any language. What is hard — barrier atomicity, write
visibility at N+1, deterministic task identity, resume-by-call-index, fenced ownership,
effect ambiguity, and compatible checkpoint history — is language-neutral semantics that
survive porting intact. Everything above that layer is where Ruby should diverge freely and
does: `throw`/`catch` inside each task execution boundary instead of exception-based
interrupts, blocks instead of callback-handler hierarchies, `Data.define` instead of
Pydantic, one method family instead of sync/async twins, and duck typing instead of
abstract base classes.

If the bet is right, the Ruby stack is a quarter of the size with the same guarantees.
If it is wrong, the failure will show up as invariant tests we cannot make pass — which is
why the invariant suite is milestone two, not milestone eight.

## Where this comes from

This goal is the missing back half of the existing study in
the source research package recorded in [SOURCE](SOURCE).
That study completed chapters 1–4 (method, RubyLLM, LangChain, LangGraph) and stopped
before chapters 5–8 (synthesis, Ruby blueprint, Hermes blueprint, roadmap). This design
folder delivers that content as working design documents rather than report prose. See
[README.md](README.md) for the mapping.
