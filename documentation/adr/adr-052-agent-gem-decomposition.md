# ADR-052 — `tamoz-agent` is decomposed into focused, independently publishable gems

**Status:** Accepted 2026-08-26
**Date:** 2026-08-29 (recording a decomposition completed incrementally)
**Relates to:** ADR-002 (four v0.1 gems — **superseded by this ADR**), ADR-040 (one monorepo, many independently publishable gems — this ADR is an instance of that rule), ADR-025 (evaluation is a non-runtime gem), ADR-053 (approval isolated into its own gem).
**Tier:** F (see [ADR_QUALITY_BAR.md §3](./ADR_QUALITY_BAR.md))

The reference agent is no longer one `tamoz-agent` gem. It is a composition of focused
verticals, each with its own gemspec and dependency boundary. This ADR records the real gem
topology and supersedes ADR-002's "four v0.1 runtime gems," which the tree outgrew.

Current version: `0.1.0.alpha.1` (pre-release).

## 1. Context

ADR-002 fixed the v0.1 runtime at four gems (`tamoz-core`, `tamoz-graph`, `tamoz-sqlite`,
`tamoz-agent`) and said "optional packages earn promotion." That was the right shape for the
durable-runtime proof. But `tamoz-agent` then accreted every agent concern — deliberation,
sessions, capabilities, memory, healing, improvement, profiles, and the CLI — into one gem.
That violates ADR-040's own principle (each gem has an explicit manifest and dependency
boundary and can be packaged independently) and makes the agent's verticals impossible to
test, version, or reason about in isolation.

The corpus never recorded the split. As of this audit the tree ships **27 `tamoz-*` gems**;
ADR-002 still says four. The record was materially wrong about the system's shape.

## 2. Decision

**`tamoz-agent` is decomposed into focused gems, one per vertical, each independently
publishable with a one-directional dependency edge toward `tamoz-core`.** The reference agent
is the *composition* of these gems, not a monolith.

Agent verticals:

| Gem | Owns |
|---|---|
| `tamoz-agent-kernel` | Deliberation substrate: the record, receipt, and effect primitives every agent shares |
| `tamoz-agent-session` | The durable deliberation session (interrupt/pause/resume/compaction lifecycle) |
| `tamoz-agent-capabilities` | The capability bridge: local tools, skills, MCP, and websearch as sources (ADR-030, ADR-054) |
| `tamoz-agent-memory` | The memory vertical: `Memory::Engine`, layers, retrieval, promotion (ADR-026, ADR-027) |
| `tamoz-agent-healing` | Bounded self-healing (ADR-028) |
| `tamoz-agent-improvement` | Bounded self-improvement / candidate promotion (ADR-023) |
| `tamoz-agent-profile` | Operator-side trusted-profile validation and registries |
| `tamoz-agent-cli` | The `tamoz` executable: argument parsing, rendering, the interactive loop |
| `tamoz-agent` | The composition root that wires the verticals into the reference agent |

Foundational primitives extracted out of `tamoz-core` / `tamoz-agent` into their own gems:
`tamoz-tools` (workspace tool primitives), `tamoz-cancellation` (cancellation signals),
`tamoz-concurrency` (thread execution machinery), and `tamoz-approval` (ADR-053).

**Rule:** a new agent concern is a new gem with an explicit boundary, not another module
inside `tamoz-agent`. Dependency edges point toward `tamoz-core`; no vertical depends on the
CLI or on a sibling vertical it does not need.

## 3. Consequences

- Each vertical is testable, versionable, and reviewable in isolation — the ADR-040 promise
  made real for the agent layer.
- The composition root (`tamoz-agent`) is thin: it wires, it does not implement.
- The pre-1.0 compatibility matrix (ADR-040) now spans more gems; versions still change only
  for affected gems.
- **Coupling to watch.** The enola snapshot flags cyclic/high-coupling module clusters and
  several high-fan-in symbols (`Tamoz::Core` at 203 dependents; `Tamoz::Agent::Deliberation`
  at 21). Decomposition must not turn shared substrate into a hub that recreates the monolith
  by dependency. This is a standing check for `diff_snapshot` on future agent changes, not a
  regression this ADR introduces.
- Cost: 27 gems is more packaging surface than four. The boundary discipline is what buys the
  isolation; without it the split would be pure overhead.

## 4. Invariant linkage

- **ADR-040** — one monorepo, per-gem manifests, repository proximity grants no runtime
  dependency. This ADR is a concrete application; the acyclic-boundary intent of ADR-040 is
  the invariant the coupling check above defends.
- **Invariant 11** — the graph engine loads no LLM client; the decomposition keeps the model
  seam in the agent layer, never in `tamoz-graph`.

## 5. Rejected alternatives

| Rejected | Why |
|---|---|
| Keep everything in one `tamoz-agent` gem | Untestable and unversionable per vertical; violates ADR-040's own boundary rule; the monolith is what forced this ADR |
| Split by layer (all "models" in one gem, all "services" in another) | Cross-cuts every vertical; a memory change would touch three gems. Split by vertical keeps a concern in one gem |
| A plugin API for agent extensions | ADR-014 rejected a plugin API; verticals are first-class gems in the monorepo, not third-party plugins |

## 6. Verification

Verified against code: 2026-08-29 — `ls gems/` shows 27 `tamoz-*` gems including the nine
agent gems and the four extracted primitives above; each carries its own `*.gemspec` with a
role summary (quoted in §2). enola snapshot (13,405 facts) confirms the module topology and
flags the coupling clusters noted in §3.

## Next reads

- [`README.md`](./README.md) — the ADR index
- [`../architecture/gems.md`](../architecture/gems.md) — the gem map
- [`../architecture/overview.md`](../architecture/overview.md) — the layered stack
