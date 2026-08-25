# IntentCatalog slice assessment

## Scope

- Production change: `gems/tamoz-agent-kernel/lib/tamoz/agent/intent_catalog.rb`
- Evidence note: this file
- No tests, lint, Enola, providers, live commands, or commits are part of this lane.

## Inspection commands

- `sed -n '1,260p' gems/tamoz-agent-kernel/lib/tamoz/agent/intent_catalog.rb`
- `sed -n '1,360p' test/agent_intent_catalog_test.rb`
- `rg -n 'IntentCatalog|intent_catalog' gems/tamoz-agent-kernel/lib/tamoz/agent gems/tamoz-stream/lib/tamoz/stream test/support test --glob '*.rb'`
- `sed` reads of `diagnosis_catalog.rb`, `episode_nodes.rb`, `episode_frame_builder.rb`, `decision_builder.rb`, `domain_loader.rb`, and `episode_composition.rb`
- `git show 1d728e6141698dab0b9ee8519e777e2513cbc058:gems/tamoz-agent-kernel/lib/tamoz/agent/intent_catalog.rb`

## Candidate and stable decisions

### Candidate

`build_entry` currently moves through entry identity, schema digest preparation and
validation, model-writable and preset validation, metadata validation, and frozen
`Entry` construction in one method. The reading-order defect is the repeated shift
between catalog concepts and field-freezing/construction mechanics.

The bounded split is:

1. `validated_entry_identity` validates the raw entry and returns the coerced type and risk.
2. `validated_parameter_schema` preserves schema JCS preparation, schema validation, and the
   optional schema-digest check, returning the schema and original digest value for
   the existing normalization at `Entry` construction.
3. `validated_entry_parameters` preserves model-writable validation before preset validation
   and returns the original presets and writable-field values.
4. `validated_entry_metadata` preserves description validation before rate-limit validation
   and returns the original metadata values.
5. `build_entry` remains the ordered entry workflow and performs the existing field
   freezing/defaulting at the `Entry` boundary.

The existing `validate_presets!` remains the single per-entry preset validator. A
per-preset extraction would add another private call without improving the catalog
workflow or changing the abstraction boundary.

### Stable behavior decisions

- Preserve `IntentCatalogError` class, exact messages, and first-error order.
- Preserve symbol-key precedence and every existing `String` coercion.
- Preserve schema JCS computation timing, including computation before the missing
  schema/type errors where the current code does so.
- Preserve model-writable-before-preset validation and description-before-rate-limit
  validation.
- Preserve `Entry` fields, shallow/deep freezing, defaults, and normalized digest
  values exactly.
- Preserve canonical entry ordering, compensation target validation and lookup, wire
  JSON shape, and all digest bytes.
- Preserve the public API; new helpers remain private class methods.

## Unimplemented behavior proposals

None. This slice applies no behavior change and proposes no new behavior.
