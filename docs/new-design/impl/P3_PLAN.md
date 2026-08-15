# P3 — Implementation plan: provenance, witness gateway, complete manifest, offline replay

Status: **draft v1** — reviewed by gap-searcher + completeness-checker before
implementation.

Bar: PHASE_P3_PROVENANCE_REPLAY.md exit gate (6 items). Bars: B3, B8, B10.
Claim: **"The real path is durable, independently witnessed, and replayable on
synthetic data."** Level 3 of 6.

## Architecture (delta from P2)

- **The witness gateway becomes the transport the effect adapter calls.** The
  frozen episode transport (P1) is split: the FRAME + frozen-request building
  stays client-side; the SENDING moves to a separately-credentialed gateway
  that rehashes the request bytes, forwards to the provider, and signs ONE
  record binding {logical call id, frame/request/response digests, provider,
  model, provider request id, settings, usage}. The gateway has NO diagnosis
  rules, NO tools, NO ground truth.
- **The signed gateway record is the witness** — Tamoz's own events stop being
  evidence (B8). The effect adapter's receipt binds to the SAME logical call
  key; the verifier checks the gateway record against the receipt.
- **Durable verified artifact store** behind the ArtifactStore interface:
  every `(digest, bytes)` rehashed on admission; SQLite-backed, tenant-scoped;
  the in-memory backend stays test-only.
- **Complete manifest + every-attempt bundles:** failed/declined/timed-out/
  cancelled/budget-exhausted/unknown attempts persist evidence with the exact
  ordering: retain response bytes → complete/mark-unknown receipt → checkpoint
  → publish terminal.
- **Offline replay** on a synthetic cell: provider + evidence networks
  disabled; every artifact resolved by verified digest; completed receipts
  replayed → same parsed document + same decision bytes.
- **Sealed build** for benchmark runs: Ruby version, lockfile digest, argv,
  sanitized env, loaded feature manifest (graph digest alone is not enough).

## Tasks

### T1 — Witness gateway (tamoz-agent, a real HTTP service)

- `WitnessGateway`: a standalone HTTP server (like LocalModelEndpoint but with
  signing + durable records) that:
  1. receives the frozen request bytes + the logical call id + the frame
     digest (the effect adapter sends them),
  2. REHASHES the request bytes (digest = sha256 of the exact body),
  3. forwards the body verbatim to the configured provider endpoint,
  4. signs one record: {logical_call_id, frame_digest, request_digest,
     response_digest, provider, model, provider_request_id, settings_digest,
     usage} with a gateway-only HMAC/ed25519 key,
  5. persists the record (durable) + returns the response bytes.
- The effect adapter (`EpisodeModelTransport` gains a gateway mode): the
  request goes to the gateway (allowlisted egress), NOT the provider directly.
- Worker egress: the transport's endpoint config points at the gateway; the
  gateway's upstream points at the provider.

### T2 — Verified artifact store (tamoz-stream)

- `VerifiedArtifactStore`: SQLite-backed, tenant-scoped, implements the
  `ArtifactStore` interface (retain/resolve); every admitted `(digest, bytes)`
  is rehashed (digest must match) before retention — a tampered byte fails
  admission and any resolution. The in-memory `ArtifactStore` stays test-only.

### T3 — Complete manifest + every-attempt bundles (situation_request.rb)

- `build_artifact_manifest` gains: skill_set_sha256, model_policy resolution
  (role name/provider/model), the receipts' digests, the graph definition
  digest, the worker build digest (sealed build), run id.
- Every-attempt bundles: the runner retains the response bytes + manifests for
  FAILED/DECLINED/TIMED_OUT/CANCELLED/BUDGET_EXHAUSTED/unknown terminals with
  the ordering: retain response bytes → (journal completes/marks unknown the
  receipt) → checkpoint → publish terminal. The P1 "manifest only for
  PRODUCED" rule is replaced by "manifest + retention for every terminal".

### T4 — Sealed build (tamoz-agent)

- `SealedBuild.fingerprint`: Ruby version, Gemfile.lock digest, ARGV, sanitized
  ENV (only allowlisted vars), and the loaded feature manifest. Injected into
  the manifest's worker_build_digest.

### T5 — Offline replay on a synthetic cell (test)

- A synthetic cell: fixed snapshot + catalog + prompt + fixture responses; run
  once (gateway + provider on), then replay with provider AND gateway network
  disabled — every artifact resolved by verified digest, completed receipts
  replayed → same parsed document + same decision bytes.

### T6 — Verifier + adversarial tests

- `WitnessVerifier.verify(receipt, gateway_record, artifact_store)`: the
  receipt's request/response digests must match the gateway's signed record
  (dummy-request attack: altered frame bytes or an ignored response break the
  binding).
- Gate tests: tamper with any retained byte → verification fails; a forged
  model event without a receipt → rejected; raw model deltas stay OFF by
  default (the transport never emits deltas).

## Deferred

- Production tenant-data privacy controls (P8). The synthetic/simulator cells
  are the exact-replay target first.
