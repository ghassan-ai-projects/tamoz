# Phase 0–2 implementation review

Date: 2026-08-20
Status: partial; the global implementation bar is not met.

This record captures the implementation and review loop for the first governed
adaptive-read-only slice. It is deliberately not a completion claim for the
plan. Phases 3–5 remain outstanding, and the Phase 0–2 exit bars still require
the vertical-slice and restart evidence described in their phase documents.

## Scope delivered

- Added the implementation bar in `00-implementation-bar.md` and linked the
  phased plan from the study README.
- Added closed-world capability descriptors, sealed registry admission, typed
  inventory reasons, and non-connecting MCP `peek` versus explicit `build`
  materialization.
- Added request-bound logical identity and execution-bound attempt identity
  through the durable effect dispatcher, SQLite journal, and graph records.
- Added checkpoint schema version 2. Old checkpoint records are rejected; no
  compatibility reader or row backfill was added.
- Added the bounded adaptive read-only graph, typed observations, provenance,
  truncation metadata, evidence references, lifecycle events, safe terminal
  reasons, and CLI opt-in routing.
- Added typed MCP outcome handling with remote provenance and credential-shaped
  output redaction at the journaling boundary.
- Added focused contract, inventory, identity, adaptive-session, MCP, record,
  CLI, and regression tests.

## Review loop

The requested specialist passes were completed before this record was written:

1. Plan critique: found late materialization, incomplete identity dimensions,
   CLI/Telegram lifecycle drift, descriptor policy gaps, and weak provenance.
2. Plan improvement: revised the acceptance bar and phase documents around
   those gaps.
3. Implementation pass: delivered the initial Phase 0–2 slice.
4. Three reviews: code quality, feature completeness, and gaps.
5. Repair pass: fixed durable provenance propagation, descriptor preflight,
   strict integer validation, checkpoint versioning, real attempt identity,
   adaptive terminal behavior, MCP source binding, inventory health, and
   remote-output redaction.

The implementation pass was performed against the shared working tree. No
review result is treated as provider or intelligence evidence.

## Verification

Focused commands passed:

```text
/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/memory_engine_test.rb
23 runs, 150 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec rubocop --cache false [30 touched production files]
30 files inspected, no offenses detected
```

The other focused suites for adaptive sessions, session records/effects,
capability descriptors/registry/host/inventory, MCP binding/source/adversarial
behavior, effect identity, durable compatibility, memory integration, and CLI
were green during the review loop. `git diff --check` was also green.

The repository-wide `rake ci` gate was not green. The actionable failures were
separated from this slice as follows:

- The local model, MCP HTTP, and Telegram fixture suites cannot bind
  `127.0.0.1` in this sandbox (`Errno::EPERM`, port 0). This prevents a real
  vertical-slice run here; it is environment-limited evidence, not a pass.
- The benchmark protocol divergence and the broken documentation link in the
  pre-existing repository quality-audit material were outside this change.
- M1 evidence cannot use `sandbox-exec` in this environment.
- Agent scorecard and memory-treatment failures remain repository/environment
  issues and were not relabeled as intelligence evidence.

Enola was rerun after the code changes:

```text
snapshot_id: sha256:27c66d015a17ce8371df6b46d01ebdcb7b56841c7c3ae46fcd1d840c2e319fec
enola: 0.2.7-51-g72cd079
facts: 9731; insights: 52; files parsed: 495/537; parse errors: 0
architecture diff: 0 new findings; +2 dependencies; +51 symbols; +521/-27 edges
```

The Enola scope check reported spillover because the change intentionally spans
the agent, core capability, tools, SQLite, graph, and test packages. That is
expected for the cross-gem identity contract, but it remains a review item.

## Bar status

| Bar item | Status | Evidence or blocker |
|---|---|---|
| Pure non-connecting capability inspection | Partial | Local inventory and MCP peek are covered; complete materialization/reachability evidence is not. |
| Bounded adaptive read-only loop | Partial | Durable graph and bounded observations are covered by focused tests; a live vertical slice is blocked by sandbox socket permissions. |
| Durable effect, observation, and lifecycle evidence | Partial | Schemas and lifecycle events exist; restart and compaction evidence is not complete. |
| Restart without duplicate effects | Not demonstrated | Requires the planned restart matrix with real durable execution. |
| Safe stop on denial, budget, malformed decision, and failure | Partial | Typed terminal paths and focused tests exist; cross-surface acceptance is outstanding. |
| Mutation handoff | Not started | Phase 4 owns governed mutation/delegation handoff. |
| CLI/Telegram semantic parity | Not demonstrated | CLI wiring exists; Telegram vertical-slice verification could not run here. |
| Measured intelligence | Not started | No real-provider benchmark result is claimed or generated. |

The next required work is Phase 3 lifecycle/compaction parity, then Phase 4
governed expansion, then Phase 5 benchmark plumbing and a matched real-provider
run. Until those are complete, the correct status is partial.

## Provenance and blind spots

- The source snapshot was generated from branch `codex/openclaw-intelligence-
  implementation` at working revision `514f4af1f777` with uncommitted changes.
- All model/provider behavior in the focused tests is fixture or fake plumbing.
  No real model run occurred, and no fixture result is presented as evidence
  that the agent is intelligent.
- Socket-restricted integration tests, Telegram parity, restart-across-
  compaction, and benchmark execution remain unverified.
- The pre-existing working-tree modification to
  `docs/openclaw-intelligence-study/README.md` is intentionally preserved and
  is not included in the implementation commit.
