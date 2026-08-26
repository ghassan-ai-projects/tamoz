# Implementation plan — `tamoz-agent-capabilities` then `tamoz-agent-session`

> Historical assessment. Superseded on 2026-08-26 by the current gem-boundary and
> model-call plans. Retained for provenance; its RubyLLM references are not current support.

Companion to [FINDINGS.md](FINDINGS.md). Scope chosen by owner: **both gems,
capabilities first, session on top.** This continues the six-gem decomposition
(`docs/agent-gem-decomposition-2026-08-23`) and picks up two moves that study
explicitly left open — 04-F (the capability/sources bridge) and the runtime
split its risk table said to "reassess against a much smaller, cleaner
`tamoz-agent`" (03, line 133). That reassessment is [FINDINGS.md](FINDINGS.md);
this is the execution.

It reuses that study's machinery verbatim — the **two-stage rule** (Stage A pure
move, Stage B simplify, both inside the phase), the **per-phase wiring
checklist** (07 §"Per-phase wiring checklist"), the **bar** (07 §"The bar"), and
**Option-B namespacing** (03: gem named `tamoz-agent-<x>`, code keeps
`Tamoz::Agent::X`). Those are not restated here; follow them as written.

---

## Ground truth (measured on `main` @ current HEAD, 2026-08-24)

- **Umbrella convention (as-built):** `lib/tamoz/agent_<x>.rb` at the top, subtree
  stays under `lib/tamoz/agent/`. Confirmed against `agent_memory.rb`,
  `agent_kernel.rb`. (07's text says `agent/<x>.rb`; the shipped gems use
  `agent_<x>.rb` — follow the shipped ones.)
- **VERSION:** hand-synced literal `0.1.0.alpha.1`, one `version.rb` per gem,
  gemspec pins `= …::VERSION`. Replicate.
- **enola snapshot is STALE** ("commit moved" since the decomposition merge). It
  must be regenerated and re-baselined on current `main` before any move, or the
  per-stage `diff_snapshot` gate is meaningless.
- **Tests are repo-root only** (`test/`); the root suite loads `tamoz/agent`
  wholesale, so Option-B keeps them green as long as `agent.rb` still requires
  the family. Named gates below are the fast per-phase check, not a substitute
  for the finish-line full suite.

---

## K1 — pre-move knot (in place, no gem yet)

Two edges point the wrong way for the split. Fix them first, in `tamoz-agent`,
as their own reviewable commit — exactly how P0 untied the kernel knots.

| # | Move | Detail |
|---|------|--------|
| K1a | **Invert the Runtime constants down** | `MAX_TASK_BYTES`, `MAX_OBSERVATION_BYTES`, `MAX_REPAIR_ATTEMPTS` live on `Runtime` (`runtime.rb:27-29`) but are consumed by the lower Session layer (`session.rb:69`, `session_nodes.rb:24-25`). Move them onto a Session-owned (or kernel-owned) home so Session stops importing *up* into a driver. Repoint the three read sites + `Runtime`'s own uses in the same commit. This is the **only inversion the split requires**; without it, PB creates a `tamoz-agent → tamoz-agent-session → tamoz-agent` cycle. |
| K1b | **Promote `SessionRecords.digest` to public** | `Runtime` (the ephemeral driver, staying in `tamoz-agent`) calls `SessionRecords.digest` (`runtime.rb:753,786`). Once `SessionRecords` moves to the session gem, that call crosses a gem boundary, so `digest` becomes documented public surface of `tamoz-agent-session`. No code change beyond a README/public-api entry — just don't let PB hide it. |

Gate for K1: `agent_session_test`, `agent_session_records_test`,
`agent_session_operations_test`, plus a smoke `require "tamoz/agent"`. enola
`diff_snapshot`: the Session→Runtime edge is gone, no new edge introduced.

---

## Phase PA — `tamoz-agent-capabilities`

The bridge Session stands on. Extract it first so PB depends on a finished gem,
not on ungrouped runtime files.

**Gem:** `tamoz-agent-capabilities` · **namespace:** `Tamoz::Agent` (unchanged) ·
**umbrella:** `lib/tamoz/agent_capabilities.rb`

**Files (~1,205 lines), moved verbatim in Stage A:**
```
capability_binding.rb (402)      mcp_source_builder.rb (276)
mcp_capability_source.rb (263)   governed_browser_source.rb (168)
governed_database_source.rb (96)
```
`child_environments.rb` (59) is a judgment call — it configures governed child
processes; check its consumers during Stage A and pull it in only if it belongs
to the sources cluster rather than the child-task driver.

**Depends on:** `tamoz-agent-kernel`, `tamoz-mcp`, `tamoz-agent-profile`,
`tamoz-core`. **Not** session, worker, graph, comms, approval (verified: nothing
in the cluster references them).

**Consumers to keep resolving (Option B → no source churn):**
`session_nodes.rb:103` (`CapabilityBinding.build`), `runtime.rb`,
`worker_runtime.rb`, `mcp_source_builder.rb` (self), plus two outside
`tamoz-agent`: `tamoz-evals` harness (`agent_smoke_corpus.rb`) and
`tamoz-agent-cli` (`cli.rb:612`, `McpSourceBuilder.new(...)`). Add
`tamoz-agent-capabilities` to the CLI and evals gemspec deps so those two name it
directly rather than leaning on transitive resolution.

**Named gates:** `agent_capability_binding_test`,
`agent_mcp_capability_source_test`, `agent_governed_database_source_test`,
`agent_phase4_capability_test` + smoke-load of `tamoz/agent`, `tamoz/agent/cli`,
and the evals harness.

**Stage B targets:** audit `capability_binding.rb` (402 lines) — is `.build` a
real assembler or a re-export facade? Collapse the re-export half or document the
responsibility. Resolve any in-gem enola findings the move surfaces. Fold the
`mcp_capability_source.rb:247` private `deep_freeze` variant onto
`Tamoz::Core.deep_freeze` **only if** enola flags it here (it was left out of
scope at P0 — take it opportunistically since the file is already open).

---

## Phase PB — `tamoz-agent-session`

The deliberation loop.

**Gem:** `tamoz-agent-session` · **namespace:** `Tamoz::Agent` (unchanged) ·
**umbrella:** `lib/tamoz/agent_session.rb`

**Files (16, ~5,043 lines):** the whole `session*.rb` family (listed in
FINDINGS §2), moved verbatim in Stage A.

**Depends on:** `tamoz-agent-capabilities` (PA), `tamoz-agent-kernel`,
`tamoz-agent-memory`, `tamoz-agent-profile`, `tamoz-agent-healing`,
`tamoz-core`. **Not** graph/comms/approval (the model/toolbox/mcp source are
injected and duck-typed — `session.rb:174`).

**New gemspec edge: `tamoz-agent-cli → tamoz-agent-session`.** The CLI names
`SessionStatusProjection`, `SessionPlanningContext`, and `SessionRecords`
directly (table above), so its gemspec — today only
`['tamoz-agent', ...]` (`tamoz-agent-cli.gemspec:14`) — must add
`tamoz-agent-session` (and `tamoz-agent-capabilities`, for `McpSourceBuilder` at
`cli.rb:612`). Under Option B the constants still *resolve* transitively, so the
suite stays green even if this is forgotten — which is exactly why it's easy to
miss. Update in the same phase: `dependency_isolation_test.rb:212` allowed-list,
`packaging_test.rb` both lists, and the `docs/public-api.json` ownership flip for
the moved constants.

**Public surface to freeze (Stage A must not change it).** Two driver families
consume it, and the **CLI reaches wider than the worker** — this was missed in
the first assessment pass and is corrected here:

_Worker/Runtime facade_ (`worker.rb:254,449,472,556,1152`): `start` · `resume` ·
`continue` · `recover` · `view` · `effect` · `model` · `close` · `capabilities` ·
`outcome` · `app` (→ `durable_runner`, `checkpointer`) · `build_definition` ·
constants `ROUTINGS`, `MODEL_CALL_SAFETIES`, `GRAPH_NAME`.

_CLI additionally reaches into four session-family internals_ — these become
**exported public surface of `tamoz-agent-session`**, not private:
| Symbol | CLI call site |
|---|---|
| `Session#verify_skill_binding!`, `Session#resolve_effect`, `app.durable_runner.submit` | `cli_session_commands.rb:50,169,244` |
| `SessionStatusProjection.document`, `::SCHEMA` | `cli_worker_commands.rb:530,540`; `cli_rendering.rb:60-168` (5×) |
| `SessionPlanningContext.follow_up_payload` | `cli_session_commands.rb:147` |
| `SessionRecords::LEGACY_PROFILE_ID` (+ `.digest`, K1b) | `cli_authority.rb:103`; `cli_profile_commands.rb:107` |

Stage A must keep every one of these resolvable and unchanged; Stage B may not
hide any of them behind a private boundary.

**Named gates:** `agent_session_test`, `agent_session_records_test`,
`agent_session_adaptive_test`, `agent_session_effect_test`,
`agent_session_operations_test`, `agent_session_status_projection_test`,
`legacy_session_resume_test`, `memory_session_integration_test`,
`agent_durable_routing_test` + smoke-load of `tamoz/agent` (worker path) and the
evals harness.
> Note: `agent_session_kill_matrix_test` is a **known pre-existing red** (08 §3,
> `continue:finalized` vs `continue:r3`) — it must stay red *identically*, not
> newly red. Prove parity against pre-move HEAD; do not try to fix it here.

**Stage B target:** `SessionRecords.load!` — cyclomatic complexity **21**
(enola), the most-branched symbol in the family and the durable-record decoder.
Simplify against the now-fixed boundary. Resolve any other in-gem findings
`diff_snapshot` surfaces for the moved files.

---

## What stays in `tamoz-agent` after PB

The **drivers** and their shared machinery — ~5,400 lines, finally meaning one
thing (drive the loop, durably and ephemerally):

- durable execution: `worker.rb`, `worker_runtime.rb`
- ephemeral execution: `runtime.rb`
- child-task machinery: `child_task.rb`, `child_task_dispatcher.rb`,
  `child_environments.rb` (unless pulled into PA)
- delivery/recording/misc: `durable_recorder.rb`, `request_projection.rb`,
  `request_route.rb`, `lane_config.rb`, `terminal_progress.rb`,
  `episode_graph.rb`, `ruby_llm_model.rb` (04-E, owner-deferred), `agent.rb`

Keeps its `tamoz-graph` / `tamoz-comms` / `tamoz-approval` edges. Worker↔Runtime
still share the durable-record and thread-advance machinery — **that** is the
real tight coupling, and it is deliberately not split (FINDINGS §4).

---

## Order, bar, finish line

1. **K1** (in place) — green, own commit.
2. **PA** — Stage A (move) + Stage B (simplify), each its own commit, bar met.
3. **PB** — Stage A + Stage B, bar met.

The **bar** and **per-phase wiring checklist** are 07's, unchanged: Gemfile
entry, `GEM_ROOTS` in `test/test_helper.rb`, both lists in
`test/packaging_test.rb`, `docs/public-api.json` + `test/public_api_test.rb`
package sections (`GEM_ROOTS.keys == packages.keys` is asserted), gemspec via
`TamozGemspec.build` with lockstep literal VERSION, `version.rb`, LICENSE,
README stating the public surface, and the `require_relative "agent/<x>"` →
`require "tamoz/agent/<x>"` swap in `agent.rb`.

**enola per stage** (the objective check): re-pin baseline on current `main`
first; after each Stage A, zero new coupling across the new seam; after each
Stage B, the named complexity/facade finding is **resolved, not relocated**.
Specifically watch for a `tamoz-agent ↔ tamoz-agent-session` cycle — if it
appears, K1a was incomplete.

**Finish line:** all bars met; `rake ci` green under **both** locales; final
`diff_snapshot` clean; root README component map + `documentation/architecture/
gems.md` reconciled to nine `tamoz-agent-*` gems; docs committed. After merge,
re-pin the enola baseline again so the *next* change grades against the new
topology.

---

## Open risks specific to this plan

| Risk | Containment |
|---|---|
| K1a missed a Runtime-constant reader → import cycle | enola `diff_snapshot` after PB Stage A fails loudly on the cycle; grep all three constant names repo-wide during K1. |
| `capability_binding.build` is a fat facade, not a clean seam | That's the PA Stage B question; if it's doing real assembly the gem is honest, if it's re-export, collapse it. Either way the phase isn't done until answered. |
| `SessionRecords.digest` accidentally left private in PB | K1b makes it public API up front; `public_api_test.rb` asserts the package surface, so a hidden cross-gem call fails the wiring gate. |
| `child_environments.rb` placed in the wrong gem | Decide by its consumers during PA Stage A, not by name; if it serves the child-task driver it stays in `tamoz-agent`. |
| Known-red suites masking a real regression | Pin the 08 §3 red inventory against pre-move HEAD and require identical failures — new red = stop. |
