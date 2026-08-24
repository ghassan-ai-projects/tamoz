# 02 — The shared kernel (the part that has to be right)

The four vertical gems look independent, but three of them lean on kernel
symbols that today sit at the top of `agent.rb`'s require chain. You cannot
extract `memory`/`healing`/`improvement` against a _base_ gem until that base
gem exists and owns those symbols. This document isolates exactly what the
kernel must contain and the two coupling knots to untie first.

## What the verticals actually reach for

Measured references from `memory/`, `healing/`, `improvement/`, `profile/` into
non-own-namespace symbols:

| Symbol | Used by | For what |
|--------|---------|----------|
| `Plan` | memory (record, retrieval, consolidation), improvement | `Plan.deep_freeze`, `Plan.parse_object`, `Plan.string` — JSON/immutability helpers |
| `EffectDispatcher` | memory/consolidation, healing/remediation, improvement/candidate_lifecycle, healing/rule | `EffectDispatcher.run`, `EffectDispatcher::MAX_ATTEMPTS` |
| `Event` | memory/retrieval | telemetry trace entries (`Event.new(type:, data:)`) |
| `Error` (base) | healing/errors | error-class ancestry |
| `Session::GRAPH_VERSION` | profile/authority_validator | a version constant |

The first three are the ones that force ordering. The last two are trivial (a
base error class belongs in the kernel anyway; `GRAPH_VERSION` should be a
kernel/graph constant, not reached through `Session`).

## Knot 1 — `Plan` is a value type doing utility work

`Plan` is `Data.define(:goal, :done_when, :steps)` — a domain model of a
deliberation plan. But it has accreted the codebase's general helpers:

```ruby
Plan.deep_freeze(hash)      # recursive freeze
Plan.parse_object(text)     # strict JSON object parse
Plan.string(v, name:)       # typed string coercion/validation
```

`MemoryRecord` freezes its fields with `Plan.deep_freeze`; `Consolidation`
parses model output with `Plan.parse_object`. Neither has anything to do with
plans. So today, extracting `memory` would drag the entire `Plan` domain type
(and `Step`, and `Deliberation`'s plan handling) along for three utility
methods.

**Recommendation:** before extracting the verticals, move these three helpers
_down_ to `tamoz-core` (e.g. `Tamoz::Core::Values.deep_freeze`,
`Tamoz::Core::Json.parse_object`, `Tamoz::Core::Values.string`) and have `Plan`
delegate to them. Then:

- `memory` and `improvement` depend on `tamoz-core` for the helpers — a
  dependency they already have — and stop needing `Plan` at all.
- `Plan` (the domain type) stays in `tamoz-agent-kernel` with `Deliberation`,
  where it belongs.

This is a small, mechanical, independently-testable change that removes the
single most awkward edge. Do it first.

## Knot 2 — `EffectDispatcher` is the effect seam for three subsystems

`EffectDispatcher.run` is how memory-consolidation, healing-remediation, and
improvement-candidate-application all perform side effects under a deterministic
logical key. It depends on `tamoz-core`, `tamoz-sqlite`, and
`Tamoz::Agent::Tool`. It is genuinely shared infrastructure, not a feature.

**Recommendation:** `EffectDispatcher` belongs in `tamoz-agent-kernel`. It is
correctly a base-layer capability. No inversion needed — just make sure it lands
in the kernel gem and not left behind in the runtime, because all three
verticals import it. Move its 16-branch `run` verbatim in Stage A; simplify it in
Stage B of the kernel phase (see [03](03-sequencing-risks-namespace.md)) — the
phase is not done while it is still flagged.

## Knot 3 — `Event` is defined in the wrong layer

`Tamoz::Agent::Event = Data.define(:type, :data)` currently lives in
`runtime.rb` (the runtime cluster), yet `memory/retrieval.rb` constructs
`Event` values for its recall trace. If `Event` stays in the runtime, `memory`
would depend _upward_ on `tamoz-agent` — the exact inversion we are trying to
avoid.

**Recommendation:** move the `Event` value type down into
`tamoz-agent-kernel` (it is a two-field telemetry value; a natural kernel
citizen). The runtime and CLI keep using `Tamoz::Agent::Event`; only its
definition site changes. This is a one-line move plus a require adjustment.

## The resulting kernel contract

After the three knots are untied, `tamoz-agent-kernel` owns:

- **Records & receipts:** `episode_*`, `model_receipt`, `reasoning_document`,
  `sealed_build`, `witness_*`, `receipt_budget_controller`.
- **The loop engine:** `deliberation`, `plan` (domain type),
  `behavior_version`.
- **Effect & telemetry seams:** `effect_dispatcher`, `Event`.
- **Catalogs & taxonomy:** `diagnosis_catalog`, `intent_catalog`, `skill_set`,
  `errors`.

…and depends only on `tamoz-core`, `tamoz-sqlite`, `tamoz-tools`,
`tamoz-observability`. Nothing above it (session, worker, cli) leaks in.

That is the whole point of doing the kernel first: once it exists, each vertical
gem's dependency line reads `tamoz-agent-kernel` (+ core/sqlite) and nothing
else — a compile-checkable statement that the seam is clean.
