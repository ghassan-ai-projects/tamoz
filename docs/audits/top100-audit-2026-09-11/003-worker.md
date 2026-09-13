# Audit 003 — `gems/tamoz-agent/lib/tamoz/agent/worker.rb`

Rank 3 · 1377 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: PLACE, DEAD, STATE

The "composition, not an engine" header is undercut: the worker also owns correspondent-facing
message copy and model-call metering, plus one dead and one unsafe attr_reader.

## Findings

- **[major][PLACE]** Orchestration is mixed with rendering (completion_text/failure_text/
  blocked_text/stop_text/crashed_text — the copy correspondents receive) and with observability
  metering (emit_durable_model_calls/model_usage). Owning seam: delivery text beside
  TerminalProgress/the delivery-sink layer; metering beside Observability::Producer.
  (worker.rb:849-931, 1274-1374)
- **[minor][DEAD]** `attr_reader :processed` has zero consumers repo-wide (grep-proven; the emit at
  line 116 reads the ivar directly). (worker.rb:47)
- **[minor][STATE]** `attr_reader :parked` hands collaborators the live Hash that @monitor guards;
  its only consumer (test/agent_worker_test.rb:271) reads internal `:signature` meta
  unsynchronized. Owning seam: a synchronized snapshot/parked-reason reader. (worker.rb:47,
  1054-1066)
