# Testing — never pay real time

- Inject the wait; never `sleep`. The gateway drainer paces for real: pass `sleeper: ->(_) {}`.
- Fast because it *fails early* is not fast.
- Don't weaken the property under test for speed — keep `WAL` + `synchronous=FULL`.
- Irreducible process/kill/socket tests go in `SLOW_TESTS`.
- `rake test_profile` after adding gates; refresh `TEST_WEIGHTS`.
