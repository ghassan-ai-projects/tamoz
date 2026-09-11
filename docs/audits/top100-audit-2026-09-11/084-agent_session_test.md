# Audit 084 — `test/agent_session_test.rb`

Rank 84 · 480 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: DUP, TEST, SIZE

Genuine behavioral coverage, but it carries its own copies of the shared test doubles, mints a
fixture through a private method via `__send__`, and one helper exceeds the params ceiling.

## Findings

- **[minor][DUP]** Inline `ScriptedModel`, `plan_for`, `accepted_review` re-spell the same doubles
  found in ~24 sibling test files; no shared seam exists. Owning seam: test/support shared model
  double + plan fixtures. (test/agent_session_test.rb:6-22, 358-372, 407-409)
- **[minor][TEST]** `append_future_version_checkpoint` builds its fixture through private
  `session.app.__send__(:append_checkpoint, ...)` instead of a public writer seam or a shipped test
  factory. (test/agent_session_test.rb:434-453)
- **[minor][SIZE]** `build_session` takes 6 parameters (5 keywords plus `**options`) against the
  ≤5 ceiling. (test/agent_session_test.rb:327-334)

## Resolution — 2026-09-11

- **[minor][TEST] fixed — the seam already existed.** `session.app` is a `Tamoz::Graph::Compiled`
  and `Compiled#append_checkpoint(writer:, **attributes)` is declared ABOVE that class's `private`
  keyword, i.e. already public (production calls it publicly too, e.g.
  `session_context_controls.rb`'s `app.append_checkpoint(...)`). The `__send__` was simply
  unnecessary, not a missing seam — replaced with a direct call, same arguments, no production
  change. No `__send__` remains in this file.
- **[minor][SIZE] fixed.** `ToolPolicy = Data.define(:allow_changes, :checks)` (with a `.default`)
  groups the two cohesive toolbox knobs, so `build_session(model:, root:, adapter:, tools:,
  **options)` is 5 parameters, at the ceiling. No knob was deleted; the three call sites that
  passed `allow_changes:`/`checks:` were updated.
- **[minor][DUP] deferred.** The inline `ScriptedModel`/`plan_for`/`accepted_review` doubles are
  left in place — a shared test/support double spans ~24 sibling files whose variants differ, and
  consolidating them is a dedicated cross-file effort (also noted under 082), not a change to make
  from this one file.

Verified: 11 runs / 72 assertions / 0 failures before AND after; assertion-bearing line count
unchanged at 54; RuboCop clean both sides.
