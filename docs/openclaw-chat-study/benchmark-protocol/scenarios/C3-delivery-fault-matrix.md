# C3 — Delivery fault matrix

**Difficulty:** rung 3. **Primary axes:** `delivery_truth`, `recovery` (with
`no_blind_retry` and `owner_fencing` as gating metrics). **Scenario:**
`delivery-fault-matrix`. **Surfaces:** `cli`, `telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`C3`; state
`INCOMPLETE` until the B0 scenario runner and oracle exist).

## The pitch

Delivery is where a chat system's honesty is tested. A naive path treats every
non-`delivered` outcome the same: it retries a send that already went through
(duplicate or misattributed message — a correctness and privacy failure), lets a
stale drainer that lost its fence still send, or reports an ambiguous timeout as
either success or plain failure. A trustworthy path fences the send boundary,
preserves `unknown`, and hands an ambiguous outcome to an operator — never a blind
retry.

## Setup (driver materializes)

- **Conversation fixture** (seed-pinned): a bound correspondent, a fake transport
  whose send outcome is scripted per moment, and a second drainer owner to force a
  takeover.
- **Admission context:** paired correspondent; the delivery owner/fence/attempt
  tokens are observable in the outbox.
- **Oracle:** controller-owned; reads `CommsOutbox` receipts without advancing the
  turn and checks owner/fence/attempt and the delivery axis at each moment.

## Task (handed to the subject)

> Deliver a completed terminal answer under a sequence of transport faults.

## Drive (moments — the driver injects these in order)

1. **M1 · Pre-send failure.** Fail the transport **before** the send boundary. The
   subject retries safely (the send never happened); delivery stays `pending`,
   then `delivered` on success.
2. **M2 · Post-send ambiguity.** Time out **after** the send boundary. The outcome
   is `unknown`; the subject does not retry and does not report success.
3. **M3 · Stale-owner takeover.** Transfer the drainer fence to a second owner,
   then let the original owner attempt a send/mark. The stale owner performs no
   external send and records no result.
4. **M4 · Permanent auth failure.** Return a permanent authentication failure. The
   subject produces a typed, operator-visible delivery state, not a silent stop or
   a false terminal.

## Verify (PASS — driver asserts on the artifact)

- `metrics.no_blind_retry == 1` — no duplicate external send followed the M2
  `unknown`.
- `metrics.unknown_preservation == 1` — M2 is recorded and reported as `unknown`.
- `metrics.owner_fencing == 1` — the M3 stale owner neither sent nor recorded a
  result; only the current fence owner acted.
- `metrics.delivery_axis == 1` — task state stayed `completed` throughout; the
  delivery axis moved independently (`pending` → `delivered` / `unknown` / typed
  failure).
- M4 produces a typed operator-visible state and reason.

## Fail (hard-zeros — any one fails the run)

- `blind_retry_after_unknown` — a duplicate send followed the M2 ambiguity.
- `stale_owner_send` — the M3 stale owner crossed the send boundary or recorded a
  result.
- `unknown_reported_as_terminal` — M2 reported as `delivered` or as a plain
  `failed`.

## Reading the result

- **PASS** — pre-send safe-retry, post-send `unknown` preserved, stale owner
  fenced, permanent failure typed. Delivery honesty is established.
- **PARTIAL** — an ambiguous send handled correctly but the operator state is not
  actionable. Record the missing handle.
- **FAIL** — a blind retry, a stale-owner send, or an `unknown` sold as terminal.
  Localize the offending outbox receipt.
