# tamoz-evals-runner

The execution side of Tamoz's evaluation system. This gem owns the harness,
scorecard, treatment, and benchmark runtime separated from `tamoz-evals`'
artifact verifier.

Every run receives a versioned `runner-input-v1` manifest with an absolute
external root and digest-pinned input documents. The runner does not ship
corpora, scripted models, MCP servers, provider fixtures, or repository-root
fallbacks. Test and operator adapters supply those inputs outside the gem.

The public entry points are `Tamoz::Evals::Runner::InputManifest` and
`Tamoz::Evals::Runner::ScorecardSummaryConsumer`. The installed command is:

```sh
tamoz-eval-runner scorecard agent-smoke --input-manifest PATH
tamoz-eval-runner treatment memory --input-manifest PATH
```

The verifier remains in `tamoz-evals`:

```sh
tamoz-eval verify path/to/artifact.json
```
