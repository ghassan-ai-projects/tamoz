# C6 — Cross-surface parity

**Difficulty:** rung 6 (advanced tier). **Primary axes:** `parity` (with `parity`
as the gating metric). **Scenario:** `cross-surface-parity`. **Surfaces:** `cli`,
`telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`C6`; state
`INCOMPLETE` until the B0 scenario runner and oracle exist).

## The pitch

The same accepted turn should mean the same thing in Telegram and CLI. A naive
path invents independent per-surface state — a CLI that considers the turn done
while Telegram still shows it running, or a Telegram cancel that the CLI never
observes. This rung runs one durable turn through both surfaces and asserts
semantic equality of the outcome, not of the presentation. Parity is scored as
equality of terminal task state and delivery outcome — never text similarity of
the emitted messages.

## Setup (driver materializes)

- **Conversation fixture** (seed-pinned): one bound correspondent and one durable
  thread reachable from both the durable CLI and the Telegram gateway; real SQLite
  stores, a deterministic provider, and a fake transport.
- **Admission context:** paired correspondent; the shared state vocabulary and
  reason-code registry from Phase 1.
- **Oracle:** controller-owned; compares the terminal task state, terminal reason,
  cancellation semantics, and delivery outcome from the two surface executions.

## Task (handed to the subject)

> Run one durable turn, observed through both surfaces, including a cancellation
> and a terminal answer.

## Drive (moments — the driver injects these in order)

1. **M1 · Dual observation.** Submit the turn and observe it from both surfaces.
   Both show the same lifecycle vocabulary and the same request identity.
2. **M2 · Terminal reason.** Let the turn complete. The terminal task state and
   reason are equal across surfaces; presentation may differ (a CLI line vs a
   Telegram message).
3. **M3 · Cancellation semantics.** Re-run and cancel from one surface. Both
   surfaces observe the same requested → observed → terminal cancellation
   semantics and the same context-inclusion rule.

## Verify (PASS — driver asserts on the artifact)

- `metrics.parity == 1` — equality of terminal task state and delivery outcome
  across `cli` and `telegram`.
- terminal reason and cancellation semantics are equal across surfaces.
- `metrics.context_inclusion == 1` on both surfaces — the same confirmed-delivery
  history rule applies.
- `metrics.reference_stability == 1` — the same reference identifies the turn on
  both surfaces.

## Fail (hard-zeros — any one fails the run)

- `parity_by_text` — the oracle used message text similarity instead of terminal
  state equality (a harness defect; fails the scenario).
- divergent terminal task state or delivery outcome between surfaces.
- a cancellation observed on one surface but not the other.

## Reading the result

- **PASS** — one meaning, two renderers. Parity holds.
- **PARTIAL** — equal terminal state but a divergent reason code or cancellation
  visibility. Record the divergence.
- **FAIL** — the surfaces disagree on the outcome, or parity was scored by text.
  Localize the diverging surface execution.
