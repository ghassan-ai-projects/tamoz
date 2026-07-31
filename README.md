# Tamoz

Tamoz is a Ruby-native durable agent framework for checkpointed, interruptible, observable,
and evaluation-governed AI workflows.

The repository is a monorepo containing independently publishable gems:

| Package | Responsibility | Runtime dependencies |
|---|---|---|
| `tamoz-core` | Shared values and runtime protocols | stdlib, Zeitwerk |
| `tamoz-graph` | Deterministic graph execution and durability contracts | `tamoz-core` |
| `tamoz-sqlite` | SQLite persistence adapter | `tamoz-graph` |
| `tamoz-agent` | Deliberative agent runtime over RubyLLM | `tamoz-graph` |
| `tamoz-evals` | Conformance, artifact verification, and release evidence | stdlib |

Tamoz Agent is the reference application under `apps/tamoz-agent`. The runtime is being
built risk-first: evaluation contracts precede agent behavior, deterministic execution
precedes persistence, and persistence precedes model integration.

## Current status

The framework has implemented core, graph, and SQLite durability foundations. Tamoz Agent
now also has a deliberately narrow working product: real RubyLLM model calls,
plan-before-action, deterministic and semantic plan review, workspace-confined tools,
human-approved atomic patches, configured verification commands, and final evidence-bound
verification.

```sh
export OPENAI_API_KEY="..."
export TAMOZ_MODEL="gpt-5-mini"
rbenv exec bundle exec tamoz --root . "Explain the persistence boundary"

# Opt in to changes. The model can select "test" but cannot alter its argv.
rbenv exec bundle exec tamoz --root . --allow-changes \
  --check 'test=rbenv exec bundle exec rake test' \
  "Fix the failing test"
```

Read-only mode remains the default. Change mode uses separate reviewed discovery and action
plans, displays the exact diff/command, and asks before every effect. It is not yet
crash-durable. See [`docs/WORKING_SLICE_2.md`](docs/WORKING_SLICE_2.md) for the exact scope.

The authoritative design is committed under [`docs/design-v0.1/`](docs/design-v0.1/).
The evaluation artifact contract is documented in
[`docs/evaluation-artifacts-v1.md`](docs/evaluation-artifacts-v1.md).

## Development

Ruby 3.3 or newer is required. The local version is pinned through rbenv:

```sh
rbenv exec bundle install
rbenv exec bundle exec rake ci
```

Verify an evaluation artifact directly:

```sh
rbenv exec bundle exec tamoz-eval verify \
  gems/tamoz-evals/suites/m0/golden/01_barrier-atomicity.case.json
```

The verifier returns distinct exit codes:

| Code | Meaning |
|---:|---|
| 0 | valid artifact or passing result |
| 1 | gate failure |
| 2 | invalid evidence, schema, digest, or reference |
| 3 | infrastructure failure |
| 4 | insufficient evidence |
| 64 | command usage error |

## Security and guarantees

Tamoz does not claim arbitrary effects execute exactly once. Replay-safe effects require
idempotency, atomic participation, or reconciliation; ambiguous work stops. See
[`SECURITY.md`](SECURITY.md) and the design invariants for the complete boundary.

## License

MIT.
