# Scenario completion bar

This is the completion contract for the `scenarios/` directory. Read it before
adding or running a scenario.

A scenario is admissible only when all of the following hold:

1. **It has all five sections** — Setup, Task, Drive (moments), Verify (PASS), and
   Fail (hard-zeros) — and each Verify assertion resolves to a field a controller
   oracle can compute from the durable request/session/effect/outbox records or
   the emitted milestone stream, or is marked `INCOMPLETE` until the B0 harness
   emits it.
2. **Its oracle is controller-owned and deterministic.** The scenario scores
   durable evidence and the emitted lifecycle, never the subject's or the
   correspondent's self-report. On a fixed build, a fixture run of the scenario
   yields the same verdict every time.
3. **It names its fixture, its permission context, its injected moments, and its
   oracle.** Setup lists a deterministic, seed-pinned workspace/conversation
   fixture; the admission/permission context; the moments the driver injects
   (an acknowledgement wait, a restart, a duplicate update, an injection line, a
   cancellation); and the oracle that computes its metrics.
4. **It runs on both surfaces.** Every scenario is drivable on `cli` and
   `telegram`; `parity` is scored as equality of terminal task state and delivery
   outcome, never text similarity.
5. **It separates the two run kinds.** A `fixture` (deterministic provider, fake
   transport) run proves wiring and invariants and can never publish. A `real`
   (real provider, real transport) run is the only source of an experience claim,
   and it requires two agreeing witnesses.

A scenario PASS is one drive-through with its assertions held. A publishable
per-axis *claim* still needs the cell discipline of
[../01-protocol-design.md §6](../01-protocol-design.md#6-statistical-validity) —
a cell is `(scenario, surface, run_kind)`, and an under-sampled axis is
`inconclusive`, never a softened `go`. The scenario is the unit of evidence; the
cell is the unit of claim.

Any global hard-zero from
[../01-protocol-design.md §7](../01-protocol-design.md#7-hard-zero-gates) fires an
immediate failed run for the scenario, in addition to the scenario-local
hard-zeros.
