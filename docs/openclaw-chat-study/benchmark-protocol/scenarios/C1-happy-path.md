# C1 — Canonical happy path

**Difficulty:** rung 1 (easiest). **Primary axes:** `identity`, `delivery_truth`
(with `admission_before_ack` as the gating metric). **Scenario:** `happy-path`.
**Surfaces:** `cli`, `telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`C1`; state
`INCOMPLETE` until the B0 scenario runner and oracle exist).

## The pitch

The simplest thing a trustworthy chat does — and the one a naive path gets subtly
wrong. Given a normal short turn, a weak implementation acknowledges before the
turn is durably admitted (so a crash loses a "received" message), returns no
stable reference (so the turn cannot be queried), or collapses task and delivery
into one status (so `completed + delivery=unknown` reads as success or failure).
A trustworthy path admits durably first, hands back a stable reference, and keeps
the two axes distinct through to the terminal.

## Setup (driver materializes)

- **Conversation fixture** (seed-pinned): one bound correspondent, a fresh thread,
  real SQLite stores, a deterministic provider, and a fake transport with recorded
  requests.
- **Admission context:** the correspondent is already paired/bound; no capability
  beyond a plain answer is required.
- **Oracle:** controller-owned; scores the durable request/session/outbox records
  and the emitted milestone stream — admission order, the reference, and the two
  terminal axes.

## Task (handed to the subject)

> Answer a short question that needs no tool. Acknowledge, run, and deliver.

## Drive (moments — the driver injects these in order)

1. **M1 · Submit.** Submit the turn on `cli`. The subject admits durably, returns
   an acknowledgement with a stable reference, runs, and delivers a terminal
   answer linked to the same reference.
2. **M2 · Query.** After the terminal, call `/status <reference>`. It returns the
   completed task state and the `delivered` delivery state as separate axes.
3. **M3 · Surface parity.** Repeat M1 on `telegram`. The reference, terminal task
   state, and delivery outcome match the `cli` run.

## Verify (PASS — driver asserts on the artifact)

- `metrics.admission_before_ack == 1` — the durable admission commit precedes the
  acknowledgement being eligible to send.
- `metrics.reference_stability == 1` — the acknowledgement reference resolves the
  same turn in `/status` and in the terminal projection.
- `metrics.completion == 1` — the turn reached the terminal success task state.
- `metrics.delivery_axis == 1` — task state and delivery state are reported
  independently; the terminal is `completed` + `delivered`.
- `metrics.context_inclusion == 1` — only the confirmed terminal delivery entered
  conversation history.
- `metrics.parity == 1` between `cli` and `telegram`.

## Fail (hard-zeros — any one fails the run)

- `ack_before_admission` — the acknowledgement was eligible to send before the
  durable admission committed.
- `unconfirmed_output_in_history` — pending/unknown output entered history.
- `identity_conflict_deduplicated` — a same-ID/different-content pair was silently
  merged (should not arise here, but is asserted absent).

## Reading the result

- **PASS** — durable-first acknowledgement, stable reference, two clean axes, both
  surfaces agree. The contract floor is established.
- **PARTIAL** — correct answer but the reference does not resolve in `/status`, or
  the two axes are conflated. A real finding; record it.
- **FAIL** — acknowledgement preceded admission, or unconfirmed output entered
  history. Localize the offending record.
