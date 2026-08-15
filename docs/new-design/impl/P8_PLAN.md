# P8 — Implementation plan: mode matrix, shadow-first, calibration, drain/kill

Status: **implemented + fully reviewed, committing** — all five implementation
reviewers ran and every critical/major finding is fixed:

- Calibration binding: the gate keys on domain + the compiled-spec digest
  (executor_version); artifact_sha256 is the Ruby-bound document identity
  verified at REGISTRATION (operator-run; the generator emits it, the plan
  notes the registration seam). A spec change invalidates the artifact —
  watch-only until re-registered.
- Kill is real: the epoch control refuses every later decision at the
  dispatch boundary AND inside the post-execute persistence transaction AND
  at the governance boundary (EvaluateIntent); Kill supersedes in-flight
  episodes so the supersession watcher cancels their provider calls; the
  hostile-worker test proves an in-flight decision never lands. Kill is
  monotonic (a later drain cannot downgrade it).
- Drain is graceful: admission SKIPS (never fails the batch) while draining,
  so in-flight episodes finish under their recorded policy_epoch.
- Stale/killed refusals quarantine the episode durably (lifecycle abandoned +
  terminal reason) — the admitted queue drains, the runtime never crash-loops.
- Fixture rejection coalesces the scheduler item instead of blocking the queue.
- Deployment retirement is same-digest-safe (a boot-time re-save keeps the
  active row) — tested.
- Exit gate 6: p95/p99 dispatch→decision histograms + stale-rejection counter
  exported via /metrics; decision-after-deadline refused (terminal timed_out).
- The full 6-cell mode×policy matrix is tested (fixture×{active,shadow}
  rejected; fixture+shadow demo; native×{active,shadow}; tamoz×{active,shadow}).
- /control/drain + /control/kill require the AGENTIC_STREAM_CONTROL_TOKEN
  bearer (operator action, not an anonymous kill switch).
- Ruby no-hidden-fallback refusal + calibration artifact generator are tested.

Deferred (stated, not hidden): the operator artifact-registration CLI and the
full privacy/retention backend (deploy-time; the fail-closed seams exist).

Bar: PHASE_P8_ROLLOUT.md exit gates 1–6. Bars: B1, B6, B8, B10.
Claim: only if the gates pass — **"Production-ready for watch-only (then
calibrated automation) in domain X"** (level 6). Anything less is reported
plainly as not-ready. Privacy (design gate 4) is NOT claimed by this phase —
the fail-closed seams below make the gate passable at deployment, and the plan
says so.

## Architecture (delta from P7)

P8 makes the mode matrix REAL. The wire already carries `dispatch_policy`
(active|shadow) and `executor_name` (native|tamoz|fixture), the proto enum
exists, and the epoch fence (runtime_owner lease + assertRuntimeEpoch) is
hostile-worker-proof. The missing pieces are the consumers of the mode, the
kill/drain/calibration control surfaces, and the Ruby-side no-fallback
enforcement.

Key decisions pinned by review:

- **`fixture` is an executor NAME.** The pipeline recognizes it; production
  (no `--demo-mode`) rejects it at admission. Tests use the existing
  `episodes.NewFakeExecutor` as the fixture provider.
- **`policy_epoch` == the runtime owner epoch** (`evidence.NewRuntimeEpoch`),
  stamped on the episode row ONCE at admission and never rewritten. Decision
  fences validate against the EPISODE's recorded epoch — a drained epoch
  refuses only NEW admission; only a KILLED epoch refuses in-flight.
- **Calibration is a per-domain artifact table**, not the global interlock
  latch (`runtime_interlock` is a single ready/tripped row; it cannot scope
  per domain). Consequential = risk_class ≥ R2.
- **Shadow scoring** = the would-be `EvaluateIntent` result computed for a
  shadow decision and stored on a shadow decision table; it never appears in
  `intents` or `commands`.

## Exit gates mapped to the design's exact 1–6

1. Go: Agentic Stream independently blocks shadow, killed, and stale
   decisions — hostile-worker test (worker keeps producing after kill →
   refused at the decision boundary; shadow decision → never dispatched;
   version-mismatched → refused).
2. Go: kill cancels in-flight provider calls (supersede-cancel path) and a
   later decision under the killed epoch is refused.
3. Go+Ruby: no fallback path — code inspection + adversarial test (the 6-cell
   mode×policy matrix; Ruby refuses a fixture answer under a tamoz-mode
   request).
4. Privacy: fail-closed seams only (production admission fails unless a
   retention policy + egress/residency scope is configured; digest-only
   decision persistence mode). The full backend is deploy-time.
5. Go: automatic consequential intent (R2+) without a matching calibration
   artifact → refused (watch-only). Ruby: the calibration artifact generator.
6. Go: latency/freshness SLOs measured AND exported via /metrics (p95/p99
   dispatch→decision histograms + stale-decision rejection rate) with defined
   targets.

Plus (in-scope, not gates): graph versioning namespace test; channel
unification recommendation (doc + owner decision marker).

## Tasks

### T1 — Mode stamping + fixture rejection + mode×policy matrix (Go)
- Migration `024_episode_modes.sql`: `dispatch_policy` + `policy_epoch` on
  `episodes` (CHECK policy ∈ {active, shadow}).
- `spec.go` Executor gains `DispatchPolicy` (struct at spec.go:177–198);
  schema.json executor def (:597, additionalProperties:false → schema first);
  compiler + `CompiledSpec.Digest`.
- `episodes.Request` gains `DispatchPolicy` (assembler.go:40).
- `assembler.go` Assemble (:81) stamps Request + Persist (:302) stamps the row
  with the resolved epoch (`evidence.NewRuntimeEpoch`).
- `PipelineConfig` (pipeline.go:29) gains a `DemoMode` flag; `assemblePending`
  (:388) rejects `executor_name == "fixture"` unless DemoMode.
- **Test**: the full 6-cell matrix `executor {native,tamoz,fixture} × policy
  {active,shadow}` — one named test per cell asserting the expected admission
  and governance outcome (fixture×active rejected without demo; fixture×shadow
  rejected without demo; native×active dispatched; native×shadow scored;
  tamoz×active dispatched; tamoz×shadow scored).

### T2 — Dispatch-time enforcement + freshness + latency (Go)
- `Runner.RunOnce` (executor.go:84): before `StartAttemptOwned` (:127),
  recheck `situations.current_version` (SELECT inside the existing tx) —
  mismatch → refuse/stale.
- Deadline gate: a decision arriving after the attempt's deadline is refused
  (terminal `timed_out`) and counted into the stale-rejection counter.
- `TestValidityWindowNeverExtended`: an intent whose snapshot expired mid-run
  is stale even though the model "just finished"; assert no code path mutates
  `valid_until`.
- `telemetry.Runtime` (runtime.go — counters only) gains p95/p99 duration
  histograms + stale-rejection counter, EXPORTED through the existing
  `/metrics` handler. SLO targets defined (p95 ≤ freshness budget; rejection
  rate surfaced).

### T3 — Kill/drain control surface (Go)
- Migration `025_epoch_control.sql`: `epoch_control(owner_epoch, state IN
  {'draining','killed'}, updated_at)`.
- API: `NewRuntimeHandler` (internal/api/events.go:13) gains `POST
  /control/drain` and `/control/kill` (registering the current epoch);
  `PipelineConfig` gains the control reader.
- `assemblePending` refuses NEW admission while draining (in-flight keeps its
  recorded epoch).
- The decision fence (`assertRuntimeEpoch` / EvaluateIntent path) refuses
  every later decision when the episode's recorded `policy_epoch` is KILLED —
  independently of the worker.
- **Test**: `TestDrainRefusesNewEpisodesAllowsInFlight` (pending refused;
  admitted/running completes under its recorded mode); `TestKillRefusesEvery
  LaterDecision` with a hostile executor that keeps producing (mirror the
  local-type pattern of internal/episodes/cancellation_test.go).

### T4 — Shadow scoring + calibration gate + Ruby no-fallback (Go + Ruby)
- Migration `026_shadow_decisions.sql`: shadow decision rows
  (`shadow_score` = would-be policy result: would_approve / would_require_
  approval / would_deny; decision_json; score provenance). Shadow intents are
  computed by `EvaluateIntent` but never written to `intents`/`commands`.
  Test: shadow decision scored; absent from `intents`/`commands`.
- Migration `027_calibration_artifacts.sql`: per-domain artifact rows
  (domain, model revision, profile digest, prompt digest, diagnosis catalog
  digest, policy digest, artifact sha256).
- `EvaluateIntent` (policy.go:149): R2+ automatic intent requires a matching
  artifact (join on domain+digests) — missing/mismatch → refused (watch-only).
  R0/R1 automatic intents proceed under active regardless of the artifact.
  Test: `TestActiveWatchOnlyBlocksConsequentialAllowsR0R1`.
- Ruby: `script/generate_calibration_artifact` (mirrors the generate_* pattern)
  emitting the artifact JSON + SHA pin test; the worker reads
  `executor_name`/`dispatch_policy` from the EpisodeRequest (already echoed in
  the payload at situation_request.rb:176–177) and refuses to serve a
  fixture/deterministic answer when the request declares `tamoz`/`active` —
  provider failure propagates as an error event, never a canned decision.
  Test: a tamoz-mode request never yields a fixture answer.

### T5 — Graph versioning namespace (Go)
- Admission resolves the ACTIVE spec version (`spec_deployments` one-active)
  → fresh `deployment_id` per version. Test: two spec versions of the same
  name share no situation/checkpoint/episode rows; the new version's admission
  never touches the old version's rows.

### T6 — Channel unification (doc)
- A recommendation doc with the three merge recommendations (stream
  `ApprovalRelay` vs comms approvals; decision-v1 vs comms `DecisionRecord`;
  capability token vs subscriber bearer vs bot token) and an explicit owner
  decision record (ADR-style close-out), so the duplication is acknowledged,
  never silent.

## Deferred (stated, not hidden)

- Design gate 4's full privacy/encryption/retention backend (deploy-time; the
  fail-closed seams in T1/T2 + the digest-only mode make the gate passable).
- The actual production rollout (owner-run; the level-6 claim is made there).
