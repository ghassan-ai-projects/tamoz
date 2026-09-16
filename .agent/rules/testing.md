# Testing — never pay real time

- Inject the wait; never `sleep`. The gateway drainer paces for real: pass `sleeper: ->(_) {}`.
- Fast because it *fails early* is not fast.
- A regression test you have not seen fail proves nothing: stash the fix, watch it fail.
- Don't weaken the property under test for speed — keep `WAL` + `synchronous=FULL`.
- Irreducible process/kill/socket tests go in `SLOW_TESTS`.
- A deadline the child's own startup must fit inside is a race, not a test — Ruby boot can
  be the whole budget. Size it for the boot, or drop the case; don't widen the sleep.
- `rake test_profile` after adding gates; refresh `TEST_WEIGHTS`.
