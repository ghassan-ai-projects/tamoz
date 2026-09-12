# Audit 070 — `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/scoreboard.rb`

Rank 70 · 525 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 3 minor) · Bar fails: SIZE

The scoreboard works, but one class with ClassLength disabled stacks a tolerant interval reader,
entry schema policy, metric scoring, and atomic persistence — and its instance half must `send`
into its own private class methods four times.

## Findings

- **[major][SIZE]** 525-line class mixes four concerns — artifact interval reading (95-102,
  247-317), entry schema/regression policy (110-239), metric scoring (420-487), and file
  persistence (510-520) — under a ClassLength disable. Owning seam: a Scoreboard::Intervals reader
  module beside the entry policy. (scoreboard.rb:13-521)
- **[minor][PLACE]** Instance code bypasses its own encapsulation via
  `self.class.send(:validate_entries!/:safe_artifact_root?/:build_axis_verdicts/:hard_zero_names,
  ...)` — the singleton/instance split is artificial. Owning seam: shared public module functions
  or an Entry builder. (scoreboard.rb:378, 391, 413-414)
- **[minor][SIZE]** Constructor takes 10 kwargs with ParameterLists disabled. Owning seam: an
  entry-fields Data value shared with ENTRY_KEYS. (scoreboard.rb:352-366)
- **[minor][DUP]** `cost_score`'s Float branch (479) re-derives exactly `normalize_lower_score`'s
  formula (473-474). (scoreboard.rb:477-486)

## Resolution — 2026-09-12

- **[major][SIZE] fixed.** The artifact interval reader moved to `Scoreboard::Intervals`
  (`for_entry`/`directory`/`documents`/`find_interval`) and the entry schema plus
  verdict/hard-zero derivation to `Scoreboard::EntryPolicy`; the class keeps append,
  regression evaluation, metric scoring and the atomic write. The `Metrics/ClassLength`
  disable remains: the file stays above the ceiling as recorded size debt for one remaining
  responsibility, no longer a mix of four concerns.
- **[minor][PLACE] fixed.** The four `self.class.send` bypasses are gone — `EntryPolicy` is
  included at both the class and instance level, so `validate_entries!`,
  `safe_artifact_root?`, `build_axis_verdicts` and `hard_zero_names` are called directly
  (grep: no `send`/`self.class` dispatch left in the file).
- **[minor][SIZE] fixed.** The constructor is 5 params; the six optional caller fields ride
  in an `EntryFields` Data value built by `Scoreboard.append`'s splat, so the CLI scripts
  and tests keep passing `date:`/`notes:`/`track:`/… unchanged. ParameterLists disable
  removed.
- **[minor][DUP] fixed.** `cost_score` defers to `normalize_lower_score` for 0..1 floats and
  feeds it `value.to_f / budget` otherwise — one formula.
