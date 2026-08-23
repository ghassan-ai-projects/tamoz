# 07 — Technical implementation plan

_Working plan for executing docs 00–06, reconciled against the gap-analysis and
completeness audits (2026-08-23). Each phase has a bar; a phase is done when the
bar is met, and the next phase does not start on an unmet bar._

## Ground truth established before planning

Measured on the working tree (2026-08-23, `main` @ 0c913ad):

- Tests are **repo-root only** (`test/`, 237 files). They stay at root; the root
  suite loads `tamoz/agent` wholesale via `test_helper.rb`, so namespace-preserving
  extraction keeps them green provided the umbrella still pulls the family.
- `Plan.deep_freeze` already delegates to `Tamoz::Core.deep_freeze` (P16).
  Remaining Knot-1 work: `parse_object/string/strings` still on `Plan` raising
  `ProtocolError`; private `deep_freeze` dupes in `intent_catalog.rb`,
  `profile.rb`.
- All 38 Plan-helper call sites are inside tamoz-agent lib; zero external-gem or
  test callers. `ProtocolError` rescue sites: ~12 (listed below) — none in the
  verticals.
- Extraction exemplar: `gems/tamoz-approval` layout + `TamozGemspec.build`;
  versions are **hand-synced identical literals** (`0.1.0.alpha.1`), one per gem
  module — new gems replicate this.

## Audit resolutions (binding)

| Question | Resolution | Evidence |
|---|---|---|
| Kernel deps | core, sqlite, tools, observability — NO graph/comms/approval | probe set |
| `episode_graph.rb` | **Runtime cluster** (stays in tamoz-agent): zero lib consumers, only stream tests + `test/support/episode_composition.rb`. Keeps kernel off `tamoz-graph`. | grep |
| `effect_dispatcher.rb:313` bare `Toolbox` | Spell `Tamoz::Tools::Toolbox` (alias lives in agent.rb, dies with extraction) | gap #2 |
| `request_projection.rb`, `request_route.rb`, `terminal_progress.rb` | Runtime-stays (terminal_progress shared by worker.rb + cli_rendering.rb; single cross-group require_relative to repoint at P5) | completeness T1 |
| `lane_config.rb` | **Not dead** — consumed by tamoz-stream (`episode_worker.rb`, `situation_request.rb`) + tests. Runtime-stays. | grep (overrules gap report) |
| improvement→Memory real edges | `heuristic.rb:66`, `promotion.rb:198,286,318` (`errors.rb:11` is comment-only) | completeness §3.4 |
| `Session::GRAPH_VERSION` | Hoist the four version constants (`GRAPH_VERSION/CURRENT/ADAPTIVE/COMPACTION`) into a kernel-owned module at P1; repoint `session.rb`, `session_nodes.rb`, `profile/authority_validator.rb:100`, `tamoz-evals/openclaw_durable_cli_adapter.rb:398` in the same commits | grep |
| Doc-06 tooling (cop, dep-fitness script) | **Out of scope** — owner ignores rubocop (a RuboCop cop is moot); enola baseline/diff per phase covers Signals 1/2/5 | decision |
| 04-F mcp bridge gem | Out of scope this effort (doc 04 itself says flag-not-rush) | decision |
| 04-H stale names | Opportunistic only when a phase already touches the file | decision |
| `SessionRecords.load!` / `Worker#advance_thread` hotspots | Out of scope — runtime cluster is explicitly not split in this study | decision |

## Per-phase wiring checklist (EVERY phase that creates a gem)

1. Root `Gemfile`: add `path: "gems/<name>"` entry.
2. `test/test_helper.rb` `GEM_ROOTS`: add the new gem name — this is BOTH the
   dependency-audit registry AND the suite `$LOAD_PATH` (incl. evals subprocess
   filter). Unlisted = silently unaudited.
3. `test/packaging_test.rb`: extend both hardcoded lists (isolated-install,
   scorecard) the moment tamoz-agent's gemspec gains the dep.
4. New gem: gemspec via `TamozGemspec.build` (lockstep literal VERSION),
   `version.rb`, LICENSE, README stating public surface, chmod 644.

## The bar (applies to every phase)

A phase = Stage A commit (pure move) + Stage B commit (simplify). Phase done
when ALL hold:

1. **Stage A is a pure move**: paths + require rewiring only; no semantic edits.
   Own commit.
2. **Targeted gates green**: the phase's named suites pass (`rbenv exec ruby
   -Itest <file>`, ONE FILE PER COMMAND) + smoke load of every consuming gem
   (`rbenv exec bundle exec ruby -e 'require "tamoz/agent"'`). No rubocop ever.
   Full suite deferred to finish line.
3. **enola objective check**: `generate_snapshot` + `diff_snapshot` vs pinned
   baseline — after Stage A: zero new coupling across the seam; after Stage B:
   findings inside the moved gem resolved, not relocated.
4. **Stage B landed**: named targets simplified; pure re-export facades
   collapsed or responsibility documented in the README; dead refs removed.
5. **Wiring checklist complete** (above) for the phase's gem(s).
6. **Commits made**, Stage A / Stage B separate.

**Finish line:** all bars met; `rake ci` green under BOTH locales; final enola
diff clean; root README component map + `documentation/architecture/gems.md`,
`getting-started/install.md`, `reference/public-api.md` reconciled; docs
committed; `tamoz-agent` ≈ 10.9k-line runtime + extracted family in lockstep.

## Phases

### P0 — Kernel knots (in place, no new gems)

| # | Move | Detail |
|---|------|--------|
| D | `Plan.parse_object/string/strings` → core | Home in `tamoz-core`; raises a core-level error (`< Tamoz::Core::Error`). Same commit: switch the ~12 `ProtocolError` rescue sites (errors.rb def, session_plan_attempt:76,197, episode_nodes:449, session_planning_context:127, session_adaptive:84, episode_model_transport:160, witness_gateway:155,206, session_routing:35,165, runtime:176,491) + fold `deep_freeze` dupes in intent_catalog/profile onto core. |
| 3 | `Event` → own file | Out of `runtime.rb:9` into `lib/tamoz/agent/event.rb`; zero churn (verified). |
| C | `raw_http.rb` → tamoz-core | Repoint `witness_gateway.rb:11` require + `test/support/local_model_endpoint`. |
| B | `durable_recorder.rb` → tamoz-observability | Consumers: cli_worker_commands + evals durable-cli adapter require path. |

Gates: memory/healing/session smoke suites + evals harness load + stream
episode fixed-graph test (exercises Event/episode paths).

### P1 — `tamoz-agent-kernel`

Files: errors, diagnosis_catalog, intent_catalog, skill_set, model_receipt,
reasoning_document, episode_model_transport, episode_model_call,
episode_tool_call, receipt_budget_controller, witness_gateway, witness_verifier,
sealed_build, episode_frame_builder, episode_nodes, behavior_version, plan,
deliberation, effect_dispatcher, event (+new graph_versions module).
NOT kernel: episode_graph, request_route/projection, lane_config, ruby_llm_model.
Deps: core, sqlite, tools, observability.

Stage A extras: `Toolbox.observe` → `Tamoz::Tools::Toolbox.observe`;
wiring checklist incl. GEM_ROOTS + packaging lists; evals durable-cli adapter
repoint if it touches moved spellings.
Stage B targets: `Deliberation.structural_issues` (cx 21),
`EffectDispatcher.run` (cx 16); graph_versions hoist lands here (constants out
of session.rb/session_nodes.rb, evals adapter + profile repointed).

### P2 — `tamoz-agent-memory`

14 files. Depends: kernel (+core/sqlite). Stage B: admission/consolidation
freeze-parse audit post-D; resolve in-gem enola findings.

### P3a — `tamoz-agent-healing` / P3b — `tamoz-agent-profile`

Independent; may run as parallel agents over disjoint file sets. Healing: 24
files. Profile: 15 files; authority_validator already repointed at P1B.
Stage B (profile): collapse the 566-line re-export half of `profile.rb`
(fan-out 106) or document its real responsibility. Stage B (healing): in-gem
enola findings resolved.

### P4 — `tamoz-agent-improvement`

11 files; after P2 (edges: heuristic.rb:66, promotion.rb:198,286,318).
Stage B: candidate lifecycle/promotion split.

### P5 — `tamoz-agent-cli`

14 `cli*.rb` files + `exe/tamoz`; depends on tamoz-agent.
Extras: `cli_rendering.rb:3` require_relative → gem path; `apps/tamoz-agent/app.json`
`runtime_package` repoint; `packaging_test.rb` executable assertion migrates to
CLI gem; `dependency_isolation_test.rb:193` allowed-list += tamoz-agent-cli.
tamoz-agent becomes a pure library (no executable).
Stage B: cli_comms_* command-group duplication.

### P6 — Comms trio → `tamoz-comms`

`comms_gateway.rb`, `outbox_delivery_sink.rb`, `delivery_drainer.rb` (~796
lines). Consumers unchanged. Stage B: Telegram seam (04-G) behind comms
abstraction. 04-E RubyLLMModel: **deferred by owner decision** — the class is
load-bearing (worker `model_factory`, evals benchmark adapter,
`Profile::KNOWN_PROVIDERS` source) and its extraction adds topology edges
outside the approved diagram; stays in the runtime cluster.
