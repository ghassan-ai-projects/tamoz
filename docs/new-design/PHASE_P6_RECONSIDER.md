# P6 — RECONSIDER in the graph

Bar rules exercised: B2, B7, B9.

## Goal

Reconsideration becomes graph nodes on the same compiled episode graph. It stays deterministic —
no model call, ever. Compensation types come from the intent catalog, not from regex.

## In scope

- **`reconsider` route.** `route_kind` sends reconsider operations to
  `intake → judge → compensate → END`.
- **`judge` node.** Deterministic. Correction references decide withdraw / downgrade / stand.
  Ported from `Reconsideration.judge` (`reconsideration.rb:136-164`) without its lookup tables.
- **`compensate` node.** Reads the compensation mapping from the intent catalog (P4). The
  compensating intent carries its own declared risk, schema, and policy. Compensations no longer
  bypass the catalog.
- **Same spine.** Reconsider runs through the same inbox, same durability, same event language.
  No parallel path.

## Deletes

- `COMPENSATION_RISK` (`reconsideration.rb:49-55`).
- `WITHDRAW_TYPES`, `DOWNGRADE_TYPES` (`reconsideration.rb:59-72`).
- `family_for` regex classifier (`reconsideration.rb:245-272`).
- Second `RISK_ORDER` copy (`reconsideration.rb:279-281`).
- The standalone `Reconsideration` module once the nodes land.

## Exit gate

1. Pending withdraw, dispatched downgrade, ceiling refusal, own-risk enforcement, and
   unknown-mapping cases all pass through the graph nodes.
2. Round-2 C.2 and round-3 M6 scenarios re-run green through the new path.
3. Unknown compensation mapping → fail closed, no substitution.
4. Reconsider replay from checkpoints is byte-identical.
5. No model receipt exists in any reconsider episode. Verified by the journal.
6. A novel domain's reconsider path resolves compensation from its own catalog with zero Ruby.

## Allowed claim

No new claim. This phase removes the last domain Ruby from the stream path and completes B2/B9.
