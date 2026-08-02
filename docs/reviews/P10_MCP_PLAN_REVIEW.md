# P10 MCP plan — review

Status: **accepted with the corrections below, which are already applied to
`docs/P10_MCP_PLAN.md`.**

Reviewed against the source-of-truth order: `INVARIANTS.md`, `MCP_DESIGN.md`,
`DECISIONS.md`, the P10 card in `PROJECT_HANDOVER_PLAN.md`, and the time-sensitive
re-check the card mandates.

## Findings and resolutions

1. **Protocol baseline amendment is justified and stays within the design's own rule.**
   `MCP_DESIGN.md` §2 keeps 2025-11-25 as the interoperability baseline "because the
   official Ruby SDK's 2026 multi-round-trip flow is not yet complete enough." The
   re-check (2026-08-02) shows the SDK at v1.1.0 (2026-08-01) supporting 2026-07-28 as
   the latest protocol version, with MRTR `input_required` (v0.24.0, SEP-2322),
   stateless discovery (SEP-2575), and cache hints (SEP-2549). The design explicitly
   allows advertising 2026 "after the selected SDK version implements the required
   features" — it now does. The plan's amendment (2026 preferred, 2025 accepted on
   negotiation) narrows nothing the design forbids and keeps silent out-of-range
   negotiation fail-closed. Sources: [SDK releases](https://github.com/modelcontextprotocol/ruby-sdk/releases),
   [2026-07-28 spec announcement](https://blog.modelcontextprotocol.io/posts/2026-07-28/).
   **Accepted.** If the SDK's stdio MRTR path fails in practice, stop criterion §12.1
   fires and the baseline reverts through a new review.

2. **Dependency boundary.** The `mcp` gem has no runtime dependencies and requires
   Ruby >= 2.7, so `tamoz-mcp`'s boundary (`tamoz-core` + `mcp` only) is achievable.
   The plan correctly forbids a hard `tamoz-agent → tamoz-mcp` dependency and repeats
   the P8-E credential-env rule inside `tamoz-mcp` instead of importing `tamoz-agent`.
   Duplication is deliberate and noted. **Accepted.**

3. **Session-record shape corrected during review.** The first draft pinned one
   `mcp_catalog_digest` STRING; sessions can touch several servers, so the field is now
   `"mcp_catalogs" => HASH` (`{server_id => digest}`, legacy sentinel `{}`,
   `RECORD_VERSION` stays 1), matching the additive-optional-field precedent from P8/P9.
   Applied to §5 and §13.

4. **Effect journal placement.** The plan keeps `tamoz-mcp` free of any journal and
   routes execution through the caller's ordinary `EffectDispatcher`. This preserves
   the "no second engine" rule from P6 and the design's "integration through ordinary
   tool/effect contracts." The v1 taxonomy table correctly refuses automatic retry for
   non-idempotent ambiguous outcomes (effect `:unknown`), which is the same rule D-7
   codified locally. **Accepted.**

5. **Test server honesty.** Using the official SDK for the test server as well as the
   client keeps the wire honest (no hand-rolled JSON-RPC that mirrors Tamoz's own
   assumptions) while staying deterministic for the gate. The server's misbehavior
   modes are driven by environment flags, not by patching the SDK. **Accepted.**

6. **Scope.** P10-D2 (HTTP/OAuth), P10-H (host mode), and full P10-E conformance are
   deferred with explicit entry conditions; the `:http` transport value raises
   `ValidationError` so no half-built HTTP path can be reached. This matches the
   phase's outcome sentence and the P9 precedent of committing to a slice and
   specifying the rest. **Accepted.**

## Residual risks (carried into implementation)

- The SDK's stdio MRTR elicitation path is new (v0.24.0); if it misbehaves, §12.1
  governs.
- JSON Schema 2020-12 validation must be bounded (depth/breadth limits in §10.2
  "schema bomb"); the SDK validates tool *schemas* structurally, but argument
  validation against them is Tamoz's job per the plan.
- The circuit is durable only within the process in v1; cross-restart circuit
  persistence belongs to the scheduler phase and is not claimed.

## Verdict

The plan preserves the source-of-truth order, honors invariants 16–18, 24–27, and
35–37, re-checks the time-sensitive baseline as the card requires, and its deferrals
are specified rather than silent. Implementation may begin under the phase-gate
protocol: adversarial matrix and scorecard case are part of the phase, not follow-ups.
