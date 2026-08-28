# Self-review — the plan against its bar

This is the loop the README asks for: the 10-point bar applied to [PLAN.md](PLAN.md),
the corrections that brought it to green, and the residual risk an implementing
agent inherits.

## The loop (what changed between drafts)

**Draft 1 → rejected on bar #1 (scoped) and #3 (extends, not reinvents).** The
research reads as a four-repo build (firmware, Go effector, gateway, emulator,
simulator, tamoz). A plan that carried all of that would have been a re-narration
of the research, not a *tamoz* plan, and would have invented a serial/effector
surface tamoz explicitly must not own. **Fix:** cut to the tamoz L2 slice; move
firmware / serial effector / gateway / emulator / fault-injection to an explicit
out-of-scope table; commit to the research's own invariant *"Do not give Tamoz the
serial port."*

**Draft 1 → rejected on bar #3.** The first outline proposed new "situation
quality" and "capability registry" subsystems. The codebase already carries
Situation facts opaquely through `ReceivedSnapshot`, catalog-authored risk through
`DecisionBuilder`, and a baseline/paired-comparison harness in `tamoz-evals-runner`.
**Fix:** every package now names the seam it extends; quality/capability become
**facts in the domain JSON**, not new machinery (also satisfies the owner's
*simple over complex* and *domain-knowledge-is-data* directives).

**Draft 2 → tightened on bar #2.** Verified each named surface by path before
citing: `DecisionBuilder`, `DomainLoader`, `Baselines`, `Comparison`, `Metrics`
(confirmed `action_utility`/`risk_coverage`/etc. exist), `Report`/`scoreboard.rb`,
`cold-chain.json`, `agent_intent_catalog_test.rb`, the parity digest `e4f86620…`.
Everything else is marked `TO BUILD` with a target path.

## Bar scorecard (final)

| # | Bar | Verdict | Evidence in the plan |
|---|---|---|---|
| 1 | Tamoz-scoped; cross-repo named & excluded | ✅ | README scope table; §Architecture marks the Go side OUT OF SCOPE |
| 2 | No invented surfaces | ✅ | Every seam cited by path or marked `TO BUILD`; verified against the tree |
| 3 | Extends, doesn't reinvent | ✅ | §0 mapping table: each ask → existing seam; gaps isolated to 6 real items |
| 4 | Owner directives honored | ✅ | data-not-Ruby (`B9`), no-compat, simple-over-complex, approval-is-data, real-model/fakes-in-tests, parity digest all cited |
| 5 | Dependency-ordered & gated | ✅ | §3 table: T0→T5, one gate each with a machine-checkable pass condition |
| 6 | Testable acceptance | ✅ | §4 test map; per-gate counters; adversarial suite WP-T4 |
| 7 | Sensor quality + capability first-class | ✅ | WP-T1 — the confirmed #1 gap (zero prior hits) + #4 |
| 8 | Safety/authority boundary explicit | ✅ | §1; risk R0–R2 mapped; unknown-outcome-stops-work; approval on the Go side |
| 9 | Evidence binding | ✅ | WP-T5 one immutable manifest binding digests + model/provider/prompt |
| 10 | Startable | ✅* | Decision Log resolves the 4 open choices; *see residual risk |

**Verdict: meets the bar.**

## Residual risk the agent inherits (not plan defects — build-time judgment)

1. **Owner ratification at G-T0.** Bar #10 is starred: an agent can *draft* WP-T0
   with the proposed vocabulary, but the mode/intent names and the quality enum are
   genuine owner choices (Decision Log #1, #4). Draft, then ratify at the gate —
   do not treat the proposed vocabulary as settled.
2. **Real-model variance in WP-T3.** The headline shadow-tournament claim depends
   on a real DeepSeek run; the paired interval can wobble. The gate is *"never
   worse on simple cells + ≥1 conflict win clearing the minimum effect,"* not a
   fixed accuracy — keep it honest and re-run rather than tuning the scorer to the
   result.
3. **`request_evidence` vs reuse-watch.** WP-T2 proposes an explicit R0
   `request_evidence` intent. If, once built, it behaves identically to the
   existing `install_watch_condition` fallback, collapse the two (simple over
   complex) and let the scorer read the watch as the evidence-request signal.
4. **Parity blast radius.** Keep `thermal-lab` tamoz-local (Decision Log #2
   default) until the loop is proven. Promoting it into the benchmark protocol
   drags in the Go mirror and a protocol-SHA bump in the same reviewed change —
   larger blast radius than the loop needs early.

## Enola / structural note

This deliverable is docs-only — no code changed, so no snapshot baseline is
pinned here. WP-T1 is the only package with a plausible structural footprint
(fact-carrying), and it is deliberately kept as data through the existing
`ReceivedSnapshot` seam, so no new coupling is expected. The implementing agent
should `set_baseline` before WP-T2/T3 code and `diff_snapshot` after, per the
project's enola rule.

---

## Implementation review (delivered code vs the plan)

The plan is now built (branch `docs/real-world-sensor-tamoz`, six commits, one per
WP). This section reviews the **code** against the plan and the clean-code bar,
and records where reality corrected the plan.

### Held to the bar

- **Extends, doesn't reinvent (bar #3).** The only production Ruby is two metrics
  in `Metrics`; quality/capability/trials are all domain **data**; the decision,
  tournament, adversarial and manifest work reuses `DecisionBuilder`, the fixed
  episode graph, `Baselines`/`Comparison`, and the digest rules. Enola confirms
  **0 structural regressions** (only fan-in on `Core` nudged).
- **Data, not Ruby (B9) / risk is the catalog's (B10).** Verified by the decision
  and adversarial suites: risk always equals the catalog's, and forged authority
  in facts is ignored.
- **Honesty (bar #7).** No fixture result is presented as intelligence. The
  tournament labels the supervisor player a fixture; the manifest verdict for a
  fixture run is `inconclusive_fixture_run`; the headline paired-win is the
  owner's real-DeepSeek step.
- **Green means green.** 34 runs / 100 assertions across the thermal slice, rubocop
  0 offenses (no `.rubocop_todo.yml` growth), `rake syntax` clean.

### Where reality corrected the plan (honest deltas)

1. **Off-allowlist is fail-closed, not demote-to-watch.** The plan (WP-T2) assumed
   an off-allowlist proposal demotes to watch. The frame gate
   `validate_recommended_intent_types!` actually **fails the episode closed** —
   strictly safer. PLAN.md and the test were corrected to the real behaviour.
2. **Sensor-quality is not schema-gated.** The plan floated an optional quality
   validator; it was deliberately **omitted** (simple over complex) and the
   adversarial suite depends on a forged quality value flowing through opaquely.
3. **Parity kept strictly local.** `thermal-lab` is proven absent from the frozen
   `BENCHMARK_PROTOCOL.json`; the two `benchmark_protocol`/`benchmark_holdout`
   pin-drift failures and the six `benchmark_comms_b0` failures are **pre-existing**
   in this environment (reproduced with all work stashed), not introduced here.

### Residual (unchanged from the plan's residual-risk list)

The real-model variance (residual #2) and the `request_evidence`-vs-watch
collapse question (residual #3) remain owner/real-run calls. `request_evidence`
is currently a genuinely distinct R0 outcome in the decision suite; if a real run
shows it behaving identically to the watch fallback, collapse the two.
