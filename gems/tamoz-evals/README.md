# tamoz-evals

Tamoz's development and release quality system. It is a runtime-coupled development/release
gem: its verifier and scorecard/treatment harness reference `Tamoz::Agent`, `Tamoz::SQLite`,
`Tamoz::Mcp`, `Tamoz::Graph`, and `Tamoz::Scheduler` directly, so it declares those gems as
dependencies. The one-way rule is the inverse edge — no production Tamoz gem depends on
`tamoz-evals` — enforced by `test/dependency_isolation_test.rb`.

```sh
tamoz-eval verify path/to/artifact.json
tamoz-eval scorecard agent-smoke
```

The gem includes its public conformance cases, honest baseline, case/evidence/result JSON
schemas, verifier, and the internal bounded subprocess primitive used by fixed runners. See
the repository's `docs/evaluation-artifacts-v1.md` for the exact v1 canonicalization,
provenance, evidence-containment, and exit-code contract.

The optional `agent-smoke` profile runs 12 controller-scripted public cases over the
installed `tamoz-agent`. The profile reports deterministic metadata and hard gates; it is
not a live-model benchmark, protected holdout, or operating-system sandbox.
