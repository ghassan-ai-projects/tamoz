# Calibration-artifact generator — parameterize the domain input

Status: **draft v2** — gap + completeness findings integrated (manifest
entries are the FULLY EXPANDED intent-catalog entries; strict JSON parse via
`Tamoz::Core` (rejects duplicate keys/non-finite/±0) so a malformed manifest
fails at parse; `domain` in the manifest MUST equal the Go `situation_type`
(a typo = permanent silent watch-only); `profile_digest` is
SealedBuild-derived, domain-independent — NOT a manifest field; option
plumbing mirrors `live_alms_telegram` (OptionParser default, parse-error
rescue, `-h/--help`, non-zero exit on a missing/unparseable manifest);
`model_revision` stays `""` on both paths and is excluded from the SHA
document; the primary test ROUND-TRIPS a real manifest (JSON from the
test-domain constants → `--manifest` → output must equal the default path
byte-for-byte, all digests + artifact SHA) proving operator-path digest
fidelity, with the fake-domain test kept as a secondary hardcoding guard;
the shared helper preserves the exact document key order; the
`require "support/…"` lines move INSIDE the default branch (the manifest
path must not load test-support modules)).

## The problem

`script/generate_calibration_artifact` hardcodes its domain input:
`%w[aquaculture climate]` + `require "support/aquaculture_domain"` +
`require "support/climate_domain"`. Those are TEST-SUPPORT fixtures. A real
deployed domain (a Go-side situation spec) cannot be registered by this
script — an operator would have to edit the script's constant list. The
audit-fix discipline ("state it plainly") requires the generator to accept
the deployed domain's documents as INPUT, not hardcode fixtures.

## Bar (finished line)

- The generator accepts an operator-supplied domain manifest (prompt +
  diagnosis catalog + intent catalog per domain) and emits the same
  artifact shape (domain, model_revision="", profile/prompt/diagnosis/
  policy digests, artifact_sha256) — identical digest computation, identical
  Go gate binding.
- The two test-support domains remain the DEFAULT when no manifest is given,
  so the determinism test keeps passing unchanged.
- The primary test proves operator-path digest fidelity: a manifest
  round-tripped from the test-domain constants produces output BYTE-EQUAL
  to the default path (all digests + artifact SHA).

## Change

- `script/generate_calibration_artifact`:
  - Gains `--manifest PATH` (JSON: `{"domains": [{"domain": "...",
    "prompt": "...", "diagnosis_catalog": [...], "intent_catalog": [...]}]}`),
    parsed STRICTLY via `Tamoz::Core` (duplicate keys/non-finite/±0 reject).
    `domain` must equal the Go `situation_type`.
  - The `require "support/…"` lines move inside the default branch; the
    manifest path loads no test-support modules.
  - Refactor: extract `build_artifact_from(domain, prompt, diagnosis_catalog,
    intent_catalog)` (the 3 digests + SealedBuild profile + document assembly
    with the exact key order `domain, profile_digest, prompt_sha256,
    diagnosis_catalog_sha256, policy_digest`), used by BOTH the default
    branch (module constants → helper) and the manifest branch (manifest
    documents → helper). The emitted entry is derived from that document via
    merge (`model_revision` + `artifact_sha256` appended) — the SHA-bound
    document order is preserved byte-for-byte; the entry wrapper order is an
    implementation detail no consumer depends on. Manifest validation:
    object root, non-empty domains array, each entry an object with a
    non-empty-string `domain` (whitespace-only rejected) and the three
    document keys present, and no duplicate domains.
  - Option plumbing mirrors `live_alms_telegram`: OptionParser default,
    input-class rescue (`OptionParser::ParseError, ArgumentError,
    Tamoz::Core::JCS::Error, Errno::ENOENT`) → non-zero exit with a clear
    message (an internal bug surfaces with its backtrace), `-h/--help`.
  - `model_revision` stays `""` on both paths (Go registration value),
    excluded from the SHA document. **State plainly**: nothing in the repo
    consumes `CALIBRATION_ARTIFACTS.json` yet — the operator registration
    (filling `model_revision` from the Go spec digest into the
    `calibration_artifacts` table) is deploy-time, still unwired.
  - **Fail-closed property**: a degenerate or mismatched manifest catalog
    binds a different `policy_digest`, so the Go gate (which joins on
    domain + digests for R2+) refuses — watch-only. A bad manifest can never
    GRANT an intent, only fail to unlock.
- `test/p8_rollout_test.rb`:
  - Existing determinism test unchanged.
  - NEW primary test: round-trip a real manifest — `JSON.generate` the
    test-domain constants → write to a temp file → `--manifest` → assert the
    output equals the default-path output EXACTLY (digests + artifact SHA).
  - NEW secondary test: a manifest with a single non-fixture domain (e.g.
    "greenhouse-prod", inline prompt + one-entry catalogs) generates a
    well-formed artifact whose SHA binds the manifest documents — guards
    against future domain-name hardcoding in the manifest path.

