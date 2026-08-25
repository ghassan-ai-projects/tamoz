# Reasoning document slice

## Scope

Only `gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb` and this
evidence note are writable in this slice. Callers, tests, other production
files, other gems, and the existing refactoring artifacts were inspected
read-only.

No tests, lint, Enola, provider, or live commands are run in this lane.

## Candidate decisions

| Surface | Candidate defect | Decision | Risk |
| --- | --- | --- | --- |
| `parse` / `strict_parse` | Public protocol entry and duplicate-key/malformed-JSON boundary; the sequence is the rejection contract. | Leave stable. | Very high: public API and exact error timing/messages. |
| Protocol constants and value types | Public protocol, limits, wire keys, and returned object shapes. | Leave stable. | Very high: wire and API contract. |
| `parse_terminal_turn` | Coordinates hypothesis, probability distribution, derived selection, and optional terminal fields in protocol order. | Leave stable. | High: field and validation order. |
| `parse_probabilities` | The collection-level workflow is readable, but its map block mixes one-entry validation with coverage and sum validation. | Refactor. Extract one per-entry probability parser; retain collection order, `seen` semantics, missing-code reporting, and sum validation here. | Medium: exact first-error order and catalog-order reporting. |
| `parse_evidence_refs` | Optional-array handling and per-reference format validation are already short and cohesive; no meaningful reading-order defect requires another seam. | Leave stable. | Low: optional nil-to-empty behavior and rejection order. |
| `parse_recommended_intents` | The collection-level workflow is readable, but its map block mixes one-entry validation with array presence/size handling. | Refactor. Extract one per-entry intent parser; retain optional empty default, input order, and truthiness checks here or in the entry parser unchanged. | Medium: nil-vs-empty and preset/parameter rejection semantics. |
| `select_argmax` | Named deterministic selection policy with catalog-order tie breaking. | Leave stable. | High: selected code and confidence behavior. |
| `parse_tool_request` / tool-turn parsing | Tool validation is a separate protocol branch with intentional terminal-field rejection and argument defaults. | Leave stable. | High: route boundary and tool wire shape. |
| Fetch/rejection/catalog helpers | Shared validation seams already name their contracts and control exact errors. | Leave stable. | High: error messages and validation timing. |

## Selected refactor

`parse_probabilities` will read as: fetch the bounded probability entries, parse
each entry, require complete catalog coverage, then validate the distribution
sum. `parse_probability_entry` owns only one entry's existing object, key, code,
duplicate, and numeric-value checks, including the existing `seen` map update.

`parse_recommended_intents` will read as: preserve the optional empty default,
fetch the bounded intent entries, then parse them in input order.
`parse_recommended_intent` owns one entry's existing object, key, type, preset,
parameter, and value-object checks. It preserves Ruby truthiness exactly: a
present non-empty or empty Hash is truthy, `nil` is falsey, and the existing
`preset && parameters` and `parameters && !parameters.is_a?(Hash)` conditions
remain unchanged.

Evidence-reference parsing is intentionally not extracted. Its current block
is bounded, already reads as one format-validation operation, and extracting it
would add a seam without improving the parser's story.

## Exact preservation contract

- Keep `ReasoningDocument.parse`, all public constants, value types, method
  signatures, visibility, and `Document` fields unchanged.
- Keep strict JSON parsing, duplicate-key rejection, protocol checks, terminal
  versus tool branching, and every stable `reasoning_document/<code>` error
  class/message unchanged.
- In probability parsing, preserve input order, per-entry validation order,
  `codes.include?` unknown-code rejection, `seen[code]` truthiness and update,
  catalog-order `codes - seen.keys` missing-code text, `Probability` construction,
  numeric conversion and finite/range checks, and the final sum/tolerance check.
- In intent parsing, preserve absent-key `[]`, bounded-array validation, input
  order, unknown-key order, required and optional bounded-string checks, the
  exact truthiness behavior of preset and parameters, Hash-only parameter
  rejection, and `RecommendedIntent` field order and values.
- Keep evidence refs absent as `[]` and present as an input-ordered array;
  preserve their existing string, byte-size, prefix, and error checks.
- Keep nil-versus-empty branch fields, selected-code/raw-confidence derivation,
  downstream `document_projection` shapes, and caller behavior unchanged.
- Do not add compatibility handling, speculative validation, comments that
  restate code, tests, tracker/bar edits, or behavior changes.

## Inspection evidence

- `sed -n '1,320p' gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb`
- `rg -n -C 4 'ReasoningDocument|parse_probabilities|parse_recommended_intents|parse_evidence_refs' gems apps bin test`
- `sed -n '1,240p' test/agent_reasoning_document_test.rb`
- `rg -n -A100 -B12 'def document_projection|def ground_evidence|def validate_recommended_intent' gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb`
- `sed -n '1,260p' docs/refactoring/tamoz-agent-kernel-clean-code/SLICE-BAR.md`
- Existing slice notes and `BAR.md` were read for the scope and evidence boundary.

## Unimplemented behavior-change proposals

None. The requested reading-order refactor does not require a behavior change.
