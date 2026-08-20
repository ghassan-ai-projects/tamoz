# Phase 4 — governed expansion

Status: partial as of 2026-08-20. Requires: Phases 0–3; exit bar not met. This phase is deliberately last
among engineering phases — breadth only after measured composition works.

Study reference: Stage 4 (`04`), P4 (`05`).

## Goal

New capability families and delegation enter only as operator-owned, fully
described capability sources. Nothing in this phase weakens a Phase 0
invariant.

The current slice adds read-only database admission policy through the existing
MCP source builder and a durable child request/adoption path with narrowed
local authority. It does not yet implement governed web/browser or
self-modification flows, child restart evidence, or real-provider family
evidence.

## Work items (each independently shippable, in this order)

1. **Governed web/browser.** Add a separate operator-owned source adapter in
   `tamoz-mcp`/`tamoz-agent` using the existing `mcp_tool` descriptor kind and
   `mcp:<server>/<tool>` source shape, with explicit egress/SSRF policy, read
   semantics, budgets, and untrusted-content fencing. This is not a generic
   HTTP tool and does not add a fifth registry kind.
2. **Governed database.** Add read-first database access through a supervised
   MCP/source adapter using the existing descriptor/dispatcher contract, with
   explicit read/write semantics, query/row/byte budgets, and egress. Never raw
   SQL against internal Tamoz state (non-goal).
3. **Durable child tasks.** Delegation as durable child requests owned by the
   request-inbox/scheduler seam, with parent
   reference, narrowed capability/profile snapshot, depth/concurrency budget,
   independent effect identities, terminal receipts, and explicit completion
   adoption into the parent. No in-memory child registry as authority.
4. **Candidate-only self-modification.** Profile/skill/config proposals follow
   propose → validate → human approval → durable apply → restart/health verify
   → activate/rollback, reusing the existing candidate/promote seams
   (`profile/`, `improvement/`). Workspace content and model output cannot
   widen authority. Apply, restart-health, activation, and rollback are
   separate durable effects; a crash after apply and before activation is
   `unknown` and requires reconciliation.
5. **Richer messaging/external effects.** Only as additional governed sources
   with complete Phase 0 descriptors.

Explicitly deferred beyond this phase: package/runtime self-update — needs its
own dedicated approval, rollback, and restart-health program first.

## Tests

- each new family: descriptor completeness enforced (Phase 0 gate), approval
  binding, egress denial, untrusted-content fencing, unknown-outcome handling
  for non-idempotent remote effects;
- web/MCP mission (matrix scenario 5): bounded output, provenance, cooldown/
  reconnect, no replay of ambiguous remote mutation;
- child task: narrowed authority enforced, restart of child resumes without
  duplicate effects, parent adopts completion exactly once;
- self-modification mission (matrix scenario 9): candidate proposed, approved
  with exact digest, applied, restart-verified, rollbackable; model/workspace
  content cannot widen authority.
- dependency-isolation tests prove the new adapters stay behind existing gem
  contracts and do not introduce a parallel runtime, registry, or journal.

## Exit bar

- Each shipped family passes its scenario with fixtures plus one recorded
  real-provider run; fixture and provider artifacts are separate.
- All Phase 0 invariants re-verified against the new sources.
- `rake ci`, `ci_full`, `rubocop`, `enola check` clean.

## Out of scope

Package/runtime self-update, any loosening of approval binding, any new
execution runtime.
