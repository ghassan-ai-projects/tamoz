# `episode_nodes.rb` slice

## Scope

Only `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb` and this
evidence note are writable in this slice. Callers, tests, other production
files, other gems, package metadata, and the refactoring tracker are
read-only. No tests, lint, Enola, provider, or live commands are run here.

## Candidate decisions

| Surface | Candidate defect | Decision | Risk |
| --- | --- | --- | --- |
| `validate` | The node mixes strict document validation, document projection, route selection, and the one-shot repair boundary. | Refactor. Extract `validated_document` and `next_node_for_document`; keep projection through the existing `document_projection` seam and keep the `ProtocolError` rescue at the node boundary. | High: validation order, route shape, repair directive, error class/message, and rescue timing. |
| `compensate` | The node mixes ordered catalog compensation mapping, risk filtering, fallback selection, decision construction, and summary policy. | Refactor. Extract `compensating_intents` and `compensation_summary`; keep catalog verification, timestamp capture, fallback, and decision-builder call in the node. | High: mapping failure timing, `MAX_INTENTS`, risk ceiling, intent order/identity, timestamp, summary text, and digest. |
| `recall` | Authorizes and journals a non-deterministic memory read across a durable-effect boundary. | Leave stable. | Very high: logical key, JCS identity, tenant checks, projections, digests, limit, and failure mapping. |
| `reason` | Performs the only model call through the existing journal seam and reconciles budget/receipt state. | Leave stable. | Very high: pre-dispatch budget, `EpisodeModelCall`, slot/ordinal, context, receipt projection, and logical identity. |
| `intake` | Selects the model/reconsideration route; reconsideration intentionally skips role resolution. | Leave stable. | High: route state and model-policy bypass contract. |
| `judge` | Produces ordered reconsideration judgements with bounded commands, truncation, and status-specific decisions. | Leave stable. | High: first-error/order semantics, command limits, byte truncation, and reason text. |
| `memory_entries`, `parse_reconsideration`, `watch_intent`, `build_compensating_intent`, and existing validation/projection helpers | Each already expresses one cohesive lower-level concept or protects a digest/identity boundary. | Leave stable. | High: changing any shape, digest, identity, or error seam would exceed the safe slice. |
| `execute_tool`, `build_frame`, `rebuild_frame`, `repair`, `decide`, and budget/receipt/tool helpers | Their existing stories and journal/budget boundaries are explicit or intentionally distinct. | Leave stable. | High: external effects, frame bytes, repair state, decision shape, and receipt semantics. |

## Selected refactor

`validate` now reads as: obtain the validated reasoning document, choose the
next graph node, and project it. `validated_document` owns the existing
frame/raw-response checks, diagnosis parsing, grounding, intent-catalog
verification, and recommended-intent validation in the same order.
`next_node_for_document` owns only the existing tool-request route decision.
The `ProtocolError` rescue remains on `validate`, including the exact repair
directive and terminal error behavior.

`compensate` now reads as: load and verify the catalog, capture the episode
inputs and one timestamp, collect the non-standing judgements, map ordered
compensations, select the existing fallback when needed, and build the
decision. `compensating_intents` preserves filtering before `MAX_INTENTS`,
catalog mapping failure timing, target-risk filtering, judgement order, and
the captured timestamp. `compensation_summary` preserves the existing array
comparison and exact summary strings, including the use of the full filtered
judgement count.

## Preservation contract

- Preserve all existing public methods, constants, signatures, visibility,
  graph state keys, projected hashes, and output ordering.
- Preserve `validate`'s first-error order: missing response, diagnosis
  parsing, evidence grounding, intent-catalog verification, and recommended
  intent validation. Preserve `document_projection` output and route strings.
- Preserve `validate`'s boundary rescue: one repair when
  `repair_count < 1`, the exact original `error.message` in
  `repair_directive`, and `ProtocolError, "episode document is malformed after
  repair"` thereafter.
- Preserve `compensate`'s catalog verification before later compensation
  work, captured `Time.now.utc`, filtering of `let_stand`, filtering before
  `MAX_INTENTS`, mapping errors and their exact messages, target risk checks,
  compensation order, fallback watch intent, and all intent identity/digest
  inputs.
- Preserve the exact decision-builder arguments, snapshot digest, summary
  text, and captured timestamp in `compensate`.
- Preserve all journal seams, logical keys, budgets, receipts, timestamps,
  digests, truncation, and errors outside the selected helper extraction.

## Concepts and behavior-change proposal

Implemented concepts are `validated_document`, `next_node_for_document`,
`compensating_intents`, and `compensation_summary`. No behavior-change
proposal is needed; no behavior change is applied. The remaining mixed
abstraction areas are intentionally deferred to protect the durable effect,
model, frame, and decision boundaries.

## Evidence boundary

The implementation is inspection-based in this slice. Relevant read-only
surfaces included the candidate map and slice bar, `EpisodeNodes` callers and
graph composition, `test/stream_episode_loop_test.rb`,
`test/stream_episode_reconsider_test.rb`, `test/stream_invariants_test.rb`,
the existing refactoring slice notes, and the aggregate bar. Tests, lint,
Enola, providers, live commands, and commits remain deferred by the task
instructions.
