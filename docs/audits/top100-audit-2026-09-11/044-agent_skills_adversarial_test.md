# Audit 044 — `test/agent_skills_adversarial_test.rb`

Rank 44 · 640 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: TEST, DEAD

Excellent adversarial matrix, but the A-20 injection case's central assertions compare two
identically constructed toolboxes and so cannot fail.

## Findings

- **[major][TEST]** `test_a20...` builds `before` and `after` Toolboxes with byte-identical
  arguments, making the names/digest/checks equalities tautological — only `record.body` and the
  two `assert_raises` actually test inertness. Owning seam: construct the comparison toolbox from a
  clean (pre-injection) tree, or assert the hostile body against the toolbox contract directly.
  (test/agent_skills_adversarial_test.rb:289-297)
- **[minor][DEAD]** `ENV.fetch("HOME", ...).then { |_| "${HOME}" }` discards the fetched value; the
  assertion is a plain literal. Owning seam: delete the dead fetch.
  (test/agent_skills_adversarial_test.rb:348)

## Resolution — 2026-09-12

- **[major][TEST] FIXED** — A-20 now compiles the comparison toolbox from the clean pre-injection tree (`skills: clean`) and the hostile toolbox from the injected tree (`skills: hostile`), asserting `clean.epoch != hostile.epoch` first so the names/digest/read-only equalities compare two genuinely different trees and the test can fail; the tautological `checks`/`root` comparisons were dropped (same-literal arguments). The catalog-digest equality is kept deliberately: the capability catalog is body-independent, and that is now a real claim, not a tautology.
- **[minor][DEAD] FIXED** — dead `ENV.fetch(...).then { |_| "${HOME}" }` deleted; the assertion is the plain `"${HOME}"` literal.
