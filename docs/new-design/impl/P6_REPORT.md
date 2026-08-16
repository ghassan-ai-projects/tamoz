# P6 — Phase report: RECONSIDER in the graph

Status: **implementation complete; review pass complete** (5 reviewer agents —
correctness, architecture, duplication/dead-code, sound/clean, repeated
mistakes — all findings fixed below).

## Review-pass fixes

- **Zero-intent decisions eliminated**: when nothing compensates (all
  let-stand, or every compensation above the ceiling), the decision carries
  the R0 watch condition from the catalog — a decision with zero intents would
  be rejected by Agentic Stream (the Go validator requires ≥1 intent).
- **Unique compensation identity**: the compensating intent's id includes the
  compensates command id — two corrected commands of the same type no longer
  collide (the Go validator rejects duplicate intent_ids).
- **One `now` per run**: the compensate node threads a single wall-clock
  through the intent + decision construction (no independent Time.now calls).
- **One payload contract**: the RECONSIDER payload normalization moved to
  tamoz-core (`normalize_reconsideration`) — the stream module and the agent
  intake node consume ONE contract (symbol- or string-keyed input, typed
  refusal); the dead `from_hash` duplication is gone; the node no longer
  hand-rolls the parse.
- **Kind normalization**: the intake downcases the kind before routing.
- **Gate tests strengthened**: a `refutes` (intent-digest → command) test; the
  gate-5 journal check queries the SQLite effects table (zero model-call
  effects); gate-6 uses a climate-UNIQUE action (open_roof_louvers) so the
  "resolves from its own catalog" claim is discriminating; the watch-fallback
  assertions for let-stand/ceiling-refusal; the test-only MAX_INTENTS
  constant deleted.

## Claims made (finished line)

No new claim. P6 removes the last domain Ruby from the stream path and
completes B2/B9: reconsideration is a graph route (intake → judge →
compensate), deterministic, with the compensation mapping from the INTENT
CATALOG — never regex or hard-coded tables.

## Exit gate status

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | Pending-withdraw / dispatched-downgrade / ceiling-refusal / own-risk / unknown-mapping through the graph | **PASS** | `stream_episode_reconsider_test.rb` — the five scenarios through the compiled graph (route_kind → judge → compensate) |
| 2 | Round-2 C.2 / round-3 M6 scenarios re-run green through the new path | **PASS** | the freezer-trace downgrade, pending-withdraw, transfer-R3 scenarios re-pinned as graph tests (the module-level tests are superseded) |
| 3 | Unknown compensation mapping → fail closed, no substitution | **PASS** | `test_an_unknown_compensation_mapping_fails_closed` (reduce_load has no mapping → typed FAILED) |
| 4 | Reconsider replay byte-identical | **PASS** | `test_a_reconsider_replay_is_byte_identical` (modulo the per-fence identity + wall-clock, which the DIAGNOSE path shares) |
| 5 | No model receipt in any reconsider episode (journal-verified) | **PASS** | `test_no_model_receipt_exists_in_any_reconsider_episode` + the intake skips role resolution entirely |
| 6 | Novel domain's reconsider resolves from its own catalog, zero Ruby | **PASS** | `test_a_novel_domains_reconsider_resolves_from_its_own_catalog` (climate → downgrade_climate_action R1) |

## What shipped

- **`route_kind` branch**: the graph branches on the intake's route — DIAGNOSE
  → recall → build_frame...; RECONSIDER → judge → compensate → END (same
  inbox, durability, event language). GRAPH_VERSION 4.
- **intake**: parses the wire's Reconsideration (prior decision required,
  typed refusal) and skips the model-role resolution for RECONSIDER.
- **`judge` node**: pure logic — the correction references (invalidates/
  refutes/explains) decide withdraw (pending), downgrade (effected), or
  let_stand. No catalog, no risk tables.
- **`compensate` node**: reads the compensation mapping from the INTENT
  CATALOG's per-entry metadata; the compensating risk is the TARGET's declared
  risk; above the ceiling the command stands; unknown mapping fails closed.
  Builds the decision via the builder's `build_decision` entry (same
  decision-v1 shape + digest).
- **Deletes**: COMPENSATION_RISK, WITHDRAW_TYPES, DOWNGRADE_TYPES, family_for,
  the second RISK_ORDER, and the standalone Reconsideration module's judgment
  machinery (parse/from_hash stay as payload helpers). The DecisionBuilder's
  RECONSIDER branch is gone.
- **Catalog metadata**: `compensation_for(type, action)` + load-time
  validation (a target that isn't a catalog member is refused); the
  aquaculture + climate catalogs gain the mapping + the note/priority target
  schemas + the transfer pair (R3).

## Fixture vs real labeling

All P6 gate tests are fixture-labeled; a RECONSIDER episode never calls a
model (gate 5's journal check is the proof).

## Honest scope notes

- Withdraw/downgrade EXECUTION (the effectors' actions) is out of scope (the
  graph produces the compensating intent proposal).
- The replay gate's "byte-identical" excludes the per-fence identity fields
  (decision_id/intent_id/intent_digest/fence) and the wall-clock expires_at —
  the same contract the DIAGNOSE path's replay uses.
