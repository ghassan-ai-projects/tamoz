# Audit 061 — `gems/tamoz-evals-runner/lib/tamoz/evals/harness/sqlite_trace_recorder.rb`

Rank 61 · 567 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major) · Bar fails: DUP

Disciplined protocol recorder undermined by three validation helpers copy-pasted verbatim from
sibling harness classes.

## Findings

- **[major][DUP]** `deeply_frozen?`, `validate_exact_hash`, `bounded_utf8` are character-identical
  copies of helpers in sqlite_scenario_registry.rb:351 and sqlite_selector_control.rb:583/626
  (near-dup in subprocess_runner.rb:474). Owning seam: one shared frozen/shape validation module
  beside DeepFreeze in tamoz-evals. (sqlite_trace_recorder.rb:473-551)

## Resolution — 2026-09-11

- **[major][DUP] fixed for the audited file.** Created `Tamoz::Evals::ShapeValidation`
  (module_function: module methods + private instance methods on include) beside `DeepFreeze`
  in tamoz-evals, holding `deeply_frozen?`, `validate_exact_hash`, `bounded_utf8` (all raising
  `Tamoz::Evals::ExecutionError`). `SQLiteTraceRecorder` now `include`s it and its three local
  copies are deleted; call sites are unchanged. Tests green (11 runs, 952 assertions).

Follow-up (out of this file's scope): the identical copies in `sqlite_scenario_registry.rb`
and `sqlite_selector_control.rb` should migrate to `ShapeValidation` too, but they hold the
helpers in different method contexts (instance vs singleton vs nested class), so each needs a
per-file include/extend decision — left for those files' own cleanup (043) rather than
editing unaudited files blind here. The canonical seam now exists for them to adopt.
