# Contributing

Changes must preserve the contracts in `docs/design-v0.1`.

Before opening a pull request:

```sh
rbenv exec bundle exec rake ci
```

Behavioral changes require evaluation evidence. Correctness and safety gates cannot be
traded for a higher aggregate score. New runtime dependencies require an architecture
decision and a clean-process dependency test.

Generated fixtures are refreshed with:

```sh
rbenv exec bundle exec rake fixtures:refresh
```

Commit the generator and generated canonical artifacts together.
