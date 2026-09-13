# Audit 014 — `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_durable_cli_adapter.rb`

Rank 14 · 1025 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major, 2 minor) · Bar fails: PLACE, SIZE, NAME

Production evals code that folds four responsibilities into one class and crosses the storage
boundary with `__send__` raw SQL against another module's schema.

## Findings

- **[major][PLACE]** The 860-line adapter (ClassLength disabled) folds CLI orchestration, subprocess
  crash-injection, hard-zero policy evaluation, and ~20 catalog metric projections into one class.
  Owning seam: the metric/hard-zero projections belong in an oracle module like the sibling
  `OpenclawCommsOracles`. (openclaw_durable_cli_adapter.rb:20-855, 446-532, 611-701)
- **[major][PLACE]** Production code crosses the storage boundary via
  `runtime.adapter.__send__(:read, ...)` with raw SQL JOINs over `tamoz_effects`/
  `tamoz_effect_attempts`, plus raw polling SQL in EffectPoller. Owning seam: the tamoz-sqlite
  effect-receipt read API (the public `effect_census` is already used at 920-933).
  (openclaw_durable_cli_adapter.rb:39-63, 241-262, 935-977)
- **[minor][SIZE]** Over the 5-param ceiling with ParameterLists disabled: `initialize` takes 7,
  `result_for` takes 8. Owning seam: the three oracle overrides ride one keyword value.
  (openclaw_durable_cli_adapter.rb:66-76, 158-159)
- **[minor][NAME]** `Tamoz::SQLite.const_get(:Wire, false)` obfuscates a directly requireable
  constant; reference `Tamoz::SQLite::Wire`. (openclaw_durable_cli_adapter.rb:1003)
