# `episode_nodes.rb` candidate pass

The candidate pass was read-only. No production or test files were changed.

## Ranked candidates

1. `validate` (lines 428–457): turn raw model output into a validated document,
   then select `execute_tool`/`decide` or the one-shot repair path. Candidate
   helpers: `validated_document`, optionally `next_node_for_document`. Preserve
   parsing, grounding, catalog validation, error type, first-error order, and the
   exact repair directive at the node boundary.
2. `compensate` (lines 235–273): map ordered non-standing judgements through the
   catalog and risk ceiling, apply the watch fallback, and build the decision.
   Candidate helper: `compensating_intents`. Preserve filtering before
   `MAX_INTENTS`, mapping failure timing, risk checks, one captured timestamp,
   fallback intent, and summary text.
3. `recall` (lines 54–125): authorize the caller, derive stable recall identity,
   perform the journaled read, validate projections/digests, and return graph
   state. This is higher risk because it crosses the durable-effect boundary;
   preserve `EffectDispatcher.run`, JCS digest inputs, tenant checks, limit `64`,
   projection order, and failure mapping.
4. `reason` (lines 378–422): preflight budget, invoke the existing journaled
   model port, reject unknown/failed outcomes, reconcile usage, and project state.
   Preserve `EpisodeModelCall`, slot `0`, receipt-count ordinal, context
   forwarding, pre-dispatch budget check, and receipt projection.
5. `intake` (lines 158–184): admit model or reconsideration routes into codec-safe
   graph state. Reconsideration must skip role resolution and model-policy checks.
6. `judge` (lines 204–225): convert correction references and command status into
   ordered judgements. Preserve command and byte truncation, status classification,
   reasons, and iteration order.

## Leave stable

- `execute_tool`: its validate → budget → journaled call → outcome rejection → append
  order is already the safety boundary.
- `build_frame` and `rebuild_frame`: similar mechanics intentionally have different
  verification gates; avoid DRY extraction that hides the distinction.
- `memory_entries`, `parse_reconsideration`, `watch_intent`, and
  `build_compensating_intent`: each is cohesive; splitting risks digest or identity
  changes.
- `repair`, `decide`, `budget_controller`, `endpoint_for`, `frame_from`,
  `ground_evidence!`, `validate_tool_request!`, `validate_recommended_intent_types!`,
  `document_projection`, and `receipt_projection`: each already expresses one concern.

## Preservation risks

Keep model/tool/recall work inside their existing journal seams; preserve logical-key
inputs, budget checks, receipt/projection append semantics, digest domains, intent
identity fields, timestamps, fallback watch behavior, route names, error classes, and
exact error messages.
