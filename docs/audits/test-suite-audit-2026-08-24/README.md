# Test Suite Audit — 2026-08-24

**Goal on the table:** the everyday full test run finishes in **under 60 seconds**.
**This document is audit + plan only. No code was changed.**

Evidence files in this folder:

| File | Contents |
|---|---|
| `timings.json` | Full per-file measurements, buckets, failures, machine facts |
| `timings.tsv` | Raw `status seconds path` lines, one per test file |

---

## 1. Method

- All **234** files in `test/*_test.rb` measured individually, strictly sequentially
  (sequential because SERIAL_TESTS are only trustworthy alone), via
  `bundle exec ruby -Itest -Igems/*/lib <file>`; ruby 3.3.11, arm64-darwin, 10 cores,
  2026-08-24, no coverage instrumentation.
- Fixed startup tax measured separately: a bare `require` of `test/test_helper.rb`
  costs **≈0.78s** (0.75/0.76/0.79 over three runs). The helper eagerly requires all
  24 gems, so every one of the 234 files pays that before its first assertion.
- Overlap/duplicate analysis: every file's test-method inventory extracted, ~20 file
  bodies opened for disambiguation; strongest duplicate claims re-verified by direct
  grep during this audit.

**Honesty caveat:** the branch (`decomposition/session-capabilities-concurrency`) is
mid-flight. **23 of 234 files FAIL at audit time**, consistent with digest-pin drift
from the gem decomposition (e.g. `agent_skills_toolbox_test` byte-identity digests).
Durations remain valid evidence; for files that died early, duration is a *lower
bound* and is marked ⚠ below.

---

## 2. Headline numbers

| Metric | Value |
|---|---|
| Test files | 234 (~65k LOC) |
| Total serial runtime | **505s** |
| Mean / median / p90 per file | 2.16s / **0.80s** / 2.90s |
| Files ≥5s | 10 — they hold **~47%** of total runtime |
| Files ≥3s | 23 |
| Pure startup tax | 234 × 0.78s ≈ **182s = 36% of serial runtime** |

The suite is **not broadly slow**. Median file is 0.8s. Cost is concentrated in a
heavy tail of ~17 files plus a fixed per-file require tax that parallelism must
dilute.

## 3. The slowest tests (top 20)

`s` = measured this audit. ⚠ = died early; true cost higher (Rakefile weight shown
where recorded). Tier = where the file runs today.

| # | File | s | Tier | What it does that costs |
|---|---|---|---|---|
| 1 | graph_surface_audit_test | 53.5 | SERIAL | Regenerates the documented graph-surface table |
| 2 | agent_scorecard_test | 49.8 | **in `rake ci`** | Scorecard auditor hard gates |
| 3 | packaging_test | ≥27.7 ⚠ | SERIAL | Strict-validates all gems, packaged bins (15 spawns) |
| 4 | mcp_invocation_test | 22.4 | SLOW | Real-wire MCP invocation, corruption/circuit cases |
| 5 | stream_worker_server_test | ≥21.0 ⚠ | SERIAL | TCP/unix handshake server suite |
| 6 | autonomy_scorecard_test | 16.9 | excluded | Milestone matrix (correctly outside `rake test`) |
| 7 | memory_treatment_profile_test | 15.7 | **in `rake ci`** | Injection-treatment CI profile gates |
| 8 | mcp_supervisor_test | 12.6 | SLOW | Process-group supervisor, group kills |
| 9 | sqlite_raw_oracle_test | 10.3 ⚠ (healthy ≈23) | SLOW | Fresh-process classification oracle vs raw SQLite |
| 10 | m2_evidence_test | 9.2 | SLOW | Sandboxed evidence runner (6 results) |
| 11 | tamoz_telegram_transport_test | 4.8 | ci | Transport poll/deliver loops |
| 12 | m1_evidence_test | 4.8 | SLOW | Same runner, 4 results |
| 13 | agent_session_operations_test | 4.2 | ci | Backup/retention/concurrent owners |
| 14 | evals_verifier_test | 3.9 | ci | Golden digest verification (6 spawns) |
| 15 | agent_unattended_policy_test | 3.9 | ci | Unattended deny matrix |
| 16 | agent_mcp_capability_source_test | 3.9 | ci | Source pinning/journal guard |
| 17 | websearch_invocation_test | 3.9 ⚠ | ci | Operator grant/attribution/budgets |
| 18 | agent_worker_test | 3.7 | ci | Worker loop/runtime dirs/events |
| 19 | benchmark_holdout_test | 3.5 ⚠ | ci | Holdout manifest/truth schema |
| 20 | mcp_catalog_test | 3.4 | ci | Catalog compile/hardening |

Not in this table but notable: `agent_session_kill_matrix_test` (healthy ≈20.9 ⚠),
`sqlite_convergence_probe_test` (healthy ≈16.2 ⚠), `sqlite_scenario_driver_test`
(healthy ≈7.3 ⚠), `agent_latency_smoke_test`, `stream_episode_end_to_end_test`.

### The Rakefile weights are stale — this matters mechanically

`TEST_WEIGHTS` drives LPT bin-packing in `test_parallel`. Current drift:

| File | Rakefile weight | Measured |
|---|---|---|
| graph_surface_audit_test | **absent → 0.7** | **53.5** (76× wrong) |
| packaging_test | absent → 0.7 | ≥27.7 |
| stream_worker_server_test | absent → 0.7 | ≥21.0 |
| agent_scorecard_test | 3.7 | **49.8** (13× stale) |
| memory_treatment_profile_test | 3.2 | 15.7 |
| sqlite_raw_oracle_test | 23.4 | 10.3 ⚠ (machine faster than when recorded) |

A shard holding graph_surface_audit as if it were 0.7s leaves eight workers idle at
the end of every `ci_fast`/`test_parallel` run. Fixing this table is the cheapest
single win available.

## 4. Where the time goes

| Lane (today) | Files | Serial sum | Note |
|---|---|---|---|
| `rake ci` set | 216 | 314.6s | Ideal 35.0s @9 workers — but true floor is its heaviest member: **agent_scorecard 49.8s** |
| SLOW_TESTS | 7 | 60.5s measured (≈92s healthy) | Subprocess/oracle/crash work by design |
| SERIAL_TESTS | 10 | 113.0s | Gem builds, artifact regen, process-table probe |
| AUTONOMY (excluded) | 1 | 16.9s | Milestone gate, correctly out |

`rake ci` today sits **marginal against the goal**: perfect packing of its current
membership cannot beat ~50s wall (one file is 49.8s), and real runs add contention.

## 5. Duplicate & overlap clusters

Verified claims marked ✅ (grep-checked during this audit); others carry
method-level evidence from the full mapping pass.

| # | Cluster | Evidence | Action candidate |
|---|---|---|---|
| 1 | ✅ capability_host_test ↔ agent_capability_binding_test | Both load same fixture `p18_start_toolbox_surface.json`; both assert byte-identical surface + forged-registration refusal | Merge into one file |
| 2 | m1_evidence ↔ m2_evidence | ✅ identical method `test_runner_uses_only_fixed_source_controlled_selections`; same structure, differ only in result count (4 vs 6) | Parameterize or merge |
| 3 | ✅ mcp_invocation ↔ agent_mcp_adversarial | Same 3 scenarios at two layers (connect/mid-call wire corruption terminal, bounded flood); adversarial adds little beyond invocation-level, but owns the serial process-table probe | Keep probe, drop duplicated scenario bodies |
| 4 | agent_toolbox ↔ agent_toolbox_invariant17 | Scenario-level overlap confirmed (UTF-8 rejection set for read_file/apply_patch/search_text appears in both; names differ) | Move unique invariant17 cases into toolbox file, delete rest |
| 5 | comms_gateway ↔ comms_cli | Serve-loop core asserted through both entrypoints (inbound→queued turn+offset, unbound sender, unknown-command reply) | CLI keeps ops/doctor only |
| 6 | approval_reload ↔ approval_mode_switch ↔ agent_mode_switch | Parked-decision resolution + old-rev invisibility asserted in all three against the same switches table | One engine-level owner + one thin integration case |
| 7 | stream_episode_crash_matrix ↔ stream_episode_replay | Fence+1 receipt reuse and started-without-receipt→unknown covered twice | Keep replay (P2 gates), trim crash-matrix dupes |
| 8 | benchmark_controls ↔ stream episode gates ×4 | control_4/control_13/control_14 attacks replicated as gate tests | Controls file owns attack corpus; gates reference outcomes |
| 9 | agent_durable_routing ↔ agent_request_routing | Malformed-route fallback + unverified-direct-response asserted twice | Split ownership by layer |
| 10 | memory_store ↔ memory_repository_adapter ↔ memory_treatment_profile | Sensitive-record never-stored/matched/decrypted asserted three times; contamination detection twice | Store owns SQL truth; profile keeps CI gate only |
| 11 | agent_skills_adversarial ↔ agent_skills_toolbox | A16 epoch-swap pair literally duplicated | Toolbox keeps surface; adversarial keeps A-matrix |
| 12 | agent_governed_database_source ↔ agent_cli_mcp | Write-query refusal duplicated pre-dispatch | Keep source-level, drop CLI copy |
| 13 | canonical_json ↔ core_jcs_vectors ↔ duplicate_key_detector ↔ evals_verifier | Reject-corpus (dup keys, control chars, nesting depth) maintained in 3–4 places | JCS vectors own the corpus; others assert dispatch only |
| 14 | graph_execution ↔ graph_state_manager | Last-value conflict semantics twice | State manager owns |
| 15 | sqlite_schedule_store ↔ scheduler_values/due_occurrences | Misfire/overlap policy matrices at two layers | Adjacent-layer redundancy — decide the policy authority |
| 16 | child_environments ↔ mcp_supervisor | Child-env credential hygiene twice | Supervisor keeps process-level only |
| 17 | secret_sweep ↔ local suites | Umbrella sweep re-asserts refusals owned locally | Intentional belt-and-braces — keep, lowest priority |

Merging clusters 1–12 removes roughly 15–20 files ⇒ ~12–16s of CPU startup tax plus
their duplicated assertion bodies.

## 6. Low-value / misplaced tests

**Genuinely low-value / candidates for removal or relocation:**

- `agent_durable_compatibility_spike_test` — spike-named; asserts version pins and v1
  round-trip ground already owned by `agent_session_records_test`. Removal candidate.
- `agent_latency_smoke_test` — shells out to `script/agent_latency_smoke --offline`;
  routing-safety ground already covered by the routing suites. Belongs in a
  benchmark task, not the test suite.
- `agent_phase3_context_lifecycle_test` / `agent_phase4_capability_test` —
  phase-numbered grab-bags whose contents are largely superseded by focused suites;
  needs an assertion-level diff before trimming.
- `stream_episode_fixed_graph_test::test_gate4_same_graph_runs_without_grpc` —
  guards the absence of a removed gRPC path (exploratory-era assertion).

**Misplaced, not low-value — move to the right lane:**

- `agent_scorecard_test` (49.8s) and `memory_treatment_profile_test` (15.7s) —
  scorecard/data-profile gates sitting inside the everyday behavior lane; they set
  the floor for `rake ci` packing.
- Evidence/artifact gates (§7 of the mapping): `benchmark_protocol`,
  `benchmark_report`, `release_evaluation_manifest`, `release_rehearsal_evidence`,
  `requirements_manifest`, `graph_surface_audit`, `public_api`,
  documentation trio, `evals_verifier`, fixture-parity captures. These gate data and
  provenance — important, but they verify artifacts, not behavior, and belong to a
  release/pre-commit-full lane, not a sub-minute loop.
- `stream_episode_real_model_test` — the single real-provider call; correctly
  env-gated today (`RUN_REAL_E2E=1` + ollama reachability). Keep gated; never let it
  into default lanes.

**Explicitly NOT low value (do not touch):**
`legacy_session_resume_test` (real committed bytes guarding the upgrade path),
both adversarial suites (current security invariants), all digest-pinned domain
data contracts (AGENTS.md B9/P4 gate), crash/kill matrices (durability contract).

## 7. The <60s plan

**Definition of the goal (proposed):** `rake ci` — the complete everyday behavior
gate — finishes in **≤45s wall clock on this 10-core machine**, leaving 25% margin
under 60s. The complete gate `rake ci_full` stays a separate lane: its members do
real subprocess, gem-build and artifact-regeneration work; shrinking them to fit
60s would weaken exactly what they verify. If ci_full itself must be <60s, that is
a decision to stop verifying packaging/evidence pre-commit — flagged here as a
product decision, not an optimization.

### Budget math

| Step change | ci-set serial sum | Floor @9 workers | Est. wall |
|---|---|---|---|
| Today | 314.6s / 216 files | max(heaviest)=49.8s | ~55–70s (marginal) |
| − scorecard − treatment profile (move lanes) | 249.1s | heaviest → 4.8s | — |
| + corrected TEST_WEIGHTS | (same sum, honest packing) | Σ/9 ≈ 27.7s | ~30–40s ✅ |
| + merge clusters 1–12 (−15..20 files) | ~−20s more CPU | ~25s | ~28–36s ✅✅ |

### Steps, each independently verifiable

1. **Prereq:** land/regenerate the WIP decomposition state so the 23 red files go
   green. A timing goal is meaningless while the suite is red.
2. **Refresh `TEST_WEIGHTS`** (`rake test_profile`) and add the four missing heavy
   entries (graph_surface_audit, packaging, stream_worker_server, telegram).
   One-line-class change; fixes idle-worker tail in every parallel run.
   Re-measure after step 1 — some healthy costs changed.
3. **Relane:** move `agent_scorecard_test` and `memory_treatment_profile_test` from
   the ci set into the slow/evidence lane (SLOW_TESTS list), and decide lane
   ownership for the §6 misplaced evidence gates. This kills the 49.8s floor.
4. **Merge duplicate clusters** 1, 2 first (literal duplication), then 3–12
   (scenario-level). Each merge: run both files before, one after, diff counts.
5. **Optional deeper cut:** make `test_helper.rb` load lazily (or split per-gem
   helpers) so unit files don't pay for all 24 gems — up to −0.5s × N files CPU
   (≈−12s wall at 9 workers). Bigger refactor; do it after merges prove the shape.
6. **Enforce the goal:** add a budget guard (fail `rake ci` if wall > 60s) and put
   `rake test_profile` on the quality-program cadence so weights can't silently rot
   again.

### What not to do

- Do not run `agent_mcp_adversarial_test` concurrently with other MCP tests — it
  probes the global process table; false failures guaranteed (Rakefile documents this).
- Do not delete digest/data-contract tests to save time — reschedule them.
- Do not trim crash matrices — they are the durability contract; the win is
  scheduling, not shrinkage.

## 8. Adversarial review of this plan

| Weakness | Severity | Mitigation |
|---|---|---|
| Relaning scorecard/evidence weakens the pre-commit gate if Lane B has no enforced home | High | Give Lane B an enforced trigger (nightly CI job + required before release); otherwise steps 3 quietly reduces safety instead of redistributing cost |
| Merged files reduce failure locality (a red file names more ground) | Low | Minitest reports method names; acceptable |
| Wall-clock estimates from a dev laptop with contention; 23 files were failing during measurement | Medium | Re-profile after step 1; keep 30% margin; treat 45s as the internal target, 60s as the gate |
| Weights will rot again (they did once) | Medium | Step 6 makes profiling part of the quality cadence, not heroics |
| Shared mutable fixtures under `test/support/` may cap safe parallelism growth | Medium | Mapping flags 8 shared harnesses; audit them before raising worker count beyond nproc−1 |
| Startup-tax savings assume merges keep file count down; new gems keep adding files | Low | Budget guard fails loudly when the floor creeps back |

## 9. Summary verdict

The suite is healthy in shape (no duplicate classes, only 4 name-level method
collisions, median file 0.8s) and slow for identifiable reasons: one 50s scorecard
inside the everyday lane, a stale weight table mis-packing every parallel run, a
17-file subprocess/evidence tail that belongs to a different lane, and a 36%
startup tax paid 234 times. The 60-second goal is reachable for `rake ci` with
relaning + repacking alone (~30–40s projected); merging duplicates and lazy helper
loads buy the margin. Nothing in this audit requires deleting a meaningful
verification.
