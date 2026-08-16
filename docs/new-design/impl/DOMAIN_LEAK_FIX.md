# Benchmark domain-leak fix — implementation plan

Status: **v1 (plan-review integrated)** — gap-searcher + completeness reviews
applied (multi-file test command blocker, kwargs-branch trap, named
failing-before tests, 4 paired call sites, execution order, version bump,
leak-scan.json stray, family-row order invariant, stale SHA prose). Source:
docs/new-design/impl/DOMAIN_LEAK_AUDIT.md (2026-08-16). Fixes L1–L3 + stale
doc refs. Drift duplicates D1–D7 are NOT touched (in agreement; D8–D10 are
carve-outs that stay).

## Bar (finished line)

1. **L1** — `fixed_threshold` has no domain defaults: `threshold:` and `operator:`
   are required, from the family's `truth` config (aquaculture 2.0/lt, climate
   31.0/gt). The climate family is no longer benchmarked at 2.0 and the alarm
   direction is data-driven (`operator` validated: anything but "gt" raises).
2. **L2** — `script/generate_benchmark_protocol` derives `case_matrix.scenario_families`
   from `DomainLoader.load(name).benchmark_family`; the hardcoded rows are gone.
   Rows freeze `threshold` + `operator`. **Order invariant:** aquaculture first,
   climate second (`benchmark_holdout` indexes `scenario_families[index % 2]`).
3. **L3** — no seed defaults in gem code: `Comparison#paired(seed:)` and
   `Baselines.random_label(seed:)` require the seed, supplied from protocol
   `statistics` (`bootstrap_seed` 7, `random_label_seed` 1). Scope note: the
   scripts' CLI defaults (benchmark_run --seed 11, benchmark_holdout --seed 23)
   and the pin-test seed 7 are invocation/test parameters, not gem-code leaks —
   unchanged. `bootstrap_seed` 7 and the holdout-pin case seed 7 are unrelated
   mechanisms (different PRNG uses); a future divergence is safe.
4. Protocol version **1.0.0 → 1.1.0** (freeze rule: any field change is a new
   benchmark version). Regenerated, `COMMITTED_SHA256` bumped deliberately,
   `holdout-pin/` regenerated at cases=6 seed=7 (case content identical — only
   `protocol_sha256` + version change).
5. Named failing-before/passing-after tests prove the L1 fix (below).
6. Stale doc references fixed (episode_diagnose ×2, stale SHA prose ×3).
7. All `test/benchmark_*` green (targeted, repo's ARGV.each form — multi-file
   `ruby a.rb b.rb` runs only the first file). Coverage of the evals gem is via
   `test/benchmark_*` (gems/tamoz-evals has no test dir); `test/benchmark_report_test.rb`
   is the latency artifact (docs/benchmark.json) and stays out of scope.
8. Audit file marked with fix status; its stale SHA line corrected.

## Change

### F1 (L1+L2 compose) — per-family threshold/operator in protocol + baselines
- Generator `scenario_families` = `DomainLoader.domains.map`:
  `{"id" => family.fetch("family_id"), "domain" => name,
    "primary" => truth.fetch("code"), "metric" => family.fetch("metric"),
    "alarm_code" => family.fetch("alarm_code"),
    "threshold" => truth.fetch("threshold"), "operator" => truth.fetch("operator")}`
  (`family = DomainLoader.load(name).benchmark_family`, `truth = family.fetch("truth")`).
  Existing fields byte-identical to today's rows; order preserved (aquaculture,
  climate). After this, `fixed_threshold` is the ONLY detector that can alarm in
  the climate gt direction — the lt-only detectors (z_score/first_difference/
  moving_median) keep their generic defaults (k/drop/window are statistics, not
  domain values).
- `baselines.rb#fixed_threshold` → `(cells, codes, metric:, threshold:, alarm_code:, operator:)`,
  all keyreq; `raise ArgumentError, "fixed_threshold operator must be lt or gt"` for
  anything else; alarm = `operator == "gt" ? value > threshold : value < threshold`.
- `report.rb#run_baseline`: pass `kwargs[:threshold]`/`kwargs[:operator]` from the
  family row when the strategy accepts them (same mechanism as metric/alarm).
  Nil-family cells now hard-raise for fixed_threshold — matches the pre-existing
  metric/alarm keyreq strictness, not a new failure class.

### F2 (L3) — seeds in protocol statistics, no defaults
- Generator `statistics` gains `"random_label_seed" => 1, "bootstrap_seed" => 7`.
- `baselines.rb#random_label`: `seed:` keyreq. `comparison.rb#paired`: `seed:` keyreq.
- `report.rb#build` passes `seed: @protocol.dig("statistics", "bootstrap_seed")`;
  `run_baseline` passes `kwargs[:seed] = @protocol.dig("statistics", "random_label_seed")`
  when accepted. Values equal the removed defaults → for the SEED plumbing,
  report outputs and `content_digest` are bit-identical pre/post (the L1
  threshold/operator fix deliberately changes climate-family baseline outputs —
  that is the point).

### F3 — protocol freeze + pins (exact order, load-bearing)
1. F1+F2+F4 code edits together (they break as one unit until the protocol regens).
2. `rbenv exec bundle exec ruby script/generate_benchmark_protocol > documentation/benchmark/BENCHMARK_PROTOCOL.json`
   (generator prints to stdout).
3. Compute the new SHA-256 of the file; bump `COMMITTED_SHA256` in
   `test/benchmark_protocol_test.rb`; extend freeze tests (threshold/operator
   exact values 2.0/lt + 31.0/gt, `random_label_seed` 1, `bootstrap_seed` 7,
   version "1.1.0", family-agreement test asserts threshold/operator).
4. Regenerate the pin AFTER the protocol regen:
   `rbenv exec bundle exec ruby script/benchmark_holdout --cases 6 --seed 7 --out documentation/benchmark/holdout-pin --force`,
   then **delete the stray `documentation/benchmark/holdout-pin/leak-scan.json`**
   (untracked; pin dir keeps only manifest + truth).
5. Update the harness helper's hardcoded `protocol_sha256` literal
   (`test/benchmark_harness_test.rb` `report` helper + `test_report_binds_the_protocol…`
   assertions of "1.0.0" and the old SHA) to the new SHA + "1.1.0".

### F4 — test call sites
- `test/benchmark_harness_test.rb#test_baselines_are_deterministic`: **split the
  kwargs branches** — `fixed_threshold` gets its own dict
  `{metric:, alarm_code:, threshold: 2.0, operator: "lt"}` (adding those keys to
  the shared dict would raise `unknown keywords` in z_score/first_difference/
  moving_median/deterministic_detector); `random_label` gets its own `{seed: 1}`
  branch (it currently falls into `kwargs = {}`).
- 4 `paired` call sites (lines 220, 228, 241, 243): add `seed: 7`.

### F5 — named failing-before/passing-after tests (L1 proof)
- `test_fixed_threshold_alarms_by_truth_operator_and_threshold` (unit): lt/2.0 →
  alarm below 2.0, majority above; gt/31.0 → alarm above 31.0, majority below.
- `test_run_baseline_applies_each_family_truth_threshold_and_operator` (report-level,
  FAILS BEFORE the fix): over the regenerated protocol, a climate-deviation cell at
  `zone_temperature` 33.0 must produce `primary_code "overheated"` from the
  `fixed_threshold` baseline (28.0 → majority); a do-crash cell at `dissolved_oxygen`
  1.0 → `low_dissolved_oxygen` (4.0 → majority). Pre-fix, 33.0 is evaluated at
  threshold 2.0/lt → majority, not `overheated`.

### F6 — stale doc references + SHA prose
- `docs/new-design/PLAN_TAMOZ_LLM_REASONER.md:88`, `PHASE_P1_ONE_REAL_CALL.md:59`:
  drop/replace the `test/fixtures/episode_diagnose.rb` refs (file removed in P1).
- `docs/new-design/impl/DOMAIN_DATA_EXTRACTION.md:8,61`: replace the `5e25b0b9…`
  prose with the new pinned SHA (they claim the current pin).
- `docs/new-design/impl/DOMAIN_LEAK_AUDIT.md`: correct §3's `5e25b0b9…` line and
  append "Fix status: L1–L3 fixed + stale docs, 2026-08-16 (DOMAIN_LEAK_FIX.md)".

## Ripple check (verified no-ops)
- `script/benchmark_run` / `benchmark_holdout` read family rows by `id`/`domain`
  only — extra fields inert. Holdout case content comes from `BenchmarkFamilies`
  config — cases byte-identical after the protocol change.
- Harness/controls report tests read the REAL protocol file — after regen they
  carry the new statistics/version; only the hardcoded SHA/version assertions
  (F3.5) need updating. Control 7's `d3e20b…` literal is pre-existing and
  self-consistent — left alone.
- Go side: no benchmark-protocol dependency (agentic-stream has its own batch
  comparator; parity digest e4f86620 is intent-catalog-bound, untouched).
- `sealed_build_digest` cannot shift (canonical fingerprint = ruby version +
  lockfile only). docs/benchmark.json (latency artifact) has no protocol ref.

## Phase bar per finding
- F1: generator emits identical existing fields + threshold/operator; the two new
  tests prove lt/gt + family wiring (failing-before → passing-after).
- F2: no `seed:` default in `paired`/`random_label`; report path reads statistics.
- F3: byte-identical regeneration; new SHA + version pins; holdout pin green; no
  leak-scan.json in the pin dir.
- F4: harness tests green with explicit params.
- Finished: `rbenv exec bundle exec ruby -Itest -e 'ARGV.each { |f| require File.expand_path(f) }' test/benchmark_protocol_test.rb test/benchmark_holdout_test.rb test/benchmark_harness_test.rb test/benchmark_controls_test.rb`; commit.
