# 08 — Remaining work after implementation

Status at writing: every planned phase (P0–P6) is implemented and committed on
branch `decomposition/agent-gems`; the full root suite runs with zero
extraction-caused regressions (every remaining red reproduces identically at
the pre-work baseline `db9b530`). This doc lists what a fresh session should
pick up, in priority order, with the context needed to start cold.

## Commit chain (newest last)

```
db9b530  P1 fix (baseline umbrella load)      ← tag wave-a-pre
2f01925  P2-A memory
e970313  P3a-A healing
dcd80d7  merge decomp/healing (union wiring)
175485a  P3b profile
ee89c0c  revert ci.yml matrix narrowing swept into dcd80d7
737383c  wiring hygiene from Wave A review
f48e4f4  P4 improvement (salvaged from deadline-expired agent)
562f144  merge decomp/improvement
6c0bd14  P5 cli (tamoz-agent becomes a pure library)
c883b62  P6 comms trio into tamoz-comms
1c6cfbc  docs component-map reconciliation
fcb3e93  generated-artifact + subprocess-list debts
c0245ba  audit: keep owner-environment audit
6a73259  audit: disclose environment-bound evidence gaps
```

## 1. Reviewer round over the post-Wave-A range (recommended first)

Wave A (P2 through P3b) received two independent reviewer passes (R1 blocker
fixed in `ee89c0c`, R2 NITs applied). **P4 (`f48e4f4`), P5 (`6c0bd14`), P6
(`c883b62`) and the finish-line commits have had no independent review.** Run
the read-only reviewer pairs from `docs/subagent-orchestration.md` over
`562f144..6a73259`. Known accepted deviations reviewers should not relitigate:
tests stay at repo root; Option-B namespaces (`Tamoz::Agent::X` inside
`tamoz-agent-x`); umbrellas named `lib/tamoz/agent_<x>.rb`; hand-synced literal
VERSION `0.1.0.alpha.1`.

## 2. Regenerate the requirements audit where kills run

The committed `docs/requirements-audit.json` marks INV-19 and OBJ-4 failing.
Both named cases pass standalone; their *supporting* evidence drives real
SIGKILLs (sqlite selector-control intervention, session kill matrix) and that
mechanism cannot complete in constrained environments ("selector control was
not authorized"). On a machine where signal delivery to children is authorized:

```
bundle exec ruby script/generate_requirements_audit --accept
```

then delete the two environment-bound disclosures in
`documentation/limitations.md` and their entries in
`GAP_DISCLOSURES` (`test/documentation_surface_test.rb`). The page and map fail
loudly if they drift, so the three artifacts move together.

## 3. Pre-existing red inventory (untouched by design)

24 suites are red at baseline exactly as they were before any decomposition
work. They fall into three groups; none block the extraction:

- **Real-model / network gated**: `agent_latency_smoke`,
  `agent_mcp_adversarial`, `benchmark_*`, `stream_episode_real_model`,
  `websearch_egress`, `websearch_invocation`, `stream_worker_server`.
- **Kill-probe / environment-bound**: `sqlite_raw_oracle`,
  `sqlite_convergence_probe`, `sqlite_selector_control`,
  `agent_approval_boot`, `capability_host` (see §2 above).
- **Latent semantic reds** (fail on any machine): `agent_session_kill_matrix`
  (one assertion, `Expected ["continue:finalized"] Actual ["continue:r3"]`),
  `agent_cli_mcp` (3 failures), plus single-failure reds in `approval_resolve`,
  `evals_verifier`, `m1_evidence`, `m2_evidence`, `comms_adr049_consistency`,
  `agent_skills_toolbox`, `agent_tool_error_recovery`, `p16_tools_gem`
  (`build` rejects `:approval` keyword — test written for a planned API),
  `sqlite_scenario_driver`.

These predate this branch and were proven identical against `db9b530` by
running each suite there. A fresh session that wants to burn them down should
treat them as its own project, not as decomposition fallout.

## 4. Deferred moves from the study (owner decisions recorded in the plan)

- **04-E `RubyLLMModel` → own gem**: deferred by owner decision — load-bearing
  in worker `model_factory`, evals benchmark adapter, `Profile::KNOWN_PROVIDERS`;
  extraction adds topology edges outside the approved diagram (07, P6 section).
- **Session/worker split**: explicitly out of scope (01, ~line 217) — shares the
  durable record and thread-advance machinery; the enola coupling cluster lives
  here by design.
- **04-B `DurableRecorder` → observability**: skipped by audit; private_constant
  with a single internal consumer. Re-evaluate if a second consumer appears.
- **04-F governed sources / MCP builder bridge gem (~800 lines)**: never
  scheduled as a phase; medium confidence. Still open if wanted.
- **04-H stale `Tamoz::Agent::*` names in core/tools/mcp**: cheap renames never
  picked up. Note `core.rb:31`'s `TOOL_ERROR_CLASS_NAMES` mapping to
  `Tamoz::Agent::Tool*` is a *deliberate public alias*, not stale — check each
  site before renaming.

## 5. Stage B debts consciously shipped as documentation

- **Telegram seam (04-G, P6 Stage B)**: `cli_comms_shared.rb` still references
  `Tamoz::Telegram` directly. The transport-neutral seam belongs behind
  `Tamoz::Comms::Transport` so the CLI speaks only comms. Left as documented
  debt rather than rushed.
- **CLI command-group structure (P5 Stage B)**: the uniform `cmd_*` dispatch
  across seven included modules is deliberate; documented in
  `gems/tamoz-agent-cli/README.md` rather than collapsed.
- **deep_freeze variants**: profile's variant folded at P3b; four pre-existing
  private variants remain out of scope (`mcp_capability_source.rb:247`,
  `comms/surface_descriptor.rb:261`, `tamoz-mcp/canonical_json.rb:23`,
  `sqlite/boundary_source_audit.rb:594`).

## 6. Small loose ends

- **ci.yml**: reverted to the committed 3-matrix state after an unrelated
  working-tree edit was swept into `dcd80d7`. The owner's Ruby-4.0-only matrix
  experiment is recoverable via `git show dcd80d7 -- .github/workflows/ci.yml`
  if that direction is still wanted.
- **`rake ci` both locales (`ci_full`)** was not run in-session beyond the
  default-locale full root suite; PR CI covers the gate set mechanically.
- After merge: delete `decomposition/agent-gems`, re-pin the enola baseline on
  the merged main so the next change grades against the new topology.

## How to resume

Read `docs/subagent-orchestration.md` first (front-loaded briefs, file
ownership, named gates + known-red list, integrator holds commits). The
implementation protocol that worked: one implementation subagent per gem
extraction over a worktree branched from current HEAD, orchestrator-owned
shared wiring (Gemfile, GEM_ROOTS in `test/test_helper.rb`, both hardcoded
lists in `test/packaging_test.rb`, `docs/public-api.json` +
`test/public_api_test.rb` inline map, gemspecs, `agent.rb` require swap,
evals subprocess lists in `gems/tamoz-evals/.../agent_smoke_corpus.rb`),
one-test-file-per-command gates, deadline-plus-salvage.
