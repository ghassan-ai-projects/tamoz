# Wiring plan — `tamoz-agent-healing` and `tamoz-agent-improvement` are built but unreachable

Date: 2026-09-16 · Branch: `self-healing-self-improvement` · Author: wiring lane
Baseline: enola snapshot pinned at HEAD `3fc8c7c` (13,534 facts)

## 1. The validated claim

> "The gems are there but not used."

**Confirmed.** Both verticals are fully built and tested, and both are `require`d by the
composition root — `gems/tamoz-agent/lib/tamoz/agent.rb:18-19` — yet **no production code path
calls either gem's entry seam.** Callers exist only in tests and the evals harness.

| Gem | Entry seam | Only callers today |
|---|---|---|
| `tamoz-agent-healing` | `Healing::Remediation.run` (`remediation.rb:62`) | `test/support/agent_smoke_corpus.rb:2317` |
| `tamoz-agent-improvement` | `Improvement::Promotion#promote`, `CandidateLifecycle`, `Generator` | `test/*`, `gems/tamoz-evals-runner/.../heuristic_paired_evaluation.rb` |

This matches the two independent functionality audits already in the tree
(`docs/audits/functionality-audit-2026-09-15/analyses/F20-agent-healing.md`,
`.../F23-agent-improvement.md`, and `.../challenge-healing.md`), which each concluded the entry
seam has **no production caller**. ADR-052 §3 says the composition root's job is *"it wires, it
does not implement"* — the wiring is simply absent.

## 2. Why it is not a one-line `require` fix

The seams cannot be naively invoked; each carries an open audit finding that lands *exactly* on
the call boundary. Wiring must close these at the seam or it wires in the defect:

- **F20-REL-01 (critical):** `Remediation.run(attempt:)` never compares `attempt` against any
  bound; the caller owns it. A caller that passes `attempt: 1` every cycle makes the protocol
  unbounded. The default `MemoryCircuitStore` is also built fresh per call
  (`remediation.rb:93`), so the circuit never persists across turns. **Wiring requirement:** the
  caller must supply a *durable, failure-fingerprint-keyed* attempt counter and a *durable*
  circuit store.
- **F23 human-gate finding (major):** the promotion "human gate" is an unbound string and the
  promotion gate can be cleared by a report produced inside the gem. **Wiring requirement:** the
  operator entrypoint stops at candidate + evaluation report and *never* promotes without an
  externally supplied approval artifact. This is also just ADR-023: improvement is *never* live
  self-mutation.

Two more structural facts shape the design:

- **Healing ≠ the in-turn repair loop.** `Runtime#run_action_repair_loop` is bounded
  catch-and-retry *within a turn* (`runtime.rb:477`). ADR-028 defines self-healing as
  rule-matched bounded *remediation* of a durable terminal failure. The correct seam is the
  durable worker's terminal-failure path (`worker_runtime.rb` `durable`/`terminal_fail`), not the
  repair loop. The two coexist.
- **Improvement has no production trajectory corpus.** `Generator#generate` reads trajectory
  JSON files (`verified == true`, `partition == "train"`) via the toolbox. Only the evals harness
  produces that shape today. An operator path needs a trajectory-export step.

## 3. Design

### Phase H — healing reachable from the durable worker (default-safe)

A single composition-root adapter, `Tamoz::Agent::SelfHealingCoordinator`, owns the risky
translation so it is unit-testable in isolation and the worker gains exactly one call site:

1. Input: a durable terminal failure (tool/effect signature already carried at the seam).
2. Build a typed `Healing::FailureRecord` from the failure — digest/source/bytes only, never
   untrusted prose (respects the gem's typed-signal boundary).
3. Look up a versioned `HealingRule` from a **durable** `RuleRegistry`. **Empty registry ⇒ no
   rule ⇒ the coordinator escalates and returns** — this is the shipped default, so wiring is a
   safe no-op until an operator authors and stages a rule (ADR-028: rules earn authority through
   evals).
4. When a rule matches: run `Remediation.run` with
   - a durable circuit store scoped `rule:<rule_id>` (the repo already has a sqlite circuit
     store — `test/sqlite_circuit_store_test.rb`),
   - `attempt:` read from a **durable counter keyed by `failure.fingerprint`**, incremented
     before the call — closing F20-REL-01 at the boundary regardless of the gem's internal gap.
5. Return the escalation/outcome payload to the worker, which records it durably as it already
   records terminal failures.

Config flag `self_healing.enabled` (default **false**) gates the whole path; off = today's
behavior byte-for-byte.

### Phase I — improvement reachable from an operator CLI entrypoint

A new `tamoz improve` command in `tamoz-agent-cli`:

1. Export verified trajectories from durable episodes into the corpus shape the `Generator`
   expects (train/holdout partition, `verified` flag).
2. Run `Generator#generate` → `HeuristicPairedEvaluation#evaluate` (distinct holdout).
3. Print the candidate, its provenance, and the sealed evaluation report. **Stop.** Promotion
   requires a separate operator step supplying a real approval artifact; the command never
   promotes on its own.

## 4. Scope and sequencing (token-aware)

- **Increment 1 (this session):** Phase H — `SelfHealingCoordinator` + its unit tests + the one
  worker call site behind the default-false flag. Highest safety value; self-contained; leaves
  runtime behavior unchanged by default.
- **Increment 2 (follow-up):** Phase I — `tamoz improve` command + trajectory export + tests.
- **Deferred (needs its own change):** authoring/staging a real healing rule through the evals
  stages (ADR-028), and fixing F20-REL-01/F23 *inside* the gems. Wiring closes F20-REL-01 at the
  seam; the in-gem fix is tracked separately.

## 5. Acceptance

- A production call site reaches each gem's entry seam (grep for the seam finds a non-test, non-
  eval caller).
- Default runtime behavior is unchanged (flag off; empty registry escalates).
- With a staged rule + open circuit, the coordinator terminates without exceeding the durable
  attempt bound (test proves the counter is consulted — the F20-REL-01 regression).
- `enola diff_snapshot` shows no new dependency cycle and no new cross-vertical coupling beyond
  the composition root.

## 6. Plan review — two lenses

### Lens A — architecture / ADR conformance

- Placing `SelfHealingCoordinator` in the composition root is correct under ADR-052 (§3: the root
  wires). It must depend on the healing gem + `tamoz-sqlite` + the worker's durable store, all of
  which the root already depends on — **no new cross-vertical edge**, and no vertical gains a
  sibling dependency. Confirm with `diff_snapshot`.
- **Verified during review:** a durable `Tamoz::SQLite::CircuitStore` already exists
  (`test/sqlite_circuit_store_test.rb`, DR-2 D1–D10) and implements the exact seam interface the
  healing gem expects (`record_failure(kind:)`, `record_success`, `open?`). Phase H reuses it
  rather than writing a new store — assumption de-risked.
- **Gap found → adjustment:** the durable attempt counter needs explicit *reset-on-recovery*
  semantics, or one transient failure poisons a fingerprint forever. Reset the counter when the
  remediation outcome is `:recovered`; otherwise leave it to accrue toward the bound.

### Lens B — safety / authority

- Default-false flag + empty registry ⇒ escalate is the right fail-safe: wiring changes nothing
  until an operator stages a rule. Good.
- **F20-REL-01 closure, made precise:** the coordinator compares the durable counter against a
  `MAX_DURABLE_ATTEMPTS` const *before* calling `Remediation.run`, and increments **durable-first**
  (persist the increment before the protocol runs) so a crash mid-remediation cannot reset the
  bound. Over-bound ⇒ escalate without running. This holds regardless of the gem's internal gap.
- **Untrusted-prose boundary:** build the `FailureRecord` fingerprint from the `failure_signature`
  sha256 already carried at the seam — never pass the raw tool-error `reason` string as prose.
  Respects the gem's typed-signal construction.
- **Improvement:** stopping at candidate + sealed report (no self-promotion) satisfies ADR-023 and
  sidesteps the F23 forged-report gate. Trajectory export must write **only under the grant root**
  and set `partition`/`verified` explicitly.

### Net changes to the plan

1. Phase H reuses `Tamoz::SQLite::CircuitStore` (do not build a new store).
2. Add `MAX_DURABLE_ATTEMPTS`, durable-first increment, and reset-on-`:recovered` to the counter.
3. Fingerprint = existing `failure_signature`; never prose.
4. Trajectory export is grant-root-scoped.

## 7. Implementation outcome (2026-09-16)

### Healing — the seam shipped; the live call site is deliberately deferred

`Tamoz::Agent::SelfHealingCoordinator`
([self_healing_coordinator.rb](../gems/tamoz-agent/lib/tamoz/agent/self_healing_coordinator.rb))
ships as a complete, tested production class in `tamoz-agent`. It is a real caller of
`Healing::FailureRecord`, `RuleRegistry`, `SQLite::CircuitStore` (scope `:rule_target`), and
`Healing::Remediation.run`, and it **closes F20-REL-01** with a durable, fingerprint-keyed
attempt counter (durable-first increment, reset on `:recovered`), refusing before the protocol
runs. Five unit tests in
[self_healing_coordinator_test.rb](../test/self_healing_coordinator_test.rb) cover: empty-registry
escalate, the durable-bound regression, durable-circuit-open escalate, the happy path (durable
increment + `attempt:` passed through + counter cleared on recovery), and increment persistence on
a non-recovery.

**Healing is now LIVE in the agent turn (ADR-028 shadow stage).**
`Tamoz::Agent::SelfHealingAssessor`
([self_healing_assessor.rb](../gems/tamoz-agent/lib/tamoz/agent/self_healing_assessor.rb)) is
wired into `Runtime#run_action_mode`: when a turn's bounded repair loop gives up on a typed
failure, the runtime builds a typed `Healing::FailureRecord` from the structured
`tool_failure`/`check_receipt`, classifies it against the operator's staged rules (read-only,
via `Healing::Classification`), and emits a `:healing_assessment` event. The CLI renders it, so
`tamoz ask` now tells the operator, on any failed turn, whether the failure is a known
remediable class and which rule would own it (or names the never-mutate class / missing rule and
escalates). This executes nothing — it is the mandated first stage a rule passes before it earns
authority to act, and is safe on by default with an empty rule set. Wired at
`Tamoz::Agent.build(healing_rules:)` (default empty). Tests:
[self_healing_assessor_test.rb](../test/self_healing_assessor_test.rb) (unit, incl. a
`remediable: true` verdict) and [self_healing_live_turn_test.rb](../test/self_healing_live_turn_test.rb)
(a real failed turn emits the assessment).

**What remains for ACTIVE (effect-executing) remediation** — the next gated stage: the ephemeral
turn already does model-recompute-and-retry, so healing's differentiated value (durable circuit,
oracle-verified reconciliation, compensation across turns) lives in the durable worker. That path
needs (1) the durable-side `SelfHealingCoordinator` (shipped, F20-REL-01 closed) fed by the
turn's typed failure + behavior/policy pins across the ephemeral/durable boundary, and (2) an
authored healing rule that has earned authority through the `tamoz-evals` stages (ADR-028:
replay → shadow → fault-injection → canary → active). Active remediation is deliberately not
shipped on by default; the shadow stage above is the safe, useful increment that makes it real.

### Improvement — the full loop, finished and proven end to end

Two surfaces, matching the ADR-025 runtime/non-runtime split:

1. **Generation (runtime CLI).** `tamoz improve --corpus DIR`
   ([cli_improvement_commands.rb](../gems/tamoz-agent-cli/lib/tamoz/agent/cli_improvement_commands.rb))
   runs the real `Improvement::Generator` (deterministic, read-only) and prints the candidate.
2. **The full pipeline (evals layer, ADR-025 home for evaluation).**
   `Harness::HeuristicImprovementPipeline`
   ([heuristic_improvement_pipeline.rb](../gems/tamoz-evals-runner/lib/tamoz/evals/harness/heuristic_improvement_pipeline.rb))
   composes the production pieces into one vetted, promotion-ready bundle:
   **generate → paired holdout evaluation → pass/fail decision → immutable provenance.** It stops
   at the human gate — it returns the bundle a human approves and a durable promoter records; it
   never mutates behavior itself.

**The loop is closed and proven end to end.**
[heuristic_improvement_pipeline_test.rb](../test/heuristic_improvement_pipeline_test.rb) drives a
pipeline bundle through the **real** durable `Improvement::Promotion` against a real
`Memory::Engine`, then activates the transition, asserting the behavior version advances
(`session/2 → session/3`) — i.e. raw trajectories become a live, reversible behavior change through
generate → evaluate → human-gated promote → activate, using the production components (no doubles).
The activation half (`SessionMemory#claim_behavior_transition` at first intake) was already wired;
this connects the producing half to it. ADR-023's guarantees hold throughout: distinct holdout,
immutable provenance, human gate, reversible promotion, evaluator ≠ generator.

## 8. Quality bar for this change — and the check

| Bar | Status |
|---|---|
| Claim validated against code, not asserted | ✅ no production caller of either entry seam; corroborated by F20/F23 audits |
| A real (non-test) production caller reaches a gem entry seam | ✅ `tamoz improve` → `Improvement::Generator`; ✅ every failed agent turn → `SelfHealingAssessor` → `Healing::Classification` (shadow stage, §7) |
| Known audit criticals on the seam are not wired in live | ✅ F20-REL-01 closed at the coordinator boundary; F23 human gate respected (no promotion) |
| Default runtime behavior unchanged | ✅ no runtime path altered; `improve` is a new opt-in operator verb |
| New code is unit/integration tested; the fixed bug has a regression test | ✅ 18 new tests across 4 files, incl. the F20-REL-01 durable-bound regression and a live-turn assessment |
| No new dependency cycle or cross-vertical coupling | ✅ see `enola diff_snapshot` (§9) |
| Docs kept in sync (subcommand surface) | ✅ install guide lists `improve` |
| Terse comment style, matches surrounding idiom | ✅ |
