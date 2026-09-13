# Audit 038 — `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/readiness.rb`

Rank 38 · 701 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: SIZE

Method-level discipline is good, but one 700-line static class fuses manifest-schema validation
with filesystem and provider-trace evidence verification — and each artifact is verified twice per
`evaluate`.

## Findings

- **[major][SIZE]** The all-static Readiness class (ClassLength disabled) mixes three seams:
  manifest-schema validation (`validate_*`), artifact filesystem verification
  (`resolve_artifact_path`, file digesting, secret scanning), and provider-trace/receipt
  cryptographic verification. Owning seam: an artifact+trace evidence verifier module beside the
  schema gate. (readiness.rb:14-697, 457-596)
- **[minor][DUP]** `evaluate` runs `artifact_reasons` twice — once via `control_reasons`, again via
  `artifacts_verified?` — re-reading and re-digesting every mission artifact per call. Compute the
  reasons once, derive the flag. (readiness.rb:59-69, 457-463, 499-501)

## Resolution — 2026-09-11

- **[minor][DUP] fixed.** `evaluate` computed `artifact_reasons` twice — once through
  `control_reasons` and again through `artifacts_verified?` — so every mission artifact was
  read, digested and secret-scanned twice per call. It is now computed ONCE in `evaluate` and
  threaded into `evidence_reasons`/`control_reasons`, with the `artifacts_verified` flag
  derived from the same pass. `artifacts_verified?` became unused and is deleted (it was
  private, no external callers). The flag's exact prior semantics are preserved, including
  `artifact_root_base && …` yielding nil (not false) when no root is given.
