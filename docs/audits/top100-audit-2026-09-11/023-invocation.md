# Audit 023 — `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb`

Rank 23 · 769 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: SIZE, DEAD, FX

Disciplined typed-outcome pipeline with correct error taxonomy, but oversized parameter lists, a
no-op strictifier branch, and a private-SDK `send` need tightening.

## Findings

- **[minor][SIZE]** `call` (7 params), `reissue` (10), and `round_trip` (8 keywords) all exceed the
  5-param ceiling. Owning seam: a per-invocation channel/context value.
  (invocation.rb:84-124, 363)
- **[minor][DEAD]** `strict_schema`'s root `additionalProperties` merge re-applies what
  `deep_strictify` already injected under the identical `strictable_object?` predicate — a no-op
  branch. (invocation.rb:239-246)
- **[minor][FX]** `resume_tool` drives the SDK's private `request` via `client.send(:request, ...)`;
  the MRTR reissue path silently breaks on a gem bump. Owning seam: a versioned adapter over
  `MCP::Client` in tamoz-mcp. (invocation.rb:421-433)

## Resolution — 2026-09-12

- **[minor][DEAD] fixed.** The root `additionalProperties` re-merge in `strict_schema` is
  deleted — `deep_strictify` already injects the default-deny at the root under the same
  `strictable_object?` predicate. The root deny stays pinned by
  `test_unknown_property_is_rejected_with_no_io` (test/mcp_invocation_test.rb:210); the
  `output_schema:` literals at :615/:644 do not route through `strict_schema`.
- **[minor][SIZE] open.** Per-invocation channel/context value for `call`/`reissue`/
  `round_trip` still to do.
- **[minor][FX] open.** Versioned adapter over the SDK's private `request` still to do.
