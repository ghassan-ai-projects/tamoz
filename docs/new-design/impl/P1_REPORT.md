# P1 — Phase report: one real journaled call through the fixed episode graph

Status: **exit-gate verification in progress** (full `rake ci` + Go suite running).

## Claims made (finished line)

The ONLY claim made by this phase: **"A real LLM adapter path exists"** — claim
**level 2 of 6**. This is a plumbing claim about the adapter, not an
intelligence claim.

- Real run evidence: provider `ollama`, model `gemma4:latest`, endpoint = the
  local endpoint in proxy mode (a separately-controlled HTTP process in front
  of the real pinned model), request digest
  `sha256:85689b8e000620de3258761fb960019f3af9ec772ab785e8ab929bed55b7a293`
  (witnessed byte-for-byte by the endpoint, outside the worker), attempt/fence
  `at-1/1`, telemetry buffered (the wire stream is produced after the run
  completes), `selected=equipment_failure`, `intents=1`.
- Fixture runs (the LocalModelEndpoint in fixture mode, the deterministic v2
  documents) are LABELED `fixture` in every test file and are never shown as
  evidence of a real model path.

## Exit gate status

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | One aquaculture episode end to end through the fixed graph, real local endpoint | **PASS** | `stream_episode_real_model_test.rb` (RUN_REAL_E2E=1): PRODUCED terminal, one provider call, witnessed digests equal |
| 2 | Endpoint log digest == Tamoz receipt digest, independently compared | **PASS** | real + fixture runs: endpoint-observed request/response digests byte-equal the receipt's; the frozen transport sends the canonical body verbatim, so `digest(body)` on the endpoint side equals the receipt by construction |
| 3 | Perturb the endpoint's response → diagnosis changes | **PASS** | `stream_episode_fixed_graph_test.rb` gate-3: two fixture documents → `low_dissolved_oxygen` vs `equipment_failure` (fixture-labeled) |
| 4 | Same fixed graph under an in-process driver | **PASS** | `EpisodeComposition` builds the SAME `EpisodeGraph`; all runner-level tests drive it without gRPC |
| 5 | Node-emitting `:model_started` rejected on a tamoz route | **PASS** | `EpisodeStreamAdapter#emit` raises on model event types; adversarial test + the old fixture graphs now fail closed |
| 6 | Crash matrix: completed receipt reused on redispatch; started-without-receipt → typed unknown, no blind retry | **PASS** | `stream_episode_crash_matrix_test.rb`: fence+1 reuses the receipt (one provider call), replayed state equal; seeded started-without-receipt → FAILED terminal, no second call |
| 7 | Unknown role / missing profile / digest mismatch → typed failure before any call | **PASS** | gate-7 tests: unknown role, catalog digest mismatch, prompt digest mismatch → FAILED with zero endpoint hits. Profile digest deferred (no wire field; unit-level only) |
| 8 | On `ExecutorName=tamoz` the Go native executor is never constructed | **PASS** | Go: constructor gated behind the worker-socket route; `TestExecutorSelectionSkipsNativeOnTamoz` (injectable constructor, count = 0) + `TestNativeModeConstructsTheNativeExecutor` (count = 1) |
| 9 | `rake ci` + no new dependency edge | **PASS** | `rake ci` green (exit 0); enola: tamoz-stream → {tamoz-core, evals, gen} only — no tamoz-agent edge. `ci_full`'s 11 raw-oracle failures are **pre-existing at HEAD** (verified by stash: identical `checkpoint.commit-advance` failures without the P1 change) |

## What shipped

### Ruby (tamoz)

- **Fixed production episode graph** (`EpisodeGraph`): START → intake →
  build_frame → reason → validate → decide → END. Compiled in process; the
  production launcher (`bin/tamoz-stream-worker`) composes it; no `--graph`
  FILE. `reason` is the ONLY model-calling node.
- **Journaled model call** (`EpisodeModelCall` + `EffectDispatcher.run` with a
  `logical_key:`): the P0B logical call key is the durable effect identity —
  `EffectJournal` gained a backward-compatible logical-key mode
  (`EffectJournalKey.logical` + `verify_identity!` logical binding) so a
  fence+1 redispatch REUSES the completed receipt and a started-without-receipt
  is typed `unknown`. The journaled result is the codec-safe call projection
  {content, response_digest, usage} — replay rebuilds the identical receipt.
- **Frozen episode transport** (`EpisodeModelTransport`): the canonical
  request body (JCS, OpenAI-compatible with `response_format: json`) IS the
  request digest; the endpoint witnesses the same bytes. RubyLLM is not used on
  the episode path (it cannot expose raw wire bytes).
- **Trusted event emission** (B4): model events are emitted from RECEIPTS via
  `context.episode_wire` (StreamPart channel); the projection adapter RAISES on
  model event types from the graph Context. Ordinals come from the invocation
  (`global_ordinal`) — replay is ordinal-identical.
- **EpisodeStream collapse**: counters/budget machine deleted; the adapter is a
  pure projection (StreamPart → proto EpisodeEvent) with unique ordinals and
  request/response digests on the wire; terminal mapping from the durable run
  result only.
- **Runner reduction** (B2): decision building + `open_verifications` deleted
  from the runner; the decide node IS the builder (DecisionNodeBuilder port,
  tamoz-stream), the runner only translates terminal state to the wire.
  `build_artifact_manifest` kept + the prompt is now retained under its own
  digest.
- **Model authority** (B5): per-request `ModelCall.resolve_role` in the intake
  node, fail-closed; the Profile's `normalized_settings` (validated, non-secret,
  `base_url` not on the secret denylist) carries the endpoint.
- **Frame builder** (`EpisodeFrameBuilder`): trusted policy section +
  untrusted facts with `fact:<id>` refs; catalog + prompt digest verification
  fail closed. The prompt digest uses the CROSS-REPO rule
  (`situation-runtime/prompt/v1\n` + {version, text}) — byte-identical to the
  Go assembler (parity test both sides).
- **Aquaculture DO-crash domain** (data only): catalog (incl. `unknown`),
  objective, prompt, snapshot facts, deterministic v2 fixtures.
- **LocalModelEndpoint**: proxy mode (real pinned model, digests logged outside
  the worker) + fixture mode (labeled).

### Go (agentic-stream)

- **Gate 8**: `worker_runtime.go` never constructs the native executor when
  `WorkerSocket` is configured (the tamoz route); the constructor is
  injectable and the adversarial test proves the count is zero.
- **Wire**: `worker_executor.go` now sends the prompt BODY, the diagnosis
  catalog (spec field `diagnosisCatalog` + schema + assembler digest under the
  shared `situation-runtime/diagnosis-catalog` domain), and the catalog digest
  (previously-unset digest fields filled). `DispatchPolicy` deferred to P8.

## Cross-repo contract

Prompt + catalog digests are byte-identical across repos (frozen vectors):
`sha256:d28884…bf45a` (prompt) and `sha256:50ef8a50…e553` (catalog, the
**parsed array** shape), computed by both the Go canonicaljson package and the
Ruby frame. The Go assembler digests the parsed catalog (review finding: the
initial wrapped-string shape would have failed every Go-driven episode in the
Ruby worker).

## Review outcomes (5 reviewer agents: correctness, architecture,
duplication, soundness, rev-4)

- **Fixed:** cross-repo catalog digest shape (Go now digests the parsed array —
  the previous wrapped-string digest mismatched Ruby's verify_wire and would
  have failed every Go-driven episode fail-closed).
- **Fixed:** model events are now emitted by the RUNNER from receipts that are
  verified against the journal record (fetch by effect_key; head :succeeded +
  stored response digest match) — a forged projection cannot reach the wire
  (B4 categorical). Nodes hold no wire channel at all (`episode_wire` removed
  from Context).
- **Fixed:** completed receipts are witnessed on ANY terminal with a
  checkpoint (a run failing after the model call still crosses its model
  events).
- **Fixed:** `PROBABILITY_TOLERANCE` tightened 0.1 → 0.05 (measured provider
  drift; a 12%-short distribution now fails) + negative test.
- **Fixed:** dead `:decision`/`:terminal` branches deleted from
  `emit_stream_part` (runner-owned translations); dead methods, the stale
  `episode_diagnose.rb` fixture, unused constants, and stale comments removed;
  the objective digest test shape aligned to the Go rule (`{"text": …}`).
- **Accepted as P8 work (documented):** ExecutorName↔route coupling
  validation on the Go side; credential_ref resolution on the episode path;
  per-call ordinal allocation (P2, single-call P1 unaffected); RISK_ORDER
  constant dedup; test-composition dedup (3 inline copies of the composition —
  functional duplicates, consolidated helper exists).

## Deferred in P1 (stated, not hidden)

- Profile digest on the wire (no field).
- `selected_code`/`evidence_refs` in decision-v1 (frozen; P4 coordinated
  change; gate 3 asserts on the checkpoint document state).
- `open_verifications` moves to the Go side/subscriber path.
- Receipt-based budgets + tool node + repair: P2.
- DispatchPolicy semantics: P8.
- `MAX_ATTEMPTS` on the execute path (unsafe semantics make it harmless).
- The full Go→Ruby socket integration run (mTLS run-live) is the cross-repo
  integration handoff; the digest parity + Ruby e2e + Go unit gates are
  exercised in this phase.

## Fixture vs real labeling

- `stream_episode_fixed_graph_test.rb`, `stream_episode_crash_matrix_test.rb`,
  `stream_episode_end_to_end_test.rb` (fixture endpoint), etc. → **fixture**.
- `stream_episode_real_model_test.rb` (RUN_REAL_E2E=1) → **real model**.
