# P4 — Implementation plan: intent authority

Status: **draft v2** — reviewed by gap-searcher + completeness-checker (11
findings integrated: G1–G7, C1–C4 below).

Bar: PHASE_P4_INTENT_AUTHORITY.md exit gate (5 items). Bars: B9, B10.
Claim: **"New domains are authoring-only"** (jointly with P5). Level 4 of 6.

## Review findings integrated

- **G1 (BLOCKER)** — the aquaculture prompt + fixture documents must emit
  `recommended_intents` (currently none → every episode would degrade to
  watch). Prompt gains the proposal instruction; `AquacultureDomain.document`
  gains an `intent:` parameter producing a `recommended_intents` entry.
- **G2 (MAJOR)** — decide seam: the runner payload carries
  `intent_catalog_json/sha256`; `build_frame`/`rebuild_frame` verify the
  catalog at the SAME seam as the diagnosis catalog and store the VERIFIED
  `IntentCatalog` in state; `DecisionNodeBuilder#call` gains `catalog:` and
  forwards the document's `recommended_intents` + `evidence_refs`.
- **G3 (MAJOR)** — the catalog-missing fail-closed gate is kind-scoped:
  DIAGNOSE requires the catalog; RECONSIDER (no model call, deterministic)
  does not.
- **G4/C1 (MAJOR)** — the Go side's SPEC authors the catalog:
  `internal/spec/spec.go` + `schema.json` gain `intents` entries (type,
  declared risk, parameter schema path, presets, model-writable fields,
  policy, rate limit, compensation targets); `compiler.go` compiles them; the
  assembler embeds the canonical catalog + shared-domain digest into the wire
  (mirroring the diagnosis-catalog block).
- **C2 (MAJOR)** — rate-limit enforcement gains a home: `internal/policy`
  `EvaluateIntent` enforces the catalog's per-intent rate limit before
  dispatch (the validator→dispatch path is
  executor.go persistValidatedIntents → pipeline.go).
- **G5 (MAJOR)** — compensation intents (RECONSIDER) are ALSO catalog members;
  the Go validator's risk-equality check applies to them too (bypassing the
  allowlist stays, but the catalog is authoritative).
- **G6 (MINOR)** — watch/action parameters are catalog PRESETS
  (byte-identical), so the existing decisions stay reproducible.
- **G7 (MINOR)** — test inventory: `stream_decision_builder_test.rb`
  (HIGH_CONFIDENCE/two-intent/widening tests), `stream_invariants_test.rb`,
  `stream_episode_crash_matrix_test.rb`, `stream_learning_loop_test.rb` are
  updated for the deletes.
- **C3 (MINOR)** — two+ actionable intents in one document → REFUSED (typed),
  never first-entry truncation.
- **C4 (MINOR)** — declared posture: the worker only PROPOSES (dispatch_policy
  SHADOW is the default); automatic action needs the P8 calibration artifact —
  missing calibration = shadow/watch-only, stated, not implemented here.
- **C5 (MINOR)** — the "zero Ruby" gate-4 claim is scoped to PRODUCTION code
  (`gems/`); the novel-domain fixture is test data.

## Architecture (delta from P3)

The domain's actions come from a SPEC-BOUND intent catalog, verified
independently by Agentic Stream. Every hard-coded domain table in Tamoz is
deleted. The model recommends; it never declares authority (hard rule 3).

- **The wire carries the intent catalog** (canonical, digest-bound), mirroring
  `diagnosis_catalog_json/sha256`: new `EpisodeRequest` fields
  `intent_catalog_json` / `intent_catalog_sha256` with the shared domain digest
  rule `digest("situation-runtime/intent-catalog/v1\n", <parsed array>)`.
  Additive proto change, coordinated across both repos; regen the vendored
  `runtime-v1_pb.rb` and the Go runtimev1 binding.
- **`IntentCatalog` (tamoz-agent)**: mirrors `DiagnosisCatalog` — `from_list`,
  `verify_wire(json, digest)` (fail closed: empty/malformed/forged/digest-
  mismatch/duplicate), `canonical_bytes`, `digest`. Per-intent fields:
  `type`, `risk_class` (R0–R4, EXACT), `parameter_schema` (JSON Schema),
  `parameter_schema_digest`, `presets` (named parameter maps, operator-
  authored), `model_writable_fields` (subset of schema properties the model
  may fill), `policy`, `rate_limit`, `compensation` (withdraw/downgrade
  targets — carried but consumed in P6).
- **`decide` node rebuild** (decision_builder + decision_node_builder): builds
  ONLY from the validated document + catalog. The model's proposal is the
  document's `recommended_intents` (already parsed by the strict v2 parser).
  At most ONE actionable intent in v1. Risk = the catalog's declared risk
  (never the model's). Parameters: operator preset (preferred) merged with
  direct model values ONLY for `model_writable_fields`. No proposal, or a
  proposal outside catalog ∩ allowlist, or confidence below the watch floor →
  watch condition (R0) from the catalog. Confidence never unlocks authority
  (the HIGH_CONFIDENCE machine is DELETED).
- **Deletes (Ruby)**: `ACTION_RISKS`, `RISK_ORDER`, empty-allowlist widening to
  all actions (fail closed instead), the confidence-threshold selection
  machine. `COMPENSATION_RISK`/`WITHDRAW_TYPES`/`DOWNGRADE_TYPES`/`family_for`
  move to P6 with the reconsideration logic (NOT deleted here).
- **Agentic Stream independent validation** (validator.go): the validator's
  `Input` gains the COMPILED catalog (digest-verified against the wire at the
  executor/assembler boundary). Per intent: `type` ∈ catalog; **proposed
  `risk_class` EQUALS the catalog-declared risk** (closes
  `validator.go:161` — currently only a ceiling check); `parameters` validate
  against the per-intent schema; preset/builder fields byte-identical to the
  compiled catalog; `evidence_ids` ⊆ the decision's `facts_used` refs. Policy,
  approval, and rate limits enforced before dispatch (the existing lifecycle
  pipeline). Rejection never silently clamps or substitutes.
- **Cross-repo conformance fixtures**: pinned catalog digest vectors (both
  sides compute the identical domain digest over the parsed array — extend the
  parity test pattern); exit-gate fixtures for old requests WITHOUT the catalog
  (fail closed before any model call), forged digest, malformed catalog,
  duplicate types, risk-label attack (model claims R0 for an R2 action).

## Tasks

### T1 — Proto + regen (both repos)
- `runtime-v1.proto`: `EpisodeRequest` gains `bytes intent_catalog_json = 63;`
  and `bytes intent_catalog_sha256 = 64;`.
- Regenerate the Ruby vendored binding (`runtime-v1_pb.rb`) and the Go
  `runtimev1` binding. Protocol version stays 1.0 (additive fields); the
  worker REFUSES a diagnose request with no intent catalog (fail closed).

### T2 — IntentCatalog (tamoz-agent, mirrors DiagnosisCatalog)
- `gems/tamoz-agent/lib/tamoz/agent/intent_catalog.rb`: structural rules —
  type `^[a-z][a-z0-9_.-]{0,127}$`, risk ∈ R0..R4, unique types, parameter
  schema must be a JSON Schema object (digest-bound by JCS of the schema),
  `model_writable_fields` ⊆ schema property names, presets valid against the
  schema (each preset's parameters must satisfy the schema), bounds (max
  entries, max parameter bytes). Canonical form binds ORDER.
- `verify_wire(intent_catalog_json, expected_digest)` — strict-parse, verify
  the shared domain digest, then `from_list`. Missing/empty/malformed/forged →
  typed `IntentCatalogError`, fail closed before any model call.
- Wire it into the runner payload + frame (like diagnosis catalog): the
  envelope payload carries `intent_catalog_json/sha256` (G2); the frame
  builder verifies it at the SAME seam as `DiagnosisCatalog.verify_wire` and
  stores the VERIFIED catalog in graph state; the decide node receives it.
  Kind-scoped: DIAGNOSE requires the catalog; RECONSIDER does not (G3).

### T2b — Aquaculture fixtures emit proposals (G1)
- The aquaculture prompt gains the recommendation instruction (at most one
  action, from the catalog; parameters only from the listed writable fields).
- `AquacultureDomain.document(selected:, hypothesis:, intent: ...)` gains a
  `recommended_intents` entry (type + parameters); the fixture domain gains
  its INTENT CATALOG (data): `install_watch_condition` (R0) and the action
  types with the SAME risk classes the deleted tables declared (so decisions
  stay reproducible), each with a parameter schema, presets matching the
  builder's current parameter shapes (G6), and `model_writable_fields`.

### T3 — decide rebuild (tamoz-stream)
- `DecisionNodeBuilder#call` gains `catalog:` (the verified IntentCatalog) and
  forwards the document's `recommended_intents` + `evidence_refs`.
- `DecisionBuilder`:
  - `intents`: at most ONE actionable intent from the document's
    `recommended_intents`; TWO+ actionable intents → REFUSED (typed, C3). The
    intent's `risk_class` is `catalog.risk_for(type)` — the model's claimed
    risk is IGNORED; parameters = the catalog PRESET (byte-identical, G6)
    overlaid with the model's values ONLY for `model_writable_fields`; a model
    value for a non-writable field → the proposal is refused → watch, never a
    silent drop.
  - No proposal / type ∉ catalog ∩ allowlist / proposal risk above the
    episode ceiling / confidence below `watch_confidence_floor` → watch
    condition intent (R0, from the catalog; `install_watch_condition` must be
    a catalog entry).
  - `allowed_intent_types` empty → FAIL CLOSED (no widening).
  - Watch/action selection is catalog-driven; `RISK_ORDER` is replaced by the
    catalog's declared risk.
- The decision's intents gain `evidence_ids` from the document's
  `evidence_refs` (schema already allows it — populate it so the Go side can
  bind the intent's grounds).

### T3b — RECONSIDER intents are catalog members (G5)
- The aquaculture catalog declares the compensation targets
  (`withdraw_ticket`/`downgrade_*` etc. with their risks); the Go risk-
  equality check applies to compensation intents too (they bypass the
  allowlist but NOT the catalog).

### T4 — Go validator (agentic-stream)
- `decisions.Input` gains `IntentCatalog *IntentCatalog` (a compiled struct
  with per-type entries: declared risk, parameter schema, presets, writable
  fields). The executor/assembler parses + digest-verifies the wire catalog
  (shared domain rule) and fails closed on missing/forged/malformed/empty.
- `validateIntent`: `risk_class` must EQUAL the catalog's declared risk for
  the type (not merely ≤ ceiling — closes the gap); `parameters` validated
  against the per-intent schema (embedded jsonschema, deny-network loader);
  preset-only fields must be byte-identical to the compiled preset; model-
  writable fields may differ. `evidence_ids` ⊆ `facts_used` refs.
- New rejection reasons: `catalog_missing`, `catalog_forged`, `risk_label_mismatch`,
  `parameter_schema_violation`, `preset_mismatch` — mapped into the lifecycle
  rejection registry (fail closed, never clamped).

### T4b — Go spec authors the catalog + rate-limit enforcement (C1/C2)
- `internal/spec/spec.go` + `schema.json`: the spec gains the intent catalog
  (type, declared risk, parameter schema path, presets, model-writable fields,
  policy, rate limit, compensation targets); `compiler.go` compiles it; the
  assembler embeds the canonical catalog + shared-domain digest into the wire
  (mirroring the diagnosis-catalog block).
- `internal/policy` `EvaluateIntent` enforces the catalog's per-intent rate
  limit before dispatch (executor.go `persistValidatedIntents` →
  pipeline.go); a rate-limited intent is rejected, not clamped.

### T5 — Cross-repo conformance fixtures
- Parity vectors: pin the aquaculture intent catalog's canonical bytes + the
  shared domain digest on BOTH sides (Ruby test + Go test) — byte-identical.
- Exit-gate fixtures (Go + Ruby):
  1. no intent catalog on the wire → refused before any model call;
  2. forged catalog digest → refused;
  3. malformed catalog (bad risk, duplicate type, schema not object) → refused;
  4. risk-label attack: worker proposes an R2 action labeled R0 → rejected by
     the Go validator with `risk_label_mismatch`;
  5. silent-clamp attack: parameters containing a non-writable field value →
     rejected, not repaired;
  6. preset field tampered → rejected with `preset_mismatch`.

### T6 — Novel domain (exit gate 4)
- A SECOND domain fixture (`test/support/climate_domain.rb`): new spec +
  intent catalog + prompt + snapshot as test DATA (C5: the "zero Ruby" claim
  is scoped to production code in gems/). Its catalog declares the climate
  actions (run_vent_cycle, dehumidify, deploy_shade_or_heat, dose_co2,
  downgrade_climate_action, withdraw_climate_action + install_watch_condition)
  with real risk classes and parameter schemas. The fixed graph produces a
  valid, independently verified decision (the Go validator, run against the
  Ruby-produced decision document, passes).

### T7 — Deletes + test updates
- Delete `ACTION_RISKS`, `RISK_ORDER`, the empty-allowlist widening, the
  confidence-threshold selection machine from decision_builder.rb.
- Update the test inventory (G7): `stream_decision_builder_test.rb`
  (HIGH_CONFIDENCE/two-intent/widening cases become catalog-driven cases),
  `stream_invariants_test.rb`, `stream_episode_crash_matrix_test.rb`,
  `stream_learning_loop_test.rb`, and the e2e assertion (`start_aerator` R1 —
  now from the aquaculture catalog).

## Test mode labeling

All P4 gate tests are fixture-labeled; the novel-domain test uses the same
fixture endpoint (no real model). The Go validator tests are pure unit tests
over the pinned fixtures.

## Deferred

- Compensation/withdraw/downgrade consumption (P6, with RECONSIDER).
- Calibration-gated automation (P8). Policy/rate-limit ENFORCEMENT is Go-side
  and lands with the P4 validator wiring where the pipeline exists today.
