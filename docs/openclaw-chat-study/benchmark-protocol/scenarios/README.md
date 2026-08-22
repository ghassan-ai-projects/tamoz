# Agent-drivable communication scenarios

The completion contract for this directory is
[00-implementation-bar.md](00-implementation-bar.md). Read it before adding or
running a scenario.

These are runbooks a capable external agent (OpenClaw, or any driver) can follow
autonomously to **set up, run, and verify** a communication-benchmark scenario,
applied to the catalog in
[../02-scenario-catalog-and-scoring.md](../02-scenario-catalog-and-scoring.md).

Each scenario is one rung on a difficulty ladder. A driver runs them in order;
each rung adds one hard thing on top of the last, so a failure localizes to the
contract the new rung introduces.

## Two roles — do not conflate them

- **Subject** — the Tamoz communication path under a real provider and transport.
  It *handles the turn* and is the thing being measured. It never scores itself.
- **Driver** — the external agent following the runbook. It *prepares the fixture,
  submits the turn through a surface, and verifies the artifacts* against the
  assertions. The driver never handles the turn.

A scenario is PASS/FAIL about the **subject**, established by the **driver**
reading deterministic, controller-owned evidence.

## The difficulty ladder

| Rung | Scenario | Primary axes | New hard thing |
| --- | --- | --- | --- |
| C1 | [C1-happy-path.md](C1-happy-path.md) | `identity`, `delivery_truth` | Admit durably before acknowledging; return a stable reference; keep task and delivery state distinct. |
| C2 | [C2-slow-liveness.md](C2-slow-liveness.md) | `liveness`, `cost` | Show a slow turn is alive with bounded, coalesced milestones — no silence, no token stream. |
| C3 | [C3-delivery-fault-matrix.md](C3-delivery-fault-matrix.md) | `delivery_truth`, `recovery` | Pre-send fail, post-send `unknown`, stale-owner takeover, permanent auth failure — no blind retry. |
| C4 | [C4-restart-boundary-matrix.md](C4-restart-boundary-matrix.md) | `recovery` | Restart at every durable boundary with no duplicate send and a preserved reference. |
| C5 | [C5-first-contact-and-controls.md](C5-first-contact-and-controls.md) | `commands`, `context_integrity` | Unknown sender, conflicting identity, and every declared command — and untrusted content changes nothing. The milestone. |

C5 is the **milestone**: the first rung where untrusted correspondent/callback
content actually reaches admission and command handling, and the whole point is
that it **grants no authority** and every declared command works. If only one
rung is run for a trust-grade result, run C5.

### Advanced tier (C6–C9) — the composed contracts

C1–C5 establish the per-contract floors. The advanced tier composes them the way
a real conversation does, where the naive implementation passes each floor alone
but fails the composition.

| Rung | Scenario | Primary axes | Why the naive path fails |
| --- | --- | --- | --- |
| C6 | [C6-cross-surface-parity.md](C6-cross-surface-parity.md) | `parity` | The same turn on CLI and Telegram must mean the same thing; independent per-surface state drifts. |
| C7 | [C7-approval-waiting.md](C7-approval-waiting.md) | `context_integrity`, `commands` | A waiting turn must name reason + next action, bind the decision to evidence, and keep deny fail-safe. |
| C8 | [C8-cancellation-states.md](C8-cancellation-states.md) | `recovery` | Requested → observed → terminal; a naive path claims "cancelled" while an external call is still in flight. |
| C9 | [C9-two-conversation-isolation.md](C9-two-conversation-isolation.md) | `context_integrity`, `parity` | Two concurrent conversations must not cross references, progress, approvals, or delivery. |

Run the advanced tier **after** C1–C5 pass on the same build: a C6+ failure is
only interpretable once the floors hold.

### Frontier round (F1–F3) — capabilities Tamoz does not have yet

C1–C9 measure what Tamoz can or nearly can do. The **frontier round** in
[frontier/](frontier/README.md) measures what it **cannot do yet** — groups, rich
media, and multi-agent/affirmative-approval routing — so the benchmark pulls the
roadmap forward instead of only guarding what works. Each F scenario fails
**honestly** today (fail-closed, with a named reason), names the smallest
increment to an existing seam that closes the gap, and defines the
machine-checkable PASS once built. When an F scenario starts passing on a real
run, it **graduates** into the ladder and the scoreboard records the date the
capability came online.

## How a driver runs one scenario

Every scenario has the same five sections, executed top to bottom:

1. **Setup** — materialize the conversation/workspace fixture and the admission
   context the scenario names. Fixtures are deterministic and seed-pinned.
2. **Task** — the exact turn handed to the subject.
3. **Drive** — the ordered moments the driver injects (an acknowledgement wait, a
   restart, a duplicate update, an injection line, a cancellation). Each moment
   names the surface (`cli` or `telegram`).
4. **Verify (PASS)** — machine-checkable assertions on the durable records and the
   emitted milestone stream.
5. **Fail (hard-zeros)** — any one is an immediate failed run, never averaged.

The driver reads results from the scenario artifact + manifest produced by the B0
scenario runner, cross-checked against the independent observability trace. Two
witnesses must agree (see
[../01-protocol-design.md §5](../01-protocol-design.md#5-provenance-and-evidence-rules)).
`SCENARIO_INDEX.json` is the contract index and is not yet consumed by a runner;
until B0 binds a scenario ID and controller oracle into the artifact, an ordinary
comms test run must not be relabeled as scenario evidence.

**One drive-through is one sample.** A publishable per-axis *claim* still needs the
cell discipline of [../01 §6](../01-protocol-design.md#6-statistical-validity).

### The verification surface (what the driver asserts against)

Every assertion resolves to a field the harness emits, or is marked `INCOMPLETE`
until the B0 fixture/oracle implementation adds that field:

| Assert on | Source |
| --- | --- |
| Scenario `status` (`ready`/`blocked`/`failed`/`unavailable`) | scenario artifact |
| Per-axis `metrics` (`identity`, `liveness`, `delivery_axis`, …) | scenario artifact |
| Two state axes (task state, delivery state) at each transition | durable request/session/outbox records |
| Emitted lifecycle milestones per surface (bounded, coalesced) | `StreamPart` / outbox milestone stream |
| Delivery receipts (owner/fence/attempt, `unknown` states) | `CommsOutbox`, read without advancing the turn |
| `hard_zero` list (which stop rules fired) | scenario artifact |
| Independent trace digest bound to the scenario digest | observability trace |

### Commands (real run)

Until B0 builds the scenario runner and oracles, there is intentionally no fixture
command to copy, and the index marks all scenarios `INCOMPLETE`. The real-run
entrypoint fails closed with a typed reason until the plan's phases land — which is
the correct behavior; it never emits a fabricated verdict. A driver must not label
an ordinary comms test run as scenario evidence.

Both tracks (composed plumbing, real usefulness) apply; a scenario's verdict is
per-axis, and a green Track A composition is a **floor claim**, never an
experience claim (see
[../02 §Verdict rule](../02-scenario-catalog-and-scoring.md#verdict-rule)).

## Reading the ladder's result

- **PASS** — every rung green on a real run: the subject admits durably,
  projects one coherent lifecycle, keeps task and delivery truth distinct,
  recovers honestly, and treats untrusted content as inert. Headline: *the
  communication contract is correct, honest, and injection-inert under a real
  model and transport.*
- **PARTIAL** — a rung fails on a *contract* boundary (e.g. C4's restart leaks a
  duplicate send, or C2 goes silent past the bound). A real, nameable finding —
  record the axis and the artifact.
- **FAIL** — a hard-zero fires: an acknowledgement preceded admission, a stale
  owner sent, an `unknown` was reported as terminal, unconfirmed output entered
  history, or content widened authority. Localize where, exactly, in the trace.
