# P6 — Implementation plan: RECONSIDER in the graph

Status: **draft v2** — gap + completeness findings integrated (gate-2 re-pinned
to the real scenarios in `stream_reconsideration_test`; the DecisionBuilder
gains a `build_decision(intents:)` entry so the compensate node reuses the
decision-v1 shape + digest; the compensation-target schemas declare
`note`/`priority` (the Go validator's `additionalProperties: false` would
reject the old params); the aquaculture catalog gains the compensation
metadata + the transfer pair (R3) as catalog members; the envelope gate
extends the intent-catalog requirement to RECONSIDER; the compensate node
verify_wire's the catalog; the test-update list is enumerated).

Bar: PHASE_P6_RECONSIDER.md exit gates 1–6. Bars: B2, B7, B9. Claim: no new
claim — removes the last domain Ruby from the stream path.

## Architecture (delta from P5)

Reconsideration becomes graph nodes on the same compiled episode graph:
`route_kind` sends RECONSIDER to `intake → judge → compensate → END`. It
stays deterministic — no model call, ever. Compensation types and risks come
from the INTENT CATALOG (P4), not from regex or hard-coded tables.

- **`route_kind` branch** (episode_graph): after intake, branch on the
  episode kind — DIAGNOSE → recall → build_frame → ...; RECONSIDER →
  judge → compensate → END. The same inbox, durability, and event language.
- **intake**: relax the P1 RECONSIDER gate ("not supported (P6)") — parse the
  wire's reconsideration payload into `state[:reconsideration]` (typed refusal
  on a missing/malformed payload; the wire's prior_decision_json is required).
- **`judge` node**: deterministic — port `Reconsideration.judge` verbatim
  WITHOUT its lookup tables: the correction references (invalidates/refutes/
  explains → command ids / intent digests) decide withdraw (pending),
  downgrade (dispatched/effected), or let_stand. Pure logic: no catalog.
- **`compensate` node**: reads the compensation mapping from the intent
  catalog — each actionable entry's `compensation` metadata
  `{withdraw: <type>, downgrade: <type>}` names the compensating TYPES (which
  are themselves catalog members with their own declared risks, P4 G5). The
  compensating intent's risk = the TARGET's declared risk (own-risk, never
  inherited); a target above the episode ceiling → the command stands (no
  compensation — typed, deterministic). An UNKNOWN mapping (an entry with no
  `compensation` metadata for the required action) → fail closed, never
  substitute.
- **compensate writes the decision**: the RECONSIDER decision is built
  (decision-v1 shape — prior_decision-derived summary + the compensating
  intents) and digested; the terminal state carries it (the runner translates
  it like the DIAGNOSE decision).
- **Deletes** (once the nodes land): `COMPENSATION_RISK`, `WITHDRAW_TYPES`,
  `DOWNGRADE_TYPES`, `family_for`, the second `RISK_ORDER`, and the standalone
  `Reconsideration` module's domain tables. `Reconsideration.parse/from_hash`
  may stay as pure payload helpers (no tables) or fold into the nodes.
- **decision_builder**: the RECONSIDER path (reconsideration_intents +
  valid_compensation?) is superseded — the compensate node produces the
  compensating intents directly (the builder's RECONSIDER branch is removed;
  the catalog membership + equal-risk checks move into the compensate node).

## Exit gates mapped to tests

1. **Pending-withdraw / dispatched-downgrade / ceiling-refusal / own-risk /
   unknown-mapping through the graph** — one parameterized gate test driving
   each scenario through the compiled graph (fixture correction + prior
   decision + commands).
2. **Round-2 C.2 / round-3 M6 scenarios** — the existing
   `stream_learning_loop_test` reconsideration scenarios re-run green through
   the new path (the runner's kind gate is gone; the wire's RECONSIDER flows).
3. **Unknown mapping → fail closed, no substitution** — an entry without the
   required compensation metadata → typed FAILED.
4. **Reconsider replay byte-identical** — fence+1 with the provider network
   disabled → identical decision (no model call → the journal has no receipts;
   gate 5's journal check proves it).
5. **No model receipt in any reconsider episode** — the terminal state's
   `model_receipts` is empty + the journal has no `reason`-stage effects.
6. **Novel domain's reconsider** — the climate catalog gains compensation
   metadata; a climate reconsider episode resolves its compensation from ITS
   catalog with zero Ruby.

## Tasks

### T1 — Graph route + intake relax
- `episode_graph.rb`: `branch :intake` (kind) — DIAGNOSE → recall; RECONSIDER
  → judge. Add the `judge` + `compensate` nodes + edges
  (judge → compensate → END). GRAPH_VERSION → 4.
- `situation_request.rb`: remove the P1 RECONSIDER refusal; the envelope
  parses + carries the reconsideration payload into the graph state
  (`state[:reconsideration]` — already declared).

### T2 — judge node (pure, no tables)
- `EpisodeNodes#judge`: port `Reconsideration.judge` (invalidated ids via
  invalidates/refutes/explains; pending → withdraw, effected → downgrade,
  else stand). No catalog, no risk tables. Writes `state[:judgements]`.

### T3 — compensate node (catalog-driven)
- `EpisodeNodes#compensate`: for each acting judgement, resolve the target
  type from the CATALOG entry's `compensation` metadata (withdraw/downgrade)
  for the ORIGINAL intent type; the target must be a catalog member; its risk
  = the catalog's declared risk for the target; above the ceiling → the
  command stands. Unknown mapping → typed failure. Builds the compensating
  intents (own digest, compensates, parameters) + the reconsider decision
  (decision-v1, digested).
- `IntentCatalog` Entry: the `compensation` metadata is already carried (P4);
  add a `compensation_for(action)` accessor + validation (the metadata's
  withdraw/downgrade types must be catalog members with declared risks).

### T4 — decision_builder prune
- Remove the RECONSIDER branch (`reconsideration_intents` +
  `catalog_member_with_declared_risk?`) from DecisionBuilder — the compensate
  node is the sole producer.
- Remove the deletes from `reconsideration.rb` (the module becomes pure
  payload helpers or is deleted).

### T5 — Catalog fixtures gain compensation metadata
- aquaculture + climate catalogs: each actionable entry gains
  `compensation: {withdraw: <type>, downgrade: <type>}` naming catalog-member
  targets (withdraw_ticket/downgrade_dispatch/etc.). The cross-repo digest
  pins change (recompute + re-pin both sides).

### T6 — Gate tests + replays
- `test/stream_episode_reconsider_test.rb`: gates 1–6 (parameterized
  scenarios, unknown mapping, replay with network disabled, journal-verified
  no-receipt, climate reconsider).
- Update `stream_learning_loop_test` + the wire composition for the RECONSIDER
  kind (the composition's wire_request gains the reconsideration payload).

## Test mode labeling

All P6 gate tests are fixture-labeled; RECONSIDER never calls a model (gate
5's journal check is the proof).

## Deferred

- Withdraw/downgrade EXECUTION (the effectors' actions) — channel-B, out of
  scope (the compensating intent proposal is what the graph produces).
