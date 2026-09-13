# Audit 042 — `test/agent_session_effect_test.rb`

Rank 42 · 646 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major) · Bar fails: TEST

Strong behavioral coverage, but three cases reach production behavior only through
`allocate`/`send`/`__send__` private pokes.

## Findings

- **[major][TEST]** Probes private implementation: `McpSourceBuilder.allocate.send(:map_mcp_error,
  ...)`, `SessionEffects.allocate.send(:result_payload, ...)` twice, and
  `adapter.__send__(:read, ...)` to read transitions. Owning seams: the public MCP dispatch outcome
  path, SessionEffects' public receipt/view API, and an adapter read API.
  (test/agent_session_effect_test.rb:321-327, 329-360, 634-645)

## Resolution — 2026-09-12

- **[major][TEST] FIXED** — `map_mcp_error` probe deleted; the ambiguous-outcome → `Tamoz::EffectUnknownError` mapping is now asserted through the public dispatch path (`McpSourceBuilder#build` + `source.execute`, `Invocation.call` stubbed) in `test/agent_cli_mcp_test.rb#test_mcp_errors_are_adapted_to_the_agent_tool_taxonomy`. The two `result_payload` probes were rewritten as public `SessionEffects#dispatch` drives over a real journal (a `FixedOutcome` capabilities fake returns the typed MCP outcome); the denial case now asserts the *persisted* error detail is redacted, which is stronger. `adapter.__send__(:read)` replaced with a direct `SQLite3::Database` read of the committed `tamoz_effect_transitions` rows — the same durable-file pattern `expire_attempt` already uses; a public adapter read API would be a gem-side seam (`Tamoz::SQLite::Adapter`) and is not needed for the contract.
