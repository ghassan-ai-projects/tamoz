# Audit 094 — `test/dependency_isolation_test.rb`

Rank 94 · 443 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: DUP, DEAD

Strong boundary proofs, but the gem-allowlist glob block is copy-pasted through six tests and the
capture3 boilerplate through four.

## Findings

- **[major][DUP]** The
  `allowed = %w[...].flat_map { |name| ... Dir.glob(library.join("tamoz/**/*.rb")) ... }.uniq.sort`
  block is copy-pasted in 6 tests. Owning seam: a `declared_features(*gem_names)` helper beside
  `loaded_features_after`.
  (test/dependency_isolation_test.rb:82-85, 98-101, 114-117, 129-132, 195-198, 276-279)
- **[minor][DUP]** The inline script/Open3.capture3/assert/JSON.parse cycle is repeated in 4 tests
  next to the existing `loaded_features_after`/`loaded_state_after` helpers. One capture helper
  owns it. (test/dependency_isolation_test.rb:25-49, 241-273, 305-334, 365-391)
- **[minor][DEAD]** The regex branch `\Aruby/gems/.+ruby_llm` can never match:
  `loaded_features_after` strips everything through `/lib/` (line 409), so no feature retains a
  ruby/gems prefix. (test/dependency_isolation_test.rb:147)

## Resolution — 2026-09-11

- **[minor][DUP] fixed (allowed-set glob).** The four-line
  `%w[...].flat_map { GEM_ROOTS.fetch(name)... Dir.glob... }.uniq.sort` block, repeated in 6
  tests, is now `declared_features(*gem_names)`; each test reads as the gem union it allows.
- **[minor][DUP] fixed (subprocess capture).** The identical
  `Open3.capture3(clean_environment, RbConfig.ruby, *LOAD_PATH_ARGUMENTS, "-e", script)` +
  `assert status.success?, stderr` + `JSON.parse(stdout)` cycle appeared 6 times (4 tests and
  both existing helpers). All now call `capture_json(script)`, which owns the whole cycle.
- **[minor][DEAD] fixed.** The `\Aruby/gems/.+ruby_llm` alternative could never match:
  `loaded_features_after` strips each path through `/lib/` (`path.sub(%r{.*?/lib/}, "")`), so
  no feature retains a `ruby/gems` prefix. The guard is now `%r{tamoz/evals|tamoz/sqlite}`,
  which is the part that actually fires.

22 runs / 221 assertions green, unchanged from before the refactor.
