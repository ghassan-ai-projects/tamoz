# tamoz-evals

Tamoz's evidence and verification gem. It owns canonical artifacts, schemas,
digests, the verifier, and the verifier-only `tamoz-eval` command. Execution
harnesses, scorecards, treatments, and benchmarks live in the separate
`tamoz-evals-runner` gem and require an explicit external input manifest.

```sh
tamoz-eval verify path/to/artifact.json
```

The gem includes the case, evidence, and result schemas plus the verifier. See
the repository's `docs/evaluation-artifacts-v1.md` for the exact v1 canonicalization,
provenance, evidence-containment, and exit-code contract.
