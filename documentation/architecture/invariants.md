# Invariants

Sixty-one clauses define the compatibility and correctness surface of Tamoz, and they are executable: each clause is backed by named conformance tests that the release audit runs. This page summarizes the contract by theme. The authoritative, full text — every clause's required behavior, the failure it prevents, and the conformance test shape — lives in the design archive at [../../docs/design-v0.1/INVARIANTS.md](../../docs/design-v0.1/INVARIANTS.md).

Current version: `0.1.0.alpha.1` (pre-release). These semantics may change only through an ADR with a migration and new conformance tests.

## What the contract governs

### Execution and state (clauses 1–8)

Barrier atomicity, write visibility at N+1, deterministic task and commit order, node restart from the top, resume by call index, reducer-mediated state edits, additive routing, and fail-fast on conflicting writes. A channel receives all of a super-step's writes in one update; step N reads one frozen snapshot whose writes become visible only in step N+1.

### Runtime isolation and control flow (clauses 9–15)

Strict backend-assigned checkpoint sequence, top-level persistence ownership (subgraphs share one backend), **LLM-independent engine** (clause 11 — a load-time invariant: requiring `tamoz/graph` loads no RubyLLM, HTTP client, provider, or adapter; run-time capability injection via node callables and `context.effects` is by design), worker-local interrupt capture via `throw`, immutable isolated input, no ambient tenant state, and streaming as one bounded projection that commits identical bytes.

### Durability and compatibility (clauses 16–22)

Prompt-cache stability per epoch, typed tool-failure boundaries, versioned allowlisted records, atomic compare-and-append commit, one fenced writer per thread, replay-safe effects or explicit ambiguity (the `:unknown` state), and graph compatibility before resume. Crash equivalence is defined at committed barriers; clause 21 controls whether replay of work after the last barrier is safe.

### Security and external input (clauses 23–24)

External inputs are identified and deduplicated with durable queue order; sensitive data is explicit — secret values are rejected from checkpoints, streams, and instrumentation, never scrubbed by key name.

### Deliberation, verification, and learning (clauses 25–28)

Reviewed plans gate every task action; material change requires re-review; material completion requires evidence; self-improvement is evaluated, versioned, and reversible. A failed check is evidence for at most two newly reviewed repairs with fresh approvals; a repeated action or failure stops safely.

### Durable memory (clauses 29–31)

Memory promotion is layered and attributable (Experience | Knowledge | Wisdom); retrieval authorizes before ranking; correction and deletion propagate with proof. Wisdom changes only through evaluated behavior transition.

### Bounded self-healing (clauses 32–34)

Remediation is typed, reviewed, authorized, and bounded; recovery means the original invariant was independently verified by a rule-supplied verifier, never by the remediation model; healing rules earn authority through staged evaluation (replay → shadow → fault injection → canary → active) and cannot promote themselves.

### Capability and MCP boundaries (clauses 35–37)

Capability authority is local, intersected, and content-addressed; MCP protocol and catalog snapshots are explicit and pinned; MCP calls preserve Tamoz authorization, durability, and uncertainty. Remote annotations are untrusted.

### Durable scheduling (clauses 38–40)

A due time creates exactly one logical occurrence and request; civil time, misfire, overlap, and backlog semantics are explicit and bounded; scheduled authority cannot widen while delayed or unattended. The scheduler materializes occurrences into the ordinary request inbox and never executes work itself.

### Skills (clauses 41–43)

Skills are portable, source-qualified, content-addressed snapshots; skill content never grants authority or escapes its tree; skill install, update, and self-improvement are staged and evaluated.

### Streaming input and physical-world action (clauses 44–51)

Input streams are not execution streams or user channels; every observation is authenticated, typed, bounded, and durably admitted; temporal truth is explicit and replayable; partition transitions and Situations are deterministic and atomic; backpressure and evidence gaps are bounded and visible; cognition is admitted against one immutable Situation snapshot; models propose typed intents while current deterministic policy owns physical dispatch; safety control and replay authority remain outside cognition.

### Cross-cutting implementation blockers (clauses 52–58)

Logical activation identity survives interruption and retry; the request inbox is durable, ordered, and redirect-safe; thread deletion preserves effect truth; discovery is reviewed, read-only, and cannot authorize action; a user channel is identified, bound, and grants nothing; channel delivery is ordered, bounded, and ambiguity-safe; a channel decision is exact, expiring, and cannot widen authority.

### Observability (clauses 59–61)

Observation cannot change execution, and its surface is bounded and versioned (a closed signal catalog); telemetry is redacted by construction with content capture as an explicit named policy; safety-bearing observability is derived from durable evidence, correlated by durable identity, and never overstates what it measured.

## The release contract within the 61

- **Foundation clauses 1–27 and correction clauses 52–55** are the v0.1 release contract.
- **Memory/skill clauses 29–31 and 41–43** become mandatory for v0.2.
- **Improvement/healing clauses 28 and 32–34** become mandatory for v0.3.
- **MCP clauses 35–37, scheduling clauses 38–40, and streaming clauses 44–51** are fixed conditional conformance: they become release-blocking when their optional packages are promoted.
- An unavailable feature never pretends to pass its clauses.

## The fault model

The suite tests process termination, raised exceptions, cancellation, lost lease, storage busy/full/corrupt responses, serializer rejection, and delayed worker completion. It does **not** claim to survive loss of the underlying database file without a backup, Byzantine adapters, or a remote effect that is both non-idempotent and impossible to reconcile.

## Change control

Changing an invariant requires: (1) an ADR describing the user-visible break; (2) a checkpoint and graph migration or a deliberate fail-fast boundary; (3) conformance tests for old and new behavior; (4) release notes naming the earliest affected format and graph versions. Correctness contracts are not cut to hit a concept-count target.

## Next reads

- [../../docs/design-v0.1/INVARIANTS.md](../../docs/design-v0.1/INVARIANTS.md) — the authoritative full text
- [../../docs/design-v0.1/DECISIONS.md](../../docs/design-v0.1/DECISIONS.md) — the ADRs that shaped the clauses
- [security-model.md](security-model.md) — the boundary in prose
- [../governance/quality.md](../governance/quality.md) — how the contract is graded
