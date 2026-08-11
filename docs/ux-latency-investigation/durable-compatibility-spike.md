# Durable compatibility spike

**Date:** 2026-08-11  
**Scope:** Slice 4 precondition only; no durable graph change was made.

The current durable protocol is explicitly versioned:

- Session::GRAPH_VERSION is "1".
- SessionNodes::GRAPH_VERSION is "1".
- SessionRecords::RECORD_VERSION is 1.
- v1 session records preserve their graph identity through load.
- The record loader preserves a future graph_version value, while resumed views,
  outcomes, and continuations now fail closed because the runtime has no selector
  that chooses a graph definition from that value.

Evidence:

- test/agent_durable_compatibility_spike_test.rb pins the version constants,
  v1 round-trip, and the absence of implicit graph migration.
- test/agent_session_kill_matrix_test.rb exercises resumable v1 barriers across
  deliberation, approval, effect preparation/start/publication, verification,
  terminal commit, and blocked unknown outcomes.
- The current UTF-8 ci_full run passes 1,473 main tests and 134 slow tests; the
  current C-locale run reaches 1,473 main tests before the known pre-existing
  `McpServerConfigTest` invalid-byte-sequence error.

Conclusion: durable routing must not change SessionNodes in place. The next
durable slice requires explicit v1/v2 graph selection keyed by the persisted
session record, followed by the same kill matrix against both definitions.
