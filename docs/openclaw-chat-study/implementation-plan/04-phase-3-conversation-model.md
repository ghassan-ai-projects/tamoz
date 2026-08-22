# Phase 3 — deepen the conversation model and prove recovery

Status: not started — no production code changed by this planning pass.
Requires: Phases 0–2 (the shared lifecycle, bounded progress, and visible
cancellation must be reliable first).

Study reference: Stage 3 (`../04-tamoz-target-architecture.md`), P3
(`../05-comparison-and-priorities.md`), root cause #7
(`../03-tamoz-current-state.md`: recovery is below the user interface). This phase
adds the deeper conversation controls **only after** the shared lifecycle is
trustworthy, and it proves cross-surface recovery and evidence end to end.

## Goal

Typed context controls (`/new`, `/reset`, `/compact`, `/usage`, `/context`,
`/think`, `/verbose`) have defined effects on session generations, prompt
history, budgets, and audit records, and are exposed identically-in-meaning on
both surfaces. CLI JSON preserves event identity for reconnection, and the full
cross-surface recovery/evidence composition is demonstrated.

## Required order

Define each control's typed semantics and audit effect before exposing it on
either surface. Add the durable/reconnectable status view's evidence contract,
then land the canonical full-composition test and the operational read model.
Do not expose a control whose effect on history, budget, or audit is undefined.

## Design constraints (from the study, binding)

- Context controls are typed session controls, not natural-language instructions
  (`../05`, "Controls are typed product features"). Each defines its effect on
  session generation, prompt history, budget, and audit before it ships.
- Extend the `Session` and command layer; do not add a parallel context store.
  `/new` and `/reset` operate on conversation generations without deleting audit
  history.
- Recovery exposes a read-only status and an actionable operator reference; a
  normal user never resolves an unknown effect or unknown delivery (`../04`,
  status read model).

## Work items

1. **Typed context controls.** Implement `/new`, `/reset`, `/compact`, `/usage`,
   `/context`, `/think`, and `/verbose` as typed controls. Define, per control:
   the effect on session generation and prompt history; the effect on budget and
   usage accounting; the audit-safe record it writes; and the projection it
   returns. `/compact` externalizes evidence and preserves authoritative facts;
   `/usage` and `/context` are read-only projections of durable accounting.
2. **Preserve event identity for reconnection.** Ensure CLI JSON carries the full
   `StreamPart` identity so a reconnecting client can resume an in-flight turn
   from the request reference and the last sequence, across both surfaces.
3. **Operational read model.** Add the durable telemetry/read model the study
   requires for diagnosis: queue age, lease loss/recovery, delivery-unknown rate,
   cancellation latency, and dropped-projection events. It is bounded, redacted,
   and derived from durable facts; it never invents state when a writer or reader
   is unavailable (invariant 12).
4. **Cross-surface recovery evidence.** Wire the evidence needed for the
   canonical full-composition test: real SQLite fixtures, worker recovery,
   provider failure, outbox ambiguity, duplicate update, and two isolated
   conversations, all projected through one lifecycle contract on both surfaces.

## Tests

- each context control has a typed-semantics test proving its defined effect on
  generation, history, budget, and audit, and that its meaning matches across CLI
  and Telegram;
- a reconnection test proves a dropped client resumes from the reference and last
  sequence without duplicating events or terminal delivery;
- the canonical full Telegram + durable CLI composition test (from
  `../06-scenario-matrix.md`) passes with real SQLite stores, a fake transport, a
  deterministic provider, worker recovery, provider failure, outbox ambiguity, a
  duplicate update, and two isolated conversations;
- an operational read-model test proves queue age, lease recovery,
  delivery-unknown, cancellation latency, and dropped-projection metrics are
  derived from durable facts and are bounded/redacted.

## Exit bar

- All four work items are done in the stated order; the context-control,
  reconnection, composition, and read-model suites are green under `rake ci` and
  `ci_full` in both locales.
- All twelve global invariants hold across the touched paths; every hard-zero in
  `00-implementation-bar.md` is covered by a named test.
- The canonical cross-surface composition test passes; two conversations cannot
  cross references, progress, approvals, or delivery.
- The evidence manifest records the test commands, changed files, and a statement
  that this phase proves plumbing only. Usefulness remains the benchmark's claim.

## Out of scope

Groups, media, multi-agent routing, and affirmative remote approvals (the
frontier round, `../benchmark-protocol/scenarios/frontier/`), and the published
usefulness verdict (the benchmark, run after this phase).
