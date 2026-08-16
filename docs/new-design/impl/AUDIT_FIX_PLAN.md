# Audit fixes — implementation plan (docs/new-design/impl/AUDIT_FINDINGS.md)

Status: **implemented — reviewers running**. F1: real E2E run twice against
`gemma4:26b` (identical request digest `sha256:c84727f4…` across runs),
witness bundle committed at `docs/new-design/evidence/p1-real-run/latest/`,
P1_REPORT CLOSED, old digest marked superseded. F2: `INTENT_WATCH_TYPE` homed
in Tamoz::Core, decision_builder edge removed, enola baseline re-pinned on the
fixed tree, isolation test added. F3: forged-provider-marker guard at
`emit_model_events`, two tests (reject forged + don't discriminate real
fixtures). P7_REPORT created with the honest no-holdout-run statement. All
audit fixture gates green.

Bar: the audit's three findings closed with code-level proof, not self-assessment:
F1's real-run must be reproducible from the repo (committed witness bundle),
F2's no-edge property must be true again AND enforced (enola re-pin),
F3's design-stated guard must be literal code at the real admission seam.
Finished line: re-run the audit's own checks (fixture gates green, enola
no-edge, witness-bundle committed), update the audit doc with the closed
status, and add P7_REPORT stating plainly the benchmark holdout was never run.

Scope line: `ci_full`'s 11 raw-oracle failures are pre-existing at HEAD
(P1_REPORT gate-9 admission) — out of scope; this fix re-runs only the
audit's own fixture gates.

## Finding → fix mapping

### F1 — The one real call is asserted, not reproducible (highest priority)

Fix (verified executable: ollama reachable, `gemma4:26b` present, rbenv
3.3.11, transport sends the JCS body verbatim → digest equality holds by
construction):

- **Pin the model**: `DEFAULT_MODEL = "gemma4:26b"` (a specific tag, present
  locally — `:latest` is a moving tag, not pinned). Record the Ollama
  manifest digest of the model in the bundle.
- **Environment overrides**: `TAMOZ_REAL_MODEL` (default `gemma4:26b`) and
  `TAMOZ_OLLAMA_BASE` (default `http://127.0.0.1:11434`) on the test — the
  plan's hosted-provider capability is IMPLEMENTED, not claimed. A deepseek
  hosted run is deferred (documented in the report), not silently dropped.
- **Committed witness bundle**: the test `mkdir_p`s
  `docs/new-design/evidence/p1-real-run/<utc>/` and writes the endpoint log +
  receipt JSON + digest-summary JSON (request_digest, response_digest,
  selected_code, intents, provider, model, terminal status, model manifest
  digest). A `latest/` pointer is convenience only — the REPORT cites the
  immutable `<utc>/` bundle id.
- **Call-count assertion**: `assert_operator observed.length, :>=, 1` — a real
  model can emit a malformed document (repair → second journaled call) or a
  stray tool_request; the digest asserts compare `observed.last` vs
  `model_receipts.last`, which stay correct with 2 calls.
- **Reproducibility gate (scoped)**: re-running reproduces endpoint==receipt
  digest EQUALITY (request digest byte-identical — the frame is frozen; the
  response digest is witnessed-fresh, never byte-identical across runs).
- **Old digest fate**: expected the new request_digest to equal
  `sha256:85689b8e…` if the frame inputs are unchanged (they are frozen) —
  retroactively verifying the old line; if it differs, P1_REPORT explicitly
  marks the old digest superseded and re-dates the claim.
- **Close P1_REPORT.md**: status → CLOSED, gates 1-2 cite the committed
  bundle; claim ladder honest (level 2 = adapter path proven by the committed
  real run; no intelligence claim).

### F2 — tamoz-stream → tamoz-agent dependency edge (medium)

- Move `WATCH_TYPE` to `Tamoz::Core` (`gems/tamoz-core/lib/tamoz/core.rb`):
  `INTENT_WATCH_TYPE = "install_watch_condition"`.
- `tamoz-agent`'s `IntentCatalog::WATCH_TYPE` becomes an alias
  (`WATCH_TYPE = Tamoz::Core::INTENT_WATCH_TYPE`) — internal uses (:179-180)
  and the test reference (agent_intent_catalog_test.rb:16) keep working.
- `decision_builder.rb` (the ONLY edge: line 5 require + :124/:153/:171/:188/
  :288/:291) drops the agent require and uses `Tamoz::Core::INTENT_WATCH_TYPE`.
- **Isolation test** (in test/dependency_isolation_test.rb, mirroring
  test_evals_is_stdlib_only_and_loads_no_runtime_package): loading
  `tamoz/stream/decision_builder` must not pull tamoz-agent; plus a gemspec
  assertion that tamoz-stream.gemspec declares no tamoz-agent dependency
  (already true — a cheap permanent guard).
- **Enola**: `generate_snapshot` → `set_baseline` NOW (edge present, as the
  P1 state) → after the fix `diff_snapshot` must show the edge resolved →
  `set_baseline` AGAIN on the fixed tree so a future reappearance is graded
  against the clean state.

### F3 — B8's stated proof is not a code guard (low)

- **Seam (verified)**: `WitnessVerifier` has NO production caller — the guard
  must live at `emit_model_events` (`situation_request.rb:488-517`), the
  design's literal "stream artifact" admission, which already fetches the
  journal record, requires head `:succeeded`, cross-checks digests, and
  already reads `receipt.fetch("provider")` at :545. One extra check there:
  reject a receipt whose provider is a FORGED marker (`test`, `fixture`,
  `local-model-fixture`) or missing, with a typed StreamError
  (`wire_refused_model_event/forged_provider_marker` resp.
  `missing_provider`), AFTER the journal verification (provenance first,
  then provider identity — both strictly before any emit for that receipt).
- **Scope stated plainly**: real fixture receipts carry provider `ollama` +
  model `local-model` — the guard rejects forged markers only, it does NOT
  discriminate fixture-vs-real (that discrimination is structural, via test
  wiring). The guard's teeth: a forged artifact cannot claim admission even
  with matching digests — the design's stated proof, enforced.
- **Test**: a forged receipt with provider `"test"` + matching digests is
  rejected at emit (unit test on the seam, no real model needed).

### P7 observation → report

- Create `P7_REPORT.md`: harness shipped, 14 adversarial controls green as
  fixture tests, holdout NEVER executed against a real model, no intelligence
  claim licensed (claim ladder capped ~level 4). Point P7_PLAN's status at it.

## Phase bar

F1 = committed bundle + closed report + re-run reproduces endpoint==receipt
digest equality; F2 = no edge on the load path + enola diff shows the edge
resolved + post-fix baseline re-pinned + isolation/gemspec tests; F3 = the
literal guard at `emit_model_events` rejects a forged-marker receipt with
matching digests. Finished line: audit doc updated (F1/F2/F3 closed, P7
report added), all fixture gates green.

## Test mode labeling

All tests remain fixture-labeled except the one RUN_REAL_E2E evidence run,
whose bundle is committed as evidence (never as an intelligence claim).
