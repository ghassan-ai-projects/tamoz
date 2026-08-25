# Deliberation slice

## Scope

Only `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` is writable in
this slice. Callers and tests were inspected read-only. No tests, lint, Enola,
provider, or live commands are run here.

## Candidate decisions

| Surface | Candidate defect | Decision | Risk |
| --- | --- | --- | --- |
| `merge_tool_surfaces` | Filters and merges two already-named capability surfaces; the intent is explicit. | Leave stable. | Low. |
| `planning_prompt` | Mixes phase-policy selection, planning protocol hash assembly, optional context/skill insertion, and JSON serialization. | Refactor. Extract named planning-input and phase-instruction helpers while preserving insertion order. | Medium: prompt bytes and optional-key order are externally observed. |
| `routing_prompt` | Builds a small routing document and serializes it; its workflow is already readable and does not hide a separate concept. | Leave stable. | Low. |
| `review_prompt` | Builds a small review document in protocol order and serializes it. | Leave stable. | Low. |
| `verification_prompt` | Builds a small verification document with two optional sections; no meaningful lower-level concept is hidden. | Leave stable. | Low. |
| `structural_issues` | Mixes plan-level invariants, per-step validation, and phase-specific ordering policy. | Refactor. Extract the named plan-shape check; retain existing step and order helpers. | Low: preserve issue append order and frozen result. |
| `step_issues` | Keeps the complete validation story for one step, including descriptor dispatch and placeholder checks. | Leave stable. | Low. |
| `descriptor_issues` | Is a focused descriptor validation boundary with an intentional error translation. | Leave stable. | Low. |
| `check_order_issues` | Is a focused action/repair ordering policy check. | Leave stable. | Low. |
| `placeholder_arguments?` | Recursively answers one named placeholder-detection question. | Leave stable. | Low. |
| `parse_review` | Parses and validates one review protocol document; error rescue is part of the boundary. | Leave stable. | Medium if reordered. |
| `parse_verification` | Parses and validates one verification protocol document; error rescue is part of the boundary. | Leave stable. | Medium if reordered. |
| `action_signature` | Selects action steps, canonicalizes patch replacements, and hashes one named signature; the sequence is the concept. | Leave stable. | Medium: digest bytes are externally persisted. |
| `canonicalize_apply_patch_arguments` | Has an explicit normalization name and is already one focused operation. | Leave stable. | Medium: ordering affects signatures. |
| `canonical` | Deliberately delegates the shared canonicalization seam to `tamoz-core`. | Leave stable. | High if changed: cross-gem digest behavior. |

The constants, prompt texts, and module-function surface are also leave-stable:
they are protocol inputs or public names rather than reading-order defects.

## Selected refactor

`planning_prompt` will read as “build the planning input, then render it.” Its
private helpers will name the phase instruction and the protocol document. The
document will be assembled in the existing key order, with planning context and
skill catalog appended at the same points as today.

`structural_issues` will read as “collect plan-shape issues, step issues, and
ordering issues.” The new plan-shape helper will append the existing four
messages in their existing order.

No public method, constant, argument list, output shape, output byte sequence,
validation order, exception class/message, or error timing is intentionally
changed.

## Behavior contract

- Keep every existing public method and constant available with the same
  signature and visibility.
- Keep `JSON.pretty_generate` input hash insertion order byte-for-byte stable.
- Keep optional `planning_context` before optional `skills` in planning prompts.
- Keep structural issue ordering: plan checks, step order, then configured-check
  ordering checks; keep the final array frozen.
- Keep all existing validation, descriptor dispatch, placeholder recursion, and
  rescue behavior unchanged.
- Do not alter canonicalization, action-signature digests, prompt constants, or
  cross-gem seams.

## Final diff concepts

Implemented only in `deliberation.rb`:

- `planning_prompt` now states the top-level operation as rendering the named
  planning input. `planning_input` owns the existing protocol hash assembly,
  `planning_phase_instruction` owns phase-policy text selection, and
  `add_skill_catalog` owns the optional progressive-disclosure section.
- `structural_issues` now states its three ordered review layers: plan shape,
  step validation, and configured-check ordering. `plan_shape_issues` owns only
  the existing four plan-level messages.
- The new helpers are private singleton methods. Existing public methods,
  constants, signatures, prompt text, hash insertion order, and issue ordering
  remain unchanged.
- Callers reread after extraction: `SessionPlanAttempt#plan_call`,
  `SessionPlanAttempt#structural_review`, `Runtime::PlanReview`, and
  `SessionRouting#discovery_plan` still invoke the unchanged public seams.
- `git diff --check` was run. Tests and all repository quality/live gates were
  intentionally not run, so behavioral equivalence remains inspection-based in
  this slice.

## Unimplemented behavior-change proposals

None. A behavior change is not needed for this reading-order refactor.
