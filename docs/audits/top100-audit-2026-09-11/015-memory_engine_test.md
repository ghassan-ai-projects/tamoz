# Audit 015 — `test/memory_engine_test.rb`

Rank 15 · 1009 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: DEAD, DUP, TEST

Genuine memory-surface coverage with three real blemishes: a no-op guard probe dressed as a check,
heavy promote boilerplate, and a private-method probe.

## Findings

- **[minor][DEAD]** The no-model probe object in `test_no_model_call_decides_admission` is never
  injected into any admission call — the bare `probe` statement is a no-op and its comment claims a
  guard that cannot fire. Pass the probe where a model is accepted or delete it.
  (memory_engine_test.rb:380-384, 406)
- **[minor][DUP]** `test_wisdom_promotion_gates` repeats the identical 6-kwarg `promote` boilerplate
  five times. Owning seam: a local helper owning the shared evaluation/holdout/gate defaults.
  (memory_engine_test.rb:895-951)
- **[minor][TEST]** Asserts durable internals via `@engine.lifecycle.send(:current_record, ...,
  allow_deleted: true)`. Owning seam: the repository's public versioned-read seam.
  (memory_engine_test.rb:333)

## Resolution — 2026-09-11

- **[minor][DEAD] fixed.** The no-model `probe` in `test_no_model_call_decides_admission` was
  never injected into any admission call (admission takes no model), so the bare `probe`
  statement and its comment proved nothing. Deleted; the engine is built with no model at
  all, so each admission deciding correctly IS the P11-13 proof.
- **[minor][DUP] fixed.** `test_wisdom_promotion_gates`'s five 6-kwarg `promote` calls now go
  through a local `promote_wisdom(candidate:, holdout_passed:, human_evidence:, snapshot:,
  version:)` helper owning the constant development-evaluation and the shared defaults.
- **[minor][TEST] deferred.** `@engine.lifecycle.send(:current_record, ..., allow_deleted:
  true)` has no public equivalent — the repository exposes `version`/`current_version` but no
  deleted-inclusive current read. Surfacing that is a repository API addition, deferred rather
  than added for one assertion.

Note: this file carries 1 pre-existing failure + 2 errors
(`consolidation failed: Tamoz::Core::ProtocolError`) unrelated to these changes.
