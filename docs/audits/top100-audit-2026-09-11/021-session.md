# Audit 021 — `gems/tamoz-agent-session/lib/tamoz/agent/session.rb`

Rank 21 · 794 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major, 3 minor) · Bar fails: SIZE, DEAD, DUP, STATE

The resume-binding guard family is coherent and well-documented, but the graph-DSL builder and
constructor carry severe size/param debt and one public guard is dead.

## Findings

- **[major][SIZE]** `build_definition` is a 156-line method assembling three graph variants behind
  `routed`/`adaptive` booleans (nodes, branches, edges all interleaved). Owning seam: per-variant
  graph declaration. (session.rb:437-592)
- **[major][SIZE]** `initialize` takes 19 keyword params (ceiling 5) and
  `validate_session_options!` re-checks them one by one. Owning seam: a frozen `Session::Options`
  value built/validated in one place. (session.rb:71-166)
- **[minor][DEAD]** `verify_graph_binding!` has zero callers repo-wide (grep-proven; only
  `enforce_graph_binding!` is referenced). The graph rule needs no public wrapper.
  (session.rb:265-269)
- **[minor][DUP]** The five `verify_*_binding!` entry points are five copies of the same
  stored-state→enforce wrapper. Owning seam: one parameterized guard registration.
  (session.rb:259-312)
- **[minor][STATE]** `build_definitions` memoizes `@nodes_v1/@nodes/@nodes_adaptive/
  @nodes_compaction` as a side effect of "building definitions"; hidden coupling silently consumed
  by `capabilities` and `current_egress_pin`. (session.rb:169-193)

## Resolution — 2026-09-12 (round 5)

- **[major][SIZE] build_definition FIXED** — the DSL assembly moved to `SessionGraph`
  (`session_graph.rb`): `definition_for(nodes, version)` with per-variant declarations and the
  state channels as literal lists; the four variants build through one path.
  `Session.build_definition` is gone (grep-proven: no external callers). `session.rb` is now
  516 lines and holds no graph DSL.
- **[major][SIZE] initialize FIXED** — `Session::Options` (`session_options.rb`): every keyword,
  its default, and every construction check (model, limits, safety, routing, durable
  checkpointer, MCP duck-type, profile binding) lives in one frozen value built through
  `Options.build`. `initialize` is a short builder reading the options; the caller-facing keyword
  API is unchanged (CLI/healing/capabilities construct `Session` from frozen gems).
- **[minor][DEAD] FIXED** — `verify_graph_binding!` deleted. Grep proof: zero references outside
  `session.rb` repo-wide (gems/, apps/, bin/, test/, script/); `enforce_graph_binding!` remains,
  used by `view`, `outcome`, and `guard_state!`.
- **[minor][DUP] FIXED** — the five stored-state→enforce wrappers collapsed onto one private
  `verify_binding!(thread)` (loads stored state, yields, nil); the four public
  `verify_*_binding!` entry points are one-liners (`verify_behavior_binding!` keeps its
  `@memory` gate). No dispatch registry — each entry point names its enforcer.
- **[minor][STATE] FIXED** — the four side-effect memoized `@nodes*` ivars are replaced by one
  frozen `@nodes_by_version` built by `build_nodes`; `nodes_for_default_graph` (hence
  `capabilities`) reads it, and `current_egress_pin` uses the verified `@profile` directly
  instead of reaching through the CURRENT-graph nodes.
