# C2 — Slow-turn liveness

**Difficulty:** rung 2. **Primary axes:** `liveness`, `cost` (with
`progress_bound` as the gating metric). **Scenario:** `slow-liveness`.
**Surfaces:** `cli`, `telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`C2`; state
`INCOMPLETE` until the B0 scenario runner and oracle exist).

## The pitch

A slow turn separates a work system from a request/response wrapper — and a naive
path gets it wrong in two opposite ways. It either goes silent from
acknowledgement to terminal (the user resends or assumes failure), or it floods
the channel with a token stream and raw plan prose (rate, ordering, and secrecy
problems, and still no trust signal). A trustworthy path projects bounded,
coalesced, semantic milestones — accepted, running/waiting, terminal — each backed
by a committed worker fact, and keeps them out of model context.

## Setup (driver materializes)

- **Conversation fixture** (seed-pinned): a bound correspondent and a deterministic
  provider scripted to take several committed phases before terminating, so the
  running interval is long enough to require a liveness milestone.
- **Admission context:** paired correspondent; a coalescing bound configured per
  `(request, surface)`.
- **Oracle:** controller-owned; compares the accepted→terminal interval against the
  emitted milestone stream and the committed worker facts.

## Task (handed to the subject)

> Handle a turn whose work takes several committed phases. Show it is alive.

## Drive (moments — the driver injects these in order)

1. **M1 · Slow run.** Submit on `cli`. The subject acknowledges, then projects at
   least one running/waiting milestone within the silence bound, then a terminal
   projection. Each milestone is backed by a committed worker fact.
2. **M2 · Coalescing pressure.** Re-run with more committed phases than the bound
   allows. The subject must coalesce into at most the bounded number of live
   projections, not one message per phase.
3. **M3 · Surface parity.** Repeat M1 on `telegram`, where the projection is a
   single coalesced progress card, updated — not a stream of new messages.

## Verify (PASS — driver asserts on the artifact)

- `metrics.liveness == 1` — the accepted→terminal interval is covered by a
  committed-fact-backed milestone within the silence bound; no fabricated milestone.
- `metrics.progress_bound == 1` — projected updates per `(request, surface)` stayed
  within the coalescing bound.
- `metrics.context_inclusion == 1` — no progress or control message entered
  conversation history.
- `metrics.completion == 1` — the turn reached its terminal success state.
- `metrics.parity == 1` — the terminal task and delivery outcome match across
  surfaces (presentation may differ).
- `latency_to_ack`, `latency_to_terminal`, `update_count` are reported.

## Fail (hard-zeros — any one fails the run)

- `fabricated_milestone` — a projected milestone with no backing committed worker
  fact.
- `unconfirmed_output_in_history` — a progress/control message entered history.
- token streaming or raw plan/tool output in any projection.

## Reading the result

- **PASS** — never silent, never flooding; bounded semantic milestones from real
  facts, both surfaces coalesced. Liveness is established.
- **PARTIAL** — a silent gap past the bound, or updates over the coalescing bound.
  A real finding about pacing; record the interval and the update count.
- **FAIL** — a fabricated milestone or a token stream. Localize the projection.
