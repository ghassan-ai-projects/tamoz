# C9 — Two-conversation isolation

**Difficulty:** rung 9 (advanced tier). **Primary axes:** `context_integrity`,
`parity` (with `isolation` as the gating metric). **Scenario:**
`two-conversation-isolation`. **Surfaces:** `cli`, `telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`C9`; state
`INCOMPLETE` until the B0 scenario runner and oracle exist).

## The pitch

A shared worker process handles many conversations, and a naive path leaks between
them: one conversation's reference resolves another's status, a progress card lands
in the wrong chat, an approval prompt crosses correspondents, or a delivery is
attributed to the wrong thread. This rung runs two concurrent conversations and
asserts that references, progress, approvals, and delivery never cross — a
correctness and privacy contract, not a UX nicety.

## Setup (driver materializes)

- **Conversation fixture** (seed-pinned): two bound correspondents in two distinct
  threads, driven concurrently through a shared worker; real SQLite stores and a
  fake transport that records the destination of every send.
- **Admission context:** paired correspondents; routing keyed on the surface and
  conversation.
- **Oracle:** controller-owned; checks that every reference, milestone, approval,
  and delivery is attributed to its own conversation, and that `/status` is
  caller-bound.

## Task (handed to the subject)

> Handle two concurrent turns in two conversations, one slow and one with an
> approval, and keep them isolated.

## Drive (moments — the driver injects these in order)

1. **M1 · Concurrent submit.** Submit a slow turn in conversation A and an
   approval-bearing turn in conversation B at the same time. Each gets its own
   reference.
2. **M2 · Cross-query.** From A, call `/status <B's reference>`. A caller-bound
   status does not resolve B's turn for A's correspondent.
3. **M3 · Progress and approval routing.** A's progress milestones deliver only to
   A; B's approval prompt delivers only to B. The fake transport records no
   cross-destination send.
4. **M4 · Terminal delivery.** Each terminal answer delivers to its own
   correspondent; neither enters the other conversation's history.

## Verify (PASS — driver asserts on the artifact)

- `metrics.isolation == 1` — no reference, milestone, approval, or delivery crossed
  conversations; `/status` is caller-bound.
- `metrics.context_inclusion == 1` — each conversation's history contains only its
  own confirmed terminal delivery.
- `metrics.reference_stability == 1` — each reference resolves only its own turn.
- `metrics.parity == 1` — isolation holds identically across surfaces.

## Fail (hard-zeros — any one fails the run)

- a reference, milestone, approval, or delivery attributed to the wrong
  conversation.
- `/status` resolving another conversation's turn for a bare caller.
- a terminal answer entering the wrong conversation's history.

## Reading the result

- **PASS** — two conversations, fully isolated references/progress/approvals/
  delivery, on both surfaces. Isolation holds.
- **PARTIAL** — isolation holds for delivery but `/status` is not strictly
  caller-bound. Record the leak surface.
- **FAIL** — any cross-conversation attribution. Localize the crossing record and
  the send destination.
