# Tamoz

Tamoz is a Ruby-native durable agent framework: checkpointed, interruptible, observable, and evaluation-governed AI workflows. This page explains what Tamoz is, what it is not, who it is for, and why it exists.

Current version: `0.1.0.alpha.1` (pre-release). Read [../limitations.md](../limitations.md) before building on it.

## What Tamoz is

An agent turn is a **graph run over a SQLite-backed checkpoint store**. The run survives `kill -9`, resumes from its last committed barrier, and reconciles an interrupted side effect from proven state rather than guessing. Three properties make that possible:

- **A durable graph engine** (`tamoz-graph`) with barrier-atomic super-steps, deterministic task identity, interrupts, replay, and subgraphs. It is a general durable-execution runtime: it never loads an LLM client, so it stays testable offline and reusable for non-LLM workflows.
- **A deliberative agent layer** (`tamoz-agent`) on top: reviewed plans, approval gates, verification, three-layer memory, bounded self-healing, and the `tamoz` CLI.
- **One honest durability story**: checkpoints make *state* durable, not external effects exactly-once. Effects carry stable identities and replay safety; an ambiguous non-idempotent effect stops as `:unknown` and waits for a human decision rather than being retried blindly.

Nothing acts without a reviewed plan bound to its canonical digest, and nothing changes a file without an approval you granted for that exact diff.

## What Tamoz is not

- **Not an exactly-once distributed transaction system.** Tamoz cannot atomically commit an arbitrary remote side effect and its local receipt. It provides idempotency keys, journaling, reconciliation, and a safe `:unknown` state.
- **Not a rewrite of `ruby_llm`.** RubyLLM supplies providers, messages, tools, and streaming; Tamoz supplies the durable execution runtime above it.
- **Not a LangChain port.** The capabilities are the product, not the vocabulary — there is no `Runnable` matrix, no chain subclass zoo, no async twin APIs.
- **Not a multi-tenant hosted platform.** Single operator, many sessions. No auth server, no billing, no team workspace.
- **Not a certified or hard real-time controller.** Physical-world control is advisory and simulated; emergency stops and interlocks remain external and authoritative.
- **Not a plugin marketplace.** The capability registry is a closed set of four built-in sources — local tools, skills, MCP servers, websearch — sealed at session construction.

## Who it is for

- **Operators running a personal or team agent** who need turns that survive restarts, approvals they can audit, and effects that never repeat blindly.
- **Ruby developers building durable agent workflows** who want the graph/checkpoint semantics without reimplementing barrier atomicity, leases, fencing, and effect journals.
- **Engineers integrating models, MCP servers, or scheduled work** who want one governed capability boundary instead of wiring each integration into the agent loop.

## Why it exists

The design goal states it directly: build a small, readable, Ruby-native durable agent runtime over RubyLLM that is safe under crash, resume, concurrency, and human approval — and prove every guarantee with an executable conformance suite.

The bet behind the project is that **LangGraph's invariants are the product, and its Python is an accident.** What is hard — barrier atomicity, deterministic task identity, resume-by-call-index, fenced ownership, effect ambiguity, compatible checkpoint history — is language-neutral semantics. Ruby's `throw`/`catch` makes interrupts structurally uncatchable by `rescue`; `Data.define` and plain Hash state keep the runtime small. The reference application, Tamoz Agent, is the honest specification of the framework: every framework primitive exists because the agent needs it.

## The guarantees in one paragraph

- **Crash-safe.** A killed process resumes from its last committed checkpoint.
- **Reviewed.** Every task action follows a reviewed plan; every file change follows an approval for that exact diff.
- **Effect-safe.** Replay-safe effects converge; ambiguous effects stop and wait for you.
- **Bounded.** Budgets, queues, signals, memory, and self-healing are bounded and observable.
- **Evaluated.** Runtime correctness and agent behavior are compared against versioned evidence before release claims are made.

## Next reads

- [../getting-started/quickstart.md](../getting-started/quickstart.md) — install, ask, and try an approved change
- [concepts.md](concepts.md) — the core mental model
- [../architecture/overview.md](../architecture/overview.md) — the layered stack
- [../limitations.md](../limitations.md) — what Tamoz does not do
- [../../README.md](../../README.md) — the repository entry point
