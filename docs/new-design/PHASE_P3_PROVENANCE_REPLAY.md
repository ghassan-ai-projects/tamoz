# P3 — Provenance and replay

Bar rules exercised: B3, B8, B10.

## Goal

An independent party can prove the model call happened with the exact bytes claimed, and can
rebuild the same decision offline. Tamoz's own events stop being evidence.

## In scope

- **Witness gateway.** Benchmark-controlled, separately credentialed. Worker egress allowlisted to
  it. It rehashes the frame, builds the provider request with a frozen adapter, sends it, and
  signs one record binding: logical call id, frame/request/response digests, provider, model,
  request id, settings, usage. It contains no diagnosis rules, no tools, no ground truth.
- **Durable verified artifact store.** Tenant-scoped backend behind the existing `ArtifactStore`
  interface. Every retained `(digest, bytes)` pair is rehashed on admission. In-memory backend
  stays test-only.
- **Complete manifest.** Spec, objective, prompt, decision schema, tool catalog, diagnosis
  catalog, skill set, model policy resolution, request/response, receipts, graph definition
  digest, worker build digest, episode/attempt/fence, run id.
- **Every-attempt bundles.** Failed, declined, timed-out, cancelled, budget-exhausted, and unknown
  attempts all persist evidence. Ordering: retain response bytes → complete/mark-unknown receipt →
  checkpoint → publish terminal.
- **Offline replay.** Provider and evidence networks disabled. Every artifact resolved by verified
  digest. Completed receipts replayed. Must produce the same parsed document and the same decision
  bytes. Does not claim the provider is deterministic.
- **Sealed build for benchmark runs.** Ruby version, lockfile digest, argv, sanitized env, loaded
  feature manifest. Graph digest alone is not enough — node descriptors carry caller-supplied
  version strings, not source (`node_spec.rb:42-50`).
- **Identity preserved.** The logical call key and sub-receipt semantics from P0B/P2 are
  unchanged. The gateway is the transport the effect adapter calls; its signed record binds to
  the same logical call key.

## Out of scope

- Production tenant-data privacy controls (P8). Synthetic/simulator cells are the exact-replay
  target first.

## Exit gate

1. Gateway-retained response reconstructs the same `ReasoningDocument` and decision.
2. Dummy-request attack fails: altered frame bytes or an ignored response break the binding.
3. Offline replay is byte-identical on a synthetic cell.
4. Tamper with any retained byte → verification fails.
5. Forged model event without a receipt → rejected by the verifier.
6. Raw model deltas stay off by default (they can leak sensor data, memory, skills).

## Allowed claim

**"The real path is durable, independently witnessed, and replayable on synthetic data."**
Level 3 of 6.
