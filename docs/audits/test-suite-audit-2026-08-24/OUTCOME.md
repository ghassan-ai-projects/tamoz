# Outcome — branch perf/test-suite-under-60s (2026-08-24)

Executes §7 of the audit above. Two results:

| Goal | Result |
|---|---|
| Suite green | All audit-time reds resolved (see ledger below); `rake ci` exit 0 |
| Everyday gate under 60s | `rake ci` = **34.9s / 33.0s** on consecutive runs (budget guard enforces ≤60s) |

## What changed

### Lane + scheduling (Rakefile)
- `agent_scorecard_test` (49.8s) and `memory_treatment_profile_test` (15.7s) moved from the
  everyday lane into SLOW_TESTS — they are scorecard/data-profile gates, not behaviour probes,
  and they set the packing floor of every parallel run. They still run in `test_slow`/`ci_full`.
- TEST_WEIGHTS refreshed from this audit's measurements (the old table was up to 13× stale);
  missing heavy entries added.
- New budget guard: `rake ci` fails if wall clock exceeds 60s (`CiBudget`, first prerequisite).

### Duplicate clusters (audit §5)
- Cluster 1 merged: `agent_capability_binding_test` absorbed into `capability_host_test`
  (host + binding layers assert the same surface; size gate waived with justification).
- Cluster 2 merged: `m1_evidence_test` absorbed into `m2_evidence_test` (SLOW lane owns the
  sandboxed conformance runners); m1's environment guards carried over verbatim.
- Cluster 4 merged: `agent_toolbox_invariant17_test` unique cases moved into
  `agent_toolbox_test`; duplicates deleted against stronger exact-message survivors.
- Clusters 3, 7, 10, 11: **no merge** — method-level diffs showed layered, non-equivalent
  assertions (session-layer vs invocation-layer, provider-reachable vs network-disabled,
  three different memory stacks). Kept per zero-lost-verification.
- Cluster 12: CLI copy of the write-refusal deleted; source-level owner kept.
- Net: 3 test files removed, zero assertions lost (ledger in commit message).

### Red baseline repaired (prereq, audit step 1)
Root causes, all traced before fixing:
- Decomposition require-closures: child load-path allow-lists in acceptance-workflow,
  kill-matrix and four sqlite slow-lane tests lacked the extracted gems
  (cancellation/concurrency/capabilities/session); same class in `script/websearch_adapter`.
  This had MASKED real failures — e.g. the kill matrix's DR-4 shape assertion never ran on main.
- Digest/artifact drift after deliberate commits: BENCHMARK_PROTOCOL regenerated via committed
  script (sealed_build_digest seals ruby + Gemfile.lock sha), holdout pins re-pointed at the new
  protocol sha, P9 surface digests + P18 fixture `catalog_digest` regenerated against production.
- API drift: dropped `approval_required:` kwarg call sites (gating now lives in descriptor/policy
  data); `Agent.build(approval:)` replaced by the sanctioned `ask:` seam or profile selection;
  ADR-049 INV-D regex aligned to the redesigned policy wording; observability doc links repointed
  at the session gem.
- Production bug (one): `worker_runtime#sync_approval_policy` called `.policy_rev` on
  `Engine#reload`'s rev-string return and adopted before validating — now validates the pointer's
  document first, hands the loaded document to reload.
- Environment note: `m1_evidence` skips under hosts that deny seatbelt profile application
  (`sandbox_apply: Operation not permitted`) instead of failing — probe-based, honest skip.

## Known remaining debt (pre-existing on main, untouched here)
- `rubocop` reports ~150 offenses in four production files landed by PR #28/#29
  (runtime/plan_review.rb, runtime.rb, runtime/step_execution.rb, memory/admission.rb);
  mostly autocorrectable style plus a Metrics cluster in plan_review.rb that predates this branch.
