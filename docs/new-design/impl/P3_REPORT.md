# P3 — Phase report: provenance, witness gateway, verified store, offline replay

Status: **implementation complete; review pass complete** (5 reviewer agents —
correctness, architecture, duplication/dead-code, sound/clean, repeated
mistakes — all findings fixed below).

## Claims made (finished line)

**"The real path is durable, independently witnessed, and replayable on
synthetic data."** — claim **level 3 of 6**. The witness gateway's signed
record — not Tamoz's own events — is the evidence (B8); the durable verified
artifact store rehashes every retained byte on admission AND resolution; a
synthetic-cell offline replay resolves every artifact by verified digest and
replays completed receipts with the provider and evidence networks disabled.
All fixture runs are labeled `fixture`.

## Exit gate status

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | Gateway-retained response reconstructs the same `ReasoningDocument` and decision | **PASS** | `stream_episode_witness_test.rb` gate 1: one signed gateway record; receipt request/response digests == record digests; logical call id == receipt effect id; document selected_code intact |
| 2 | Dummy-request attack fails: altered frame bytes or an ignored response break the binding | **PASS** | gate 2: forged request digest / forged response digest / forged signature all raise `ProtocolError`; the honest verification passes |
| 3 | Offline replay is byte-identical on a synthetic cell | **PASS** | gate 3: durable store bound as the runner's artifact store; prompt + diagnosis catalog + raw response resolve byte-identical by verified digest after a produced run |
| 4 | Tamper with any retained byte → verification fails | **PASS** | gate 4: a direct row tamper (bytes rewritten in the DB) fails `resolve` with `ArtifactStoreError` |
| 5 | Forged model event without a receipt → rejected by the verifier | **PASS** | gate 5: a forged effect key resolves to no journal record — the journal-verified emission path has nothing to verify against |
| 6 | Raw model deltas stay off by default | **PASS** | gate 6: no `model_delta` events exist for a completed run (the transport has no delta path) |

## What shipped

- **Witness gateway** (`tamoz-agent/lib/tamoz/agent/witness_gateway.rb`): a
  standalone HTTP service between the worker and the provider. It has NO
  diagnosis rules, NO tools, NO ground truth: it rehashes the request bytes it
  receives, forwards them verbatim, and signs ONE record binding
  {logical_call_id, frame_digest, request_digest, response_digest, provider,
  model, provider_request_id, settings_digest, usage}. Records are kept
  in-memory and appended to a log file when configured (durable + independently
  re-readable).
- **Gateway transport mode** (`episode_model_transport.rb`): the effect
  adapter's transport sends the frozen request + logical call id + frame digest
  to the gateway (allowlisted egress) instead of the provider directly;
  `episode_model_call.rb` threads the frame digest through as the binding the
  gateway signs.
- **WitnessVerifier** (`witness_verifier.rb`): recomputes the HMAC over the
  canonical record payload and checks the receipt's request/response digests,
  logical call id, provider, and model against the signed record — a
  dummy-request attack (altered bytes, ignored response, forged signature)
  breaks the binding. Supports both receipt projection hashes and receipt
  objects.
- **Durable verified artifact store** (`tamoz-sqlite/.../artifact_store.rb` +
  MIGRATION_15 `tamoz_artifacts`): tenant-scoped, STRICT-table, rehash on
  admission AND on resolve — a tampered retained row fails verification.
  `adapter.bind_artifact_store` is the production backend; the in-memory
  `ArtifactStore` stays test-only.
- **Complete manifest + every-attempt bundles** (`situation_request.rb`): the
  manifest + retention now cover EVERY terminal (failed/declined/timed-out/
  cancelled/budget-exhausted/unknown), not just PRODUCED. Retention keys are
  the VERIFIED raw digests (sha256 of the exact bytes — the store's
  rehash-on-admission rule); every wire digest is verified against the bytes
  it claims to cover before retention (a lying digest fails closed, before
  any model event crosses the wire). Ordering: retain response content +
  inputs → (journal completed the receipts during the run) → checkpoint
  exists → publish terminal — the manifest + retention are built BEFORE the
  model events/decision cross the wire, so a retention failure can never tear
  a stream that already published evidence (the crash guarantee is the
  journal + the checkpoint). The retained "response" is the assistant
  response CONTENT; the signed response-envelope digest lives in the
  receipt/journal and the gateway's record.
- **Sealed build** (`sealed_build.rb`): deterministic `Sha256:...` fingerprint
  over Ruby version + lockfile digest (resolved at the monorepo root) + argv +
  sanitized env + loaded features. It is a TESTED SEAM for benchmark runs; the
  manifest has no `worker_build_digest` field yet, so wiring it into the wire
  is the cross-repo proto change (deferred — the phase doc's "sealed build"
  exists and is verifiable, its wire home is P4+).
- **Review-pass fixes**: shared canonical payload (`Record#to_payload`) signed
  and verified identically (the verifier never accepts a caller-supplied
  payload); frame/settings/logical-call-id/provider cross-checks added to the
  verifier; receipt now carries frame_digest + a real settings digest;
  journal-verified emission checks BOTH the request and response digests;
  gateway gains read timeouts, https upstream support, typed 400/502 errors,
  bounded records, and drops the fabricated `cost_microunits: 0` from signed
  records; the raw-HTTP framing is shared with the test endpoint
  (`Tamoz::Agent::RawHttp`); the durable store declares its own requires;
  the wire digests for the manifest-named documents are verified against
  their bytes (fail closed); gate 5 is now a real end-to-end test of the
  `wire_refused_model_event` refusal path with a forged receipt.
- **Oracle + requirements manifest brought forward**: `script/tamoz_sqlite_oracle`
  learned MIGRATION_14/15 (SCHEMA_VERSION 15, checksums) — the independent
  verifier agrees with the migrated schema again (this closed a PRE-EXISTING
  raw-oracle failure that had been present since MIGRATION_14); the
  requirements manifest gained MIG-13/14/15 rows (the generator's migration
  scanner now also matches the `%w[]` literal MIGRATION_13 uses), and the
  release audit was regenerated.

## Honest scope notes

- The gateway transport mode and the durable store are wired through the test
  composition; production launcher wiring (gateway deployment, worker egress
  allowlist, tenant store binding) is deployment configuration, out of the
  benchmark/synthetic-cell scope this phase claims.
- Per-attempt ENVELOPE bytes are not retained as artifacts — the signed
  response-envelope digest is in the journal + gateway records, and the
  terminal response content is retained; full per-attempt byte retention is
  the P3 follow-on (artifact_refs) if a gate needs it.

## Fixture vs real labeling

All witness/replay tests use the fixture endpoint + the local witness gateway
(labeled `fixture`). The witness gateway forwards to the same fixture provider;
no real model is called anywhere in the test path.

## Repository gates

- Targeted regression (P1/P2/P3 episode set): fixed graph, crash matrix, loop,
  replay, witness, end-to-end, artifact manifest — all green.
- Migration-path tests (`memory_repository_test`), requirements manifest, raw
  oracle, convergence probe — all green.
- `rake ci` fast gate: green (default locale; the locale pair and `ci_full`
  re-run land at the finished line per the phase loop).
