# Implementation plan — OpenClaw intelligence study

Status: implementation in progress; Phases 0–5 have partial plumbing, and the
global implementation bar is not met.

This folder turns the completed study (`docs/openclaw-intelligence-study/`) into
implementation phases. The study's `04-tamoz-target-architecture.md` (stages 0–5)
and `05-comparison-and-priorities.md` (P0–P4) are the source; these files make
them executable: concrete work items mapped to real seams, tests, and a per-phase
exit bar.

The current partial slice is intentionally not an end-state claim: it adds
descriptor/identity, non-connecting MCP visibility, a durable adaptive
read-only graph, canonical turn/lifecycle/status contracts, bounded governed
database and child-record admission seams, and benchmark readiness checks.
The benchmark preparation slice also now includes a provider-agnostic mission
runner and strict evidence artifact validation; it does not supply real-provider
evidence.
Durable compaction, composed cross-surface execution, full governed expansion,
and real-provider evidence remain outstanding until their phase exit bars pass.

Read in this order:

1. [00-implementation-bar.md](00-implementation-bar.md) — the bar every phase must meet, global invariants, evidence rules.
2. [01-phase-0-authority-and-identity.md](01-phase-0-authority-and-identity.md) — close authority gaps before any breadth.
3. [02-phase-1-capability-visibility.md](02-phase-1-capability-visibility.md) — inspectable capability surface, peek/materialize/invoke.
4. [03-phase-2-adaptive-read-only-continuation.md](03-phase-2-adaptive-read-only-continuation.md) — the core intelligence change: Session re-decides after observations.
5. [04-phase-3-context-and-lifecycle.md](04-phase-3-context-and-lifecycle.md) — compaction, Telegram/CLI parity, progress projection.
6. [05-phase-4-governed-expansion.md](05-phase-4-governed-expansion.md) — new capability families, delegation, self-modification UX.
7. [06-phase-5-measured-intelligence.md](06-phase-5-measured-intelligence.md) — real-provider benchmark before any "more intelligent" claim.

## Delivery tracks and dependency order

The engineering path is one sequence: authority and identity, capability
visibility, adaptive continuation, context/lifecycle, then governed breadth.
The benchmark has a preparation track that may start after Phase 2, but its
final run and any intelligence claim wait for Phase 4. This distinction keeps
benchmark plumbing from becoming an accidental parallel implementation path.

| Phase | Study reference | Gate to enter | Concrete deliverable |
| --- | --- | --- | --- |
| 0 — authority and identity | Stage 0 / P0 | none | A complete descriptor contract, closed-world registration, and collision-free effect identity |
| 1 — capability visibility | Stage 1 / P1 | Phase 0 complete | Non-connecting inventory plus explicit materialization and typed availability reasons |
| 2 — adaptive read-only continuation | Stage 2 / P2 | Phases 0–1 complete; effect identity fixed | The first durable CLI/Telegram read-only vertical slice |
| 3 — context and lifecycle | Stage 3 / P3 | Phase 2 complete | Durable compaction and one canonical semantic lifecycle projection |
| 4 — governed expansion | Stage 4 / P4 | Phases 0–3 complete | Independently gated browser/database/delegation/self-modification families |
| 5 — measured intelligence | Stage 5 | Protocol plumbing after Phase 2; final execution after Phase 4 | Versioned matched/native benchmark artifacts and bounded claims |

Phase 5 may add fixture-only harness code after Phase 2 so that later phases
are measurable. It may not publish a capability or intelligence claim until
the final Phase 4 gate passes and the real-provider provenance requirements in
`06-phase-5-measured-intelligence.md` are satisfied. Breadth (Phase 4) is
explicitly last among engineering phases, per the study's decision to put
authority, durability, and observability before tool count.

## Change protocol

Before implementing a phase, inspect the named seam end to end, run Enola's
`generate_snapshot` and `set_baseline`, and record the baseline receipt in the
phase evidence manifest. After a structural code change, run
`generate_snapshot`, `compare_receipts`, and `diff_snapshot` before declaring
the phase complete. Documentation-only plan edits do not change the baseline.

Each work item is executable only when its phase file names all four of these:

- the existing seam being extended and the authority it owns;
- the durable record/state fields and bounded failure states;
- a test that proves plumbing, plus a real-provider proof when the item makes
  a model-behavior claim; and
- the committed evidence artifact and the command that generated it.

Do not add a new runtime, registry, journal, or domain catalog to satisfy a
work item. If a required seam is missing, the phase must first identify the
smallest extension to the existing owner and state why reuse is insufficient.

## First vertical slice

The first proof of the whole program is the study's recommended slice:
a read-only repository investigation mission through durable CLI and Telegram,
using the Phase 0–2 work. Its acceptance criteria are listed in
`03-phase-2-adaptive-read-only-continuation.md` and in the study's
`05-comparison-and-priorities.md` ("Recommended first vertical slice").

Every phase completion package belongs under
`docs/openclaw-intelligence-study/implementation-plan/evidence/phase-N/` and
contains a manifest with: phase status/date, git revision, Enola snapshot
receipt, exact commands and exit codes, test/quality-gate output digests,
changed files, generated-artifact digests, known blind spots, and a statement
separating fixture plumbing from real-provider evidence. Generated artifacts
are regenerated by their owning command; they are never hand-edited to make a
gate pass.
