# Implementation bar & phase loop

The plan ([PLAN.md](PLAN.md)) defines six gated packages. This file is the
**working bar** the implementation is held to and the **loop log** — one row per
phase, each looped until its gate is green, committed at green.

## The clean-code bar every phase must clear (in addition to its gate)

1. **Extends the named seam** — no new machinery where data or a test suffices
   (`AGENTS.md`: understand before you build).
2. **Zero domain knowledge in Ruby** (`B9`) — catalogs, prompts, facts, thresholds
   live in `test/fixtures/domains/*.json`.
3. **Risk is the catalog's, never the model's** (`B10`).
4. **Terse, honest naming** — no comments that restate code; names carry intent.
5. **Green means green** — `rake` target for the touched slice passes; no skipped
   assertion presented as a pass.
6. **No claim exceeds its gate** — the "claim licensed" line is the ceiling.
7. **Real-model runs are real; tests never fake intelligence** — fixture provider
   in CI is labeled and never presented as an intelligence result
   (`memory/real-llm-not-fake.md`).

## Phase loop log

| WP | Gate | Loops | State |
|---|---|---|---|
| T0 domain fixture | G-T0 loader compiles; family builds | 2 | **green** |
| T1 quality + capability facts | G-T1 degraded quality diverges | 1 | **green** (data); behaviour → T2/T3 |
| T2 decision discipline | G-T2 mode/evidence/abstain, risk-governed | — | pending |
| T3 shadow tournament | G-T3 mechanics green; paired-win harness | — | pending |
| T4 adversarial suite | G-T4 zero escalations/injections | — | pending |
| T5 evidence manifest | G-T5 manifest + CI + parity | — | pending |

Each row is filled in as its phase closes: how many loop iterations the gate took,
what the last red was, and the commit that carried it green.

## Loop notes

- **T0** — Loop 1 red: `benchmark_families_test` ran clean but the loader gate
  could not be run under system Ruby 2.6; corrected to `bundle exec` + rbenv 3.3 +
  gem `-I` flags. Loop 2 green: loader compiles `thermal-lab`, its 8-code document
  normalizes to 1.0, `IntentCatalog.from_list` accepts the 6-type catalog with
  catalog-authored risks (R2 cooling, R0 evidence), and the family sweep passes.
  Note: `benchmark_protocol_test#test_protocol_regenerates_byte_identically` fails
  **pre-existing** in this environment (local `Gemfile.lock` digest ≠ the sealed
  fingerprint the committed protocol pinned); identical failure with the fixture
  removed. Not caused here, and `thermal-lab` is deliberately kept out of the
  frozen protocol's case matrix (parity local path, Decision Log #2).
- **T1** — Loop 1 green: sensor-quality enum (9 states) and a declarative
  actuator-capability registry (`fan_01_capability`, `led_01_capability`) added as
  first-class snapshot facts + `kwarg_map` overrides, and bound in the prompt
  (quality-is-evidence, capability-gating). `test/thermal_lab_facts_test.rb` pins
  the data contract (7 runs, 34 assertions). The behavioural divergence
  (degraded quality → evidence-request, not cooling, where the baseline alarms)
  is deferred to T2/T3, where the episode path exists — an honest bar, since the
  divergence is a real-model choice, not a fixture.
