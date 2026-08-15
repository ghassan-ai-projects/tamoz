# P4 — Intent authority

Bar rules exercised: B9, B10.

## Goal

The domain's actions come from a spec-bound intent catalog, verified independently by Agentic
Stream. Every hard-coded domain table in Tamoz is deleted. The model recommends; it never
declares authority.

## In scope

- **Intent catalog in the spec.** Per intent: unique type, exact configured risk, parameter schema
  digest, optional named parameter presets, explicit model-writable fields, policy, rate limit,
  optional withdraw/downgrade compensation targets.
- **Wire.** The compiled request carries the canonical, digest-bound catalog. Missing, duplicate,
  malformed, digest-mismatched, or empty catalog fails before any model call.
- **`decide` node rebuild.** Builds from the validated document + catalog only. Model output is a
  recommendation: at most one actionable intent in v1, preferring operator-authored presets.
  Direct model parameters only for catalog-declared model-writable fields.
- **Agentic Stream independent validation.** Proposed type is declared. Proposed risk **equals**
  the declared risk — not merely under the ceiling (closes `validator.go:138-163`). Parameters
  validate against the per-intent schema. Preset/builder fields byte-identical to the compiled
  catalog. Policy, approval, rate limit enforced before dispatch. Rejection never silently clamps
  or substitutes.
- **Confidence cannot unlock authority.** Confidence may cause abstention or watch. Automatic
  action additionally needs a calibration artifact bound to model revision, profile, prompt,
  catalog, domain. Missing calibration = shadow/watch-only.

## Deletes (only after both sides enforce the catalog)

- `ACTION_RISKS`, `RISK_ORDER` (`decision_builder.rb:15-38`).
- Empty-allowlist widening to all actions (`decision_builder.rb:204-207`). Fail closed instead.
- Confidence-threshold intent selection machine (`decision_builder.rb:135-161`).
- `COMPENSATION_RISK`, `WITHDRAW_TYPES`, `DOWNGRADE_TYPES`, `family_for` move out in P6 together
  with the reconsideration logic that uses them.

## Exit gate

1. Missing / duplicate / forged / empty catalog → fail closed before any model call.
2. Risk-label attack (model claims lower risk than declared) → rejected by Agentic Stream.
3. Silent clamp or substitution attempt → rejected, not repaired.
4. A novel domain (new spec + catalog, zero Ruby) produces a valid, independently verified
   decision through the fixed graph.
5. Cross-repo conformance fixtures cover old/missing/forged catalog cases.

## Allowed claim

**"New domains are authoring-only"** (jointly with P5). Level 4 of 6.
