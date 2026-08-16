# Domain-knowledge extraction + docs relocation — implementation plan

Status: **implemented + fully reviewed, committing**. All five implementation
reviewers ran; every finding fixed. The critical (pilot harness crash — the
family driver returned a loader instance where benchmark_run resolves
`::PROMPT` constants) is fixed by returning the thin-loader MODULE. The
reviewers verified by execution: all six pinned digests byte-identical, the
protocol regenerates identically (SHA `5e25b0b9…`), the holdout output pins
to a committed artifact (`documentation/benchmark/holdout-pin/`), the Go
cross-repo parity test passes, and the pilot harness runs end-to-end
(verdict: inconclusive, correct for a fixture run). The plan's
"completely/external" wording is corrected to the honest "knowledge is data,
not code; the JSON is committed repo data" and the Go-side scope (production
Go still embeds the domain) is stated as a separate owner-decided follow-up.

## The problem

- `test/support/aquaculture_domain.rb` and `test/support/climate_domain.rb`
  embed DOMAIN KNOWLEDGE in Ruby code: diagnosis catalogs, operator prompts,
  intents + risks, compensation maps, watch presets, snapshot fact templates,
  and fixture-response content. The design's goal (B9: "hard-coded domain
  tables deleted", P4 gate-4: "a NOVEL domain authored as DATA ... ZERO
  production Ruby") is met for production gems but NOT for the test-support
  layer — the domain content is still code. The owner's directive: the
  domain KNOWLEDGE becomes DATA, not code — the definitions move to external
  data files loaded at runtime. Honest scope: the JSON is committed repo data
  under `test/fixtures/domains/` (Ruby is knowledge-free; the data still
  lives in the repo, not outside it).
- `docs/benchmark/` (the frozen protocol) sits under the owner's `docs/`
  working directory. Code-loaded benchmark files move to the `documentation/`
  folder; the design docs in `docs/` (working directory) stay.

## Bar (finished line)

1. **Zero domain knowledge in Ruby code.** The catalogs, prompts, intents,
   watch-property rules, compensation maps, watch presets, snapshot
   templates, fixture content, and benchmark-family config live in JSON under
   `test/fixtures/domains/`. The domain modules become thin loaders
   (machinery only: schema construction, probability normalization, digest
   computation). All 27 referencing files keep working through the loader
   API (the 6 files listed in T3 additionally get path updates).
   Scope note: this is the RUBY side. The Go side (agentic-stream) still
   embeds the aquaculture domain in production (event schemas, simulator)
   and in its conformance tests — cross-repo digest parity is unaffected
   (verified), but "removed from the codebase" is a Ruby-side claim;
   porting the Go copies to shared data is a separate, owner-decided
   follow-up.
2. **Wire values byte-identical.** Verified by execution: JSON round-trips
   of both catalogs, both intent catalogs, and both prompts produce identical
   digests (JCS canonicalization sorts hash keys; arrays are preserved in
   order). The six baseline digests (aqua intent `e4f86620…`, clim intent
   `f27b63a6…`, aqua diag `7ab740e0…`, clim diag `bb2b4789…`, aqua prompt
   `9c89f6e5…`, clim prompt `4e1440a2…`) and the protocol SHA pin
   (`5e25b0b9…`) survive. A verification step diffs the six digests before
   commit.
3. **Benchmark families are data too.** The family config moves into the
   domain JSON; a small driver reconstructs the `FAMILIES` shape (facts
   generator with the single-rand structure, threshold truth/gold) the
   scripts consume — identical holdout/run output (seed-determinism test
   enforces it).
4. **`docs/benchmark/` → `documentation/benchmark/`.** The protocol path and
   generated output paths move; every reference (6 files, 8 sites — incl.
   the split `ROOT.join("docs","benchmark",…)` form) updates. Out of scope:
   `docs/benchmark.json` + `script/benchmark_release` + `test/benchmark_report_test.rb`
   (a different artifact). The two stale path lines in `P7_PLAN.md` /
   `P7_REPORT.md` update.
5. **`test/support/local_model_endpoint.rb` analyzed** — already
   domain-agnostic; the only fix is `MODEL_MARKER = "local-model"` (not
   coupled to the same literal in benchmark_run / crash_matrix_test).
6. All affected test suites green (fixture gates).

## Change

### T1 — Domain data files + loader
- `test/fixtures/domains/aquaculture.json`, `climate.json`: carry ALL domain
  content — `catalog` (array order preserved), `objective`, `prompt`,
  `intent_types` (type→risk, insertion order preserved — order is
  digest-significant), `watch_properties` (per-domain property type rules),
  `compensation_map`, `watch_preset`, `snapshot` (situation metadata + fact
  template + default overrides), `document_template` (evidence_refs +
  default intent + intent param semantics), `fixtures` (precomputed JCS
  response strings), and `benchmark_family` (`domain_ref`, `metric`,
  `alarm_code`, `series`, `id_prefix`, `base_facts`, `metric_range
  {min,width,round}`, `series_offsets`, `truth {operator,threshold,code,
  fallback}`, `gold {operator,threshold,risk_class}`).
- `test/support/domain_loader.rb`: `DomainLoader.load("aquaculture")` —
  rebuilds INTENT_CATALOG entries (intent_entry machinery: base props,
  writable, compensation note/priority, watch properties FROM JSON,
  description interpolation, parameter_schema_digest, presets, policy, rate
  limit), fixture documents, snapshot. NO sorting anywhere. Shallow-freezes
  loaded containers. Fixtures resolve from the loader's own file path
  (`File.expand_path("../fixtures/domains", __dir__)`).
- `AquacultureDomain`/`ClimateDomain` become loaders exposing exactly:
  `CATALOG, OBJECTIVE, PROMPT, INTENT_CATALOG, INTENT_TYPES,
  FIXTURE_RESPONSES` constants + `intent_catalog_digest, document(selected:,
  hypothesis:, intent: nil), snapshot, profile_document(endpoint:, root:,
  model:)` methods. `profile_document` stays machinery (not JSON).
  `COMPENSATION_MAP`/`WATCH_PRESET`/`intent_entry` have zero external uses —
  loader-internal.

### T2 — Benchmark families as data
- The family config moves from `benchmark_families.rb` (lambdas) into the
  domain JSON `benchmark_family` sections; `BenchmarkFamilies::FAMILIES`
  becomes a small data-driven driver (mapping family id → loaded domain
  module, reconstructing the facts/truth/gold lambdas exactly: one
  `random.rand` per facts call, series offsets as `v + offset` unrounded,
  threshold comparisons with the per-family operator).

### T3 — docs relocation
- `git mv docs/benchmark documentation/benchmark`; update the 6 files /
  8 sites: `script/benchmark_run` (PROTOCOL_PATH + results default),
  `script/benchmark_holdout` (PROTOCOL_PATH + holdout default),
  `test/benchmark_protocol_test.rb`, `test/benchmark_harness_test.rb`,
  `test/benchmark_controls_test.rb`, `test/benchmark_holdout_test.rb` (the
  split `ROOT.join("docs","benchmark",…)` form included). Update the two
  stale path lines in `P7_PLAN.md` / `P7_REPORT.md`. The protocol SHA pin is
  unchanged (git mv preserves bytes).

### T4 — local_model_endpoint analysis
- `LocalModelEndpoint::MODEL_MARKER = "local-model"` used in
  `fixture_envelope`; no other change (domain-agnostic confirmed; the same
  literal in benchmark_run / crash_matrix_test stays independent).

## Phase bar per finding

T1 = grep shows zero domain literals in gems/ + test/support (only the JSON
files carry them); the six baseline digests diff clean; all 27 referencing
files pass. T2 = benchmark_families.rb is a data driver; holdout/run produce
identical output (seed-determinism test green). T3 = path-aware grep finds no
`docs/benchmark` reference (incl. the split form); protocol pin test passes
unchanged. T4 = the marker constant is used; endpoint tests pass. Finished
line: audit-style grep + fixture gates green; commit.

## Test mode labeling

All tests remain fixture-labeled; the real-model E2E is unchanged and still
env-gated.
