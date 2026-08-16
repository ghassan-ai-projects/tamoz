# Domain-knowledge leak audit — tamoz (2026-08-16)

Status: **audit report — no code changed.** Three sub-agents swept the repo after the
domain-data extraction (86e8dce): (a) production gems + entry points, (b) test/support/
scripts/Rakefile, (c) cross-cutting sweep + fixture-vs-code drift + digest integrity.

Verdict: the extraction is **clean for domain CONTENT** — zero prompts, catalogs,
intent rows, compensation maps, watch presets, snapshot templates, or fixture
responses in code. What remains is **benchmark-config leakage** (3 items, one is a
live bug) plus **duplicate-value drift risks** (all currently in agreement).

---

## 1. LEAKs — to fix (ranked)

### L1 (bug + leak) gems/tamoz-evals/lib/tamoz/evals/benchmark/baselines.rb:34
```ruby
def fixed_threshold(cells, codes, metric:, threshold: 2.0, alarm_code:)
```
The default `threshold: 2.0` is the **aquaculture** truth threshold
(`aquaculture.json benchmark_family.truth.threshold` = 2.0). `report.rb:122-132`
calls `fixed_threshold` without a threshold, so **2.0 is applied to BOTH families** —
the climate family (truth threshold **31.0**) is benchmarked with the aquaculture
threshold. The module's own comment claims "domain knowledge lives in the benchmark
data, not in this gem" — this value was missed.

- Belongs in: per-domain benchmark row (protocol `case_matrix.scenario_families` or
  the JSON `benchmark_family`), read by the caller and passed in.
- Fix: remove the default; `report.rb` passes the family's threshold from the data.

### L2 (leak) script/generate_benchmark_protocol:54-59
```ruby
{"id" => "do-crash", "domain" => "aquaculture", "primary" => "low_dissolved_oxygen",
 "metric" => "dissolved_oxygen", "alarm_code" => "low_dissolved_oxygen"},
{"id" => "climate-deviation", "domain" => "climate", "primary" => "overheated",
 "metric" => "zone_temperature", "alarm_code" => "overheated"}
```
The `case_matrix.scenario_families` rows are re-authored instead of derived from the
JSON `benchmark_family` keys (`family_id`, `metric`, `alarm_code`, `primary` ==
`alarm_code` == `truth.code`, `domain` == fixture name). The script already iterates
`DomainLoader.domains` for the digest section, so `DomainLoader.load(name).benchmark_family`
can drive the rows. The duplication then freezes into the committed
`documentation/benchmark/BENCHMARK_PROTOCOL.json`, and
`test/benchmark_protocol_test.rb:126-135` (`test_family_config_agrees_between_protocol_and_domain_data`)
guards a duplication that should not exist.

- Belongs in: `DomainLoader.load(name).benchmark_family` (JSON).
- Fix: build the family rows from the loader; the guard test then checks the protocol
  against the JSON as before.

### L3 (leak, minor) gems/tamoz-evals/lib/tamoz/evals/benchmark/comparison.rb:21
```ruby
def paired(candidate:, baseline:, cells:, metric:, minimum_effect:, seed: 7, ...)
```
Bootstrap seed default `7` (also `baselines.rb:22 random_label(..., seed: 1)`). The
protocol's `statistics` section records only the boolean policy
`paired_seeds_across_providers_and_baselines`; the numeric seeds exist only in gem
code. `report.rb:41` calls `paired` without `seed`, so 7 is the effective production
value. The holdout pin (cases 6, seed 7) reuses the same 7 in
`test/benchmark_holdout_test.rb:71`; scripts use 11/23 — seeds are not centralized.

- Belongs in: protocol `statistics` data (numeric seed fields) or per-domain rows.
- Fix: carry seeds in the protocol data and read them; no defaults.

---

## 2. Drift risks — duplicate values, currently in agreement (watch, don't churn)

These re-declare fixture values in code. None DIFFER today (no behavior drift), but
each is a future drift point if the JSON changes.

| # | Location | Value | Fixture source |
|---|---|---|---|
| D1 | `test/benchmark_controls_test.rb:208` | diagnosis codes `%w[low_dissolved_oxygen equipment_failure overstocking feeding_overload temperature_stress]` | `catalog[].code` |
| D2 | `test/benchmark_harness_test.rb:12` | `%w[low_dissolved_oxygen equipment_failure unknown]` subset | `catalog[].code` |
| D3 | `test/stream_decision_builder_test.rb:123,333,338`; `stream_invariants_test.rb:327` | watch preset `"situation.condition_score >= 0.8"`, `max_fires 3`, `watch_threshold 0.8` | `watch_preset` |
| D4 | `test/benchmark_harness_test.rb:14`; `benchmark_controls_test.rb:237` | `scenario_family: "do-crash"` | `benchmark_family.family_id` |
| D5 | `test/stream_episode_real_model_test.rb:76` | `pond_id: "pond-07"` | `snapshot.fact_defaults.pond_id` |
| D6 | `test/stream_episode_intent_authority_test.rb:151` | `"zone-03"` | `snapshot.fact_defaults.zone_id` |
| D7 | `test/p8_rollout_test.rb:82` | synthetic `greenhouse-prod` manifest reusing `overheated` + `install_watch_condition` R0 | novel synthetic domain (kept) |
| D8 | `gems/tamoz-core/lib/tamoz/core.rb:21` | `INTENT_WATCH_TYPE = "install_watch_condition"` | route/effector constant — **carve-out, keep** |
| D9 | `gems/tamoz-stream/contracts/canonicalization-vectors.json:216,219` | `install_watch_condition`/`create_maintenance_ticket` (refrigeration example) | frozen JCS vectors — **carve-out, keep** |
| D10 | `gems/tamoz-stream/contracts/notification-goldens-v1.json:46` | `tenant_id: "acme"` | synthetic vector — **carve-out, keep** |

Fix direction (only if the JSON changes): read from `DomainLoader`/`AquacultureDomain`
constants instead of literals. D8-D10 are deliberate and should stay.

---

## 3. Acceptable — reviewed, not leaks

- `test/support/{domain_loader,aquaculture_domain,climate_domain,benchmark_families}.rb`
  — thin loaders / data drivers.
- Digest pins: `agent_intent_catalog_test.rb:118` (`e4f86620…`), `benchmark_protocol_test.rb`
  (`bb2b4789…`, `87dec3cd…` — v1.1.0), holdout pin test — frozen assertion vectors (T4-classified).
- Wire machinery: `reasoning_document.rb:23 PROTOCOL = "tamoz.episode-diagnosis/v2"`,
  `episode_frame_builder.rb:111-120` output-shape rules, `decision_builder` document keys,
  `EpisodeNodes#judge` withdraw/downgrade logic, `INTENT_WATCH_TYPE` route constant,
  memory scopes as scalar wire params (`acme`, `aquaculture`, `pond` in tests).
- `docs/benchmark.json` — the unrelated latency artifact (`script/benchmark_release`),
  explicitly out of the extraction's scope. Keep.

---

## 4. Stale doc references (docs only, no code)

- `docs/new-design/PLAN_TAMOZ_LLM_REASONER.md:88`,
  `docs/new-design/PHASE_P1_ONE_REAL_CALL.md:59` — reference
  `test/fixtures/episode_diagnose.rb`, which was removed in P1 (see P1_REPORT.md:130).

---

## 5. Digest integrity — verified consistent (2026-08-16)

All six pinned digests + protocol SHA computed live from the current fixtures
(rbenv 3.3.11, JCS domain `situation-runtime/<type>/v1\n`) and match both the
committed protocol and the test pins. `script/generate_benchmark_protocol` output is
byte-identical to the committed `BENCHMARK_PROTOCOL.json`. One note: the climate
diagnosis digest `bb2b4789…` is asserted only in a test (by design — the protocol
pins only the aquaculture diagnosis catalog); it matches the fixture.

---

## 6. Suggested remediation order

1. **L1** — move the baseline threshold into the benchmark data and pass it from the
   caller (fixes the live climate-benchmark bug). Add/extend a test that fails
   before (climate family benchmarked at 2.0) and passes after.
2. **L2** — derive `scenario_families` from `DomainLoader.load(name).benchmark_family`;
   regenerate the protocol; the existing agreement guard keeps both copies honest.
3. **L3** — carry the bootstrap seeds in the protocol `statistics` data; remove defaults.
4. Fix the two stale doc references (§4).
5. Leave §2 drift duplicates as-is unless a JSON value changes; then read from the
   loader instead of literals.

---

## Fix status — 2026-08-16 (DOMAIN_LEAK_FIX.md)

**L1, L2, L3 fixed + stale docs corrected**, following the per-phase loop (2 plan
reviewers, 5 implementation reviewers). Protocol regenerated at **v1.1.0** (new SHA
`87dec3cd…`): `scenario_families` are now derived from the domain JSON and freeze
`threshold`/`operator` (2.0/lt, 31.0/gt); `statistics` carries `random_label_seed` 1
and `bootstrap_seed` 7. `fixed_threshold` requires `threshold:`/`operator:` (validated
lt/gt); `random_label`/`paired` require `seed:` — no domain defaults in gem code.
`holdout-pin/` regenerated (case content identical, SHA/version refreshed). New tests:
`test_fixed_threshold_alarms_by_truth_operator_and_threshold` +
`test_run_baseline_applies_each_family_truth_threshold_and_operator` (failing-before/
passing-after). §2 drift duplicates (D1–D7) deliberately untouched; D8–D10 carve-outs
stay.
