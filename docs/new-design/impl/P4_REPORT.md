# P4 — Phase report: intent authority

Status: **implementation complete; review pass complete** (5 reviewer agents —
correctness, architecture, duplication/dead-code, sound/clean, repeated
mistakes — all findings fixed below).

## Review-pass fixes

- **Watch fallback is schema-clean and allowlist-gated**: the watch schema
  (both sides) declares the builder-bound `target`/`expires_at` keys; the
  watch fallback requires `install_watch_condition` ∈ allowed_intent_types
  (a misconfigured episode fails typed instead of producing a decision
  Agentic Stream would reject).
- **Catalog policy enforced**: `requires_approval` is digest-bound, carried
  through the validator → intent row, and EvaluateIntent routes such intents
  through the approval pipeline regardless of risk (R1 "approval" can no
  longer auto-dispatch).
- **Full parameter schema** is carried and digested (required/enum/minLength
  are never narrowed); the spec requires `additionalProperties: false`.
- **Builder-bound identity bound independently**: the Go validator checks
  `entity_id` against the dispatched episode, `target` against the entity,
  and the watch `expires_at` against `valid_until` (a tampered entity can no
  longer flow into the command payload).
- **Intent count enforced Go-side**: ≥1 intent, ≤1 actionable (non-watch,
  non-compensation) intent — the v1 at-most-one contract is independent, not
  builder-only.
- **Compensation bypass is kind-scoped**: only a RECONSIDER episode may carry
  `compensates`; a DIAGNOSE worker forging one is rejected.
- **Atomic rate limit**: per-(tenant,type,hour-bucket) counter incremented
  with `RETURNING` before the command is created; an over-limit dispatch
  denies and rolls back (no double-count, no partial command).
- **Dead code removed**: HIGH_CONFIDENCE, canonical_bytes, watch_type?,
  BOUND_PARAMETERS; the redundant rebuild_frame re-verification dropped;
  marshalIntentCatalog now fails closed; rejection reasons + DB CHECK widened
  with the new reasons; reject() errors carry the field.

## Claims made (finished line)

**"New domains are authoring-only"** (jointly with P5) — bars B9/B10, level 4
of 6. The intent catalog is spec-bound, digest-verified on BOTH sides, and the
model's proposal is checked against the catalog's DECLARED risk — never the
model's claim. A novel domain (climate) produces a valid, independently
verified decision with ZERO new production Ruby.

## Exit gate status

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | Missing / duplicate / forged / empty catalog → fail closed before any model call | **PASS** | `stream_episode_intent_authority_test.rb` (0 endpoint hits for missing/forged/duplicate); envelope gate + `build_frame` verify_wire; Go `CompileIntentCatalog` fails closed |
| 2 | Risk-label attack (model claims lower risk than declared) → rejected by Agentic Stream | **PASS** | Go `validateIntent`: proposed `risk_class` must EQUAL the catalog-declared risk — `risk_label_mismatch` (`validator_test.go`) |
| 3 | Silent clamp / substitution attempt → rejected, not repaired | **PASS** | non-writable model value → typed refusal (builder); `preset_mismatch` + `parameter_schema_violation` + `ungrounded_evidence` (Go validator tests) |
| 4 | Novel domain (new spec + catalog, zero Ruby) → valid, independently verified decision | **PASS** | `test_gate4_a_novel_domain_produces_a_decision_with_zero_new_ruby` (climate domain, `run_vent_cycle` R1 from ITS catalog) |
| 5 | Cross-repo conformance fixtures cover old/missing/forged catalog | **PASS** | pinned catalog digest parity (both sides, byte-identical) + `decisionInput` missing/forged/tampered/malformed cases |

## What shipped

**Ruby (tamoz-agent + tamoz-stream):**
- `IntentCatalog` (mirrors DiagnosisCatalog): per-entry exact risk, parameter
  schema + digest, presets, model-writable fields, policy/rate-limit/
  compensation metadata; `verify_wire` (fail closed: missing/forged/
  malformed/duplicate/empty) at build_frame (BEFORE the model call) + at
  decide (defense-in-depth).
- Wire: `EpisodeRequest` gains `intent_catalog_json/sha256` (fields 63/64,
  shared `situation-runtime/intent-catalog/v1` domain digest over the parsed
  array); envelope requires the catalog for DIAGNOSE (kind-scoped; RECONSIDER
  still fails at intake — P6 wires it).
- `decide` rebuild: at most ONE actionable intent (two+ → typed refusal);
  risk = catalog's declared risk; parameters = preset + per-episode bindings +
  model-writable overrides; non-writable model value → typed refusal;
  no proposal / type ∉ catalog ∩ allowlist / risk above ceiling / confidence
  below floor → R0 watch from the catalog; empty allowlist → fail closed.
  Deleted: `ACTION_RISKS`, `RISK_ORDER`, the empty-allowlist widening, the
  confidence-threshold machine. RECONSIDER compensations are catalog members
  with equal risk (G5).
- Test data: aquaculture intent catalog (same risks the deleted table held) +
  the climate domain (novel-domain fixture).

**Go (agentic-stream):**
- Spec: `Intent` gains parameter schema (inline), presets, model-writable
  fields, compensation; schema.json updated.
- `CompileIntentCatalog` (assembler): spec intents → canonical wire form +
  shared-domain digest (parity-pinned); the executor embeds it in the request.
- `decisionInput`: independently digest-verifies the wire catalog (fail closed
  on missing/forged/malformed) and compiles the validator's catalog.
- `validateIntent`: catalog membership (compensations too, G5), risk
  EQUALITY (`risk_label_mismatch`), per-intent schema validation
  (`parameter_schema_violation`), preset-only field equality
  (`preset_mismatch`), `evidence_ids` ⊆ `facts_used`
  (`ungrounded_evidence`).
- Rate-limit enforcement (C2): migration 022 (`intent_dispatches` +
  `rate_limit_per_hour`), EvaluateIntent gate before dispatch, dispatch
  recorded atomically with the command.

## Fixture vs real labeling

All Ruby gate tests use the fixture endpoint; the Go validator tests are pure
unit tests over pinned fixtures. No real model is called.

## Honest scope notes

- The climate domain lives in test support (test data); the "zero Ruby" claim
  is scoped to production code in gems/.
- P8 owns the calibration-gated automatic action; P4's posture is
  proposal-only (dispatch_policy SHADOW default).
