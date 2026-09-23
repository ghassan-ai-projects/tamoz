# Testing — never pay real time

- Inject the wait; never `sleep`. The gateway drainer paces for real: pass `sleeper: ->(_) {}`.
- Fast because it *fails early* is not fast.
- A regression test you have not seen fail proves nothing: stash the fix, watch it fail.
- Don't weaken the property under test for speed — keep `WAL` + `synchronous=FULL`.
- Irreducible process/kill/socket tests go in `SLOW_TESTS`.
- A deadline the child's own startup must fit inside is a race, not a test — Ruby boot can
  be the whole budget. Size it for the boot, or drop the case; don't widen the sleep.
- `rake test_profile` after adding gates; refresh `TEST_WEIGHTS`.
- **A file this session creates is mode 600; `gem build` then refuses it.** `packaging_test` is the
  only gate that notices, and it reports it as 15 errors in gem *building*, not as a permission
  problem: `Gem::InvalidSpecificationException: specification has warnings`. `chmod 644` every new
  file (dirs `0755`, scripts `0755`) in the same change, or `rake test_slow` goes red for a reason
  no failure message names.
- **A probe that executes scripts inherits their side effects.** `test/script_context_bootstrap_test.rb`
  globbed `script/*` and ran each hit, which ran `script/generate_legacy_session_fixture` and
  rewrote a committed fixture — the *next* test to read it went red. Name the subjects a runner
  probe covers; never discover them by glob.
- **A test that passes locally and fails only on CI is usually reading the WORKING TREE, not the
  checkout.** `documentation_test` resolves every markdown link against the filesystem, so a tracked
  doc linking to an untracked directory (`docs/coding-harness/README.md` →
  `docs/active-investigation/`) resolves on the author's machine and dangles in CI, which checks out
  tracked files only. To reproduce a doc/packaging failure, move the untracked path aside first —
  `git stash` does not cover untracked files and will "reproduce" nothing.
- **Fix the failure the pipeline reports, not the one you inferred.** A `FAILED:` line lists every
  file in the failing SHARD, not every failing file: one assertion fails and shard-mates are named
  with it. Read the numbered failure bodies at the end of the output to find the real subject —
  the CI summary's file list is not a to-do list.
