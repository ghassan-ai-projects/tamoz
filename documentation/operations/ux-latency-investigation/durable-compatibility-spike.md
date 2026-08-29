# Durable compatibility spike

**Date:** 2026-08-11  
**Scope:** Slice 4 compatibility spike and its implemented follow-up. The original
spike was run before the durable graph change; this page now records the resulting
v1/v2 decision.

The current durable protocol is explicitly versioned:

- Session::GRAPH_VERSION is "1".
- SessionNodes::GRAPH_VERSION is "1".
- SessionRecords::RECORD_VERSION is 1.
- v1 session records preserve their graph identity through load.
- `Session::CURRENT_GRAPH_VERSION` is "2" and the runtime selects the graph from
  the persisted checkpoint metadata before decoding state.
- Existing v1 threads use the v1 definition; explicit experimental routing creates
  new v2 threads with the route node and read-only discovery branch.

Evidence:

- test/agent_durable_compatibility_spike_test.rb pins the version constants,
  v1 round-trip, and the absence of implicit graph migration.
- test/agent_session_kill_matrix_test.rb exercises resumable v1 barriers across
  deliberation, approval, effect preparation/start/publication, verification,
  terminal commit, and blocked unknown outcomes.
- The focused compatibility, durable routing, kill-matrix, and trace suites pass.
  The aggregate CI runner remains separately documented as an environment/order
  evidence gap in `IMPLEMENTATION_EVIDENCE.md`.

Conclusion: durable routing does not reinterpret v1 checkpoints. The v1/v2 selector
is keyed by persisted graph metadata, and the same recovery contract remains covered
by the focused compatibility and kill-matrix suites.
