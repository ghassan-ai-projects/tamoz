# 01 — Protocol design

This is the measurement model for the communication benchmark. It defines what is
being measured, how a run is made trustworthy, and how the result is protected
from drift and gaming. It answers one question honestly: **is the Tamoz chat
experience trustworthy and responsive, and is it improving over time?**

It exists because the study proved the *design* but never the *experience* —
every composition test to date runs a deterministic provider and a fake
transport, so it measures machinery, not what a correspondent actually feels.

## 1. What "trustworthy communication" means here

The study's working hypothesis is that OpenClaw feels useful because the
conversation is a durable work system, not a request/response wrapper. So the
benchmark does **not** measure a single satisfaction scalar. It measures eight
**canonical axes** — the single taxonomy used by the scenario catalog, the
verdict, and the scoreboard. Each scenario maps to one primary axis and may
contribute metrics to others.

1. **`identity`** — every accepted turn commits durably before acknowledgement
   and carries a stable, non-authorizing reference; inbound identity is correct
   (exact duplicate → one request; same-ID/different-content → durable conflict);
   the four Telegram IDs stay distinct.
2. **`liveness`** — a slow turn is never silent between accepted and terminal:
   bounded, coalesced, semantic milestones show it is alive, without streaming
   tokens or leaking internal detail.
3. **`delivery_truth`** — task state and delivery state are reported as separate
   axes; an ambiguous send is `unknown`, preserved, never blindly retried, never
   reported as success or as plain failure.
4. **`recovery`** — restart and cancellation are honest: a restart preserves the
   reference, sequence, and task state without duplicating an external send;
   cancellation shows requested → observed → terminal.
5. **`parity`** — the same turn through CLI and Telegram reaches a semantically
   equal outcome (terminal task state + delivery outcome), differing only in
   presentation.
6. **`commands`** — the command grammar and the handlers agree; every declared
   command works; typed controls have defined effects.
7. **`context_integrity`** — only confirmed successful terminal deliveries enter
   conversation history; untrusted message/callback content never expands
   authority, alters a plan, or forges approval evidence; two conversations never
   cross.
8. **`cost`** — latency to first acknowledgement and to terminal, and the number
   of projected updates, for the same outcome. The tie-breaker axis: lower is
   better, and it never outranks correctness (a chattier system is not more
   trustworthy for sending more messages).

"More responsive" or "more trustworthy" is a claim about a *named axis*, never an
unqualified superlative.

## 2. Two tracks (both required for a published claim)

### Track A — composed plumbing (the invariant gate)
A deterministic provider and a **fake transport** (recorded requests, no real
egress) drive the real Gateway/Worker/Drainer/Session seams. This isolates the
**communication contract** from provider and network variability. It proves the
invariants and the scoring math. It can **never** publish a usefulness claim — a
fake-transport run is marked `fixture` and refused publication.

### Track B — real usefulness (the honest experience report)
A real provider behind a real durable session, delivered over a real transport
(or a recorded live-transport session), run through a supported user surface.
This is the **only** source of a liveness/usefulness claim. It records latency,
the visible lifecycle updates a correspondent actually received, answer quality,
and recovery behavior — separately from Track A.

A Track A pass is a precondition; a Track B run is the claim. A green Track A is
never relabeled as a Track B result.

## 3. The state-axis model (task truth vs delivery truth)

Every scenario records the turn as two independent axes, not one status:

- **task state** — `accepted → queued | running | waiting | blocked → completed |
  failed | stopped`;
- **delivery state** — `pending | delivered | failed | unknown`.

The oracle reports each axis independently and names the terminal reason. This is
what prevents `completed + delivery=unknown` from being averaged into a `failed`
or a `success`. A run that reaches `completed` task state but leaves delivery
`unknown` is a *delivery* outcome, scored as such, not a task failure.

## 4. Fixture vs real separation (the honesty firewall)

`run_kind` is `fixture` or `real`. The two never share an artifact root
(`fixtures/` vs `real/`).

- **fixture** runs use a deterministic provider and a fake transport. They prove
  the composition, the scenario wiring, and the scoring math. They are refused
  publication. The canonical composition tests
  (`../../../docs/openclaw-chat-study/06-scenario-matrix.md`, "Required composition tests") are the fixture gate
  and stay exactly that.
- **real** runs use a real model and a real transport. They are the only source
  of a usefulness claim. Publication requires, per scenario: durable request,
  session, effect, and outbox receipts read **without advancing** the turn; an
  independent observability trace; and — for a parity claim — a recorded outcome
  on **both** surfaces.

A real run that cannot produce that evidence is `blocked`, not `passed`.

## 5. Provenance and evidence rules

Every scenario run records:

- provider/model identity, transport class (fake vs real), git revision, graph
  name+version, protocol digest;
- the turn and the admission/permission context;
- the request reference and the two state axes at every transition;
- the projected lifecycle milestones actually emitted per surface (bounded and
  coalesced), and the delivery receipts (with `unknown` states preserved);
- task outcome, delivery outcome, and per-axis metrics;
- cost: latency to first acknowledgement, latency to terminal, update count.

Two independent witnesses must agree before a real run is publishable:

1. the durable **request/session/effect/outbox receipts** read from the stores
   without advancing the turn, and
2. the independent **observability trace**.

Divergence between the two is `artifact_mismatch` — a hard-zero.

## 6. Statistical validity

The benchmark reuses the study's evidence discipline rather than inventing new
statistics:

- a **cell** is `(scenario, surface, run_kind)`; one scenario drive-through is one
  sample; the first attempt is scored and failures are never replaced;
- fixture cells are deterministic — a scenario's oracle must produce the same
  verdict on repeated runs of the same build, or the scenario is not admissible;
- real cells accumulate over runs; a single real drive-through is one data point,
  and a usefulness claim states the number of runs behind it;
- binary metrics (`completion`, `parity`, `no_blind_retry`) are reported as
  pass-rates with the run count, never softened into a scalar.

A usefulness claim names its axis, its track, and its sample count. Anything less
is `inconclusive`.

## 7. Hard-zero gates

Any occurrence fails the run outright (from the study's hard-zero list,
`../../../docs/openclaw-chat-study/implementation-plan/00-implementation-bar.md`):

`ack_before_admission`, `stale_owner_send`, `blind_retry_after_unknown`,
`unknown_reported_as_terminal`, `identity_conflict_deduplicated`,
`unconfirmed_output_in_history`, `phantom_command`, `authority_from_content`,
`artifact_mismatch`, `fixture_published_as_real`.

A hard-zero is reported as a failure of *that run*, never averaged. The report
names the fired rule; an invalidated run blocks publication regardless of the
other cells.

## 8. Anti-gaming threat model

The benchmark must survive a change that optimizes for the score rather than the
experience:

| Attack | Defense |
| --- | --- |
| Faking a delivery success to raise `delivery_truth` | Two independent witnesses must agree; delivery receipts are read from the outbox without advancing the turn; `artifact_mismatch` hard-zero. |
| Coalescing away real silence to pass `liveness` | `liveness` is scored from committed worker facts vs emitted milestones; a projected milestone with no backing committed fact is `fabricated`, and a silent gap over the bound fails the axis. |
| Passing `parity` by matching message text | `parity` is equality of terminal task state + delivery outcome, never text similarity of the emitted messages. |
| Blindly retrying an ambiguous send to look "delivered" | `blind_retry_after_unknown` hard-zero; `unknown` must be preserved and reconciled by an operator. |
| Publishing a fake-transport run as real | Separate artifact roots; `fixture_published_as_real` hard-zero; real publication requires real receipts + an independent trace. |
| Drifting the protocol/catalog to pass a gate | The protocol and catalog are digest-pinned; any threshold or scenario edit is a reviewed, digest-visible change. |
| Letting untrusted content widen authority to "help" | `authority_from_content` hard-zero; message/callback content is data, never a plan/approval/authority source. |

## 9. Longitudinal design (improving over time)

The benchmark is a scoreboard, not a one-shot gate:

- **Versioned artifact roots.** Every run writes under `real/<date>-<git-sha>/`,
  bound to the exact build, so runs are comparable across time.
- **A committed scoreboard.** A small, append-only summary (per-axis metric +
  verdict + provider/model + transport class + git-sha) is committed after each
  accepted real run, so a later change that lowers an axis is a visible
  regression and an improvement is a dated, attributable delta (see the scoreboard
  spec in [02-scenario-catalog-and-scoring.md](02-scenario-catalog-and-scoring.md#longitudinal-scoreboard)).
- **Provider and transport drift are confounds, recorded not hidden.** The model
  and the live Bot API are moving targets; each scoreboard entry records the
  provider-reported model version when available and the transport class, so a
  trend break that coincides with an upstream change is annotated, not silently
  attributed to Tamoz.

The deterministic Track A composition tests remain the *fast* regression gate on
every commit; the real-transport scoreboard is the *slow* experience trend, run
on a cadence, never on every commit.
