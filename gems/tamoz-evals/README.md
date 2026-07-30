# tamoz-evals

Tamoz's development and release quality system. The artifact verifier is stdlib-only and is
never a runtime dependency of a production Tamoz gem.

```sh
tamoz-eval verify path/to/artifact.json
```

The gem includes its public M0 conformance cases, honest baseline, JSON schemas, and
verifier. See the repository's `docs/evaluation-artifacts-v1.md` for the exact v1
canonicalization, provenance, evidence-containment, and exit-code contract.
