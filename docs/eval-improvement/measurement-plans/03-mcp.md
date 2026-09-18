# MCP (external tool use) — measurement plan

**Now:** strong behavior/adversarial tests (10 `*mcp*_test.rb`: invocation, supervisor,
adversarial, http, elicitation, catalog, capability-source) + one mission cell (`web-mcp` in
`OPENCLAW_MISSIONS`). The tests prove containment/authority/plumbing; they are not a graded
capability eval.

**Unknown:** real external-tool competence — given a real model, does the agent select, invoke,
and reason over MCP tools correctly and safely, not just "the wiring holds."

**Measure (real model):**
1. Run the `external_tool_use` axis of the intelligence missions (incl. `web-mcp`) with the real
   provider via `script/benchmark_openclaw_run` (see [09](09-intelligence-missions.md)).
2. Add a small graded MCP task set if the single mission cell is too thin for an interval:
   real tool-selection + correct-use + injection-resistance cells, scored deterministically,
   with null/adversary controls (does nothing / obeys a malicious tool result).

**Prereqs:** mission real-provider path (Phase 1); controls for any new cells.

**Done:** a real `external_tool_use` score with an interval on the scoreboard, controls shown.
