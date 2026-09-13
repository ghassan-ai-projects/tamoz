# Audit 085 — `gems/tamoz-mcp/lib/tamoz/mcp/server_config.rb`

Rank 85 · 474 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: SIZE, STATE

Fail-closed validated value type, but its initializer breaches the hard method ceiling and its
Data.define block leaks twelve pattern constants into the `Tamoz::Mcp` namespace.

## Findings

- **[major][SIZE]** `initialize` runs ~39 body lines over the hard-30 ceiling. Owning seam:
  extract a transport-specific builder. (server_config.rb:113-153)
- **[minor][STATE]** The Data.define block leaks twelve pattern constants into `Tamoz::Mcp`
  (only Budgets is re-homed at 470-472). Owning seam: define the constants on ServerConfig outside
  the block. (server_config.rb:28-57, 470-472)

## Resolution — 2026-09-11 — both findings rejected with evidence

- **[major][SIZE] declined (corrected note).** `initialize` IS over the ceiling
  (MethodLength 22/20, ParameterLists 15/5), silenced as repo-wide debt in
  `.rubocop_todo.yml` (Exclude-listed like 300+ files), so a plain `rubocop` run is green but
  not compliant — the earlier "rubocop clean" wording was wrong. The audit's "~39 lines"
  overcounts (it includes the multi-line signature), but the body is genuinely 2 lines over.
  The 15-param count is the field count of a 14-field Data type plus workspace_root; it is
  intrinsic. The body is a flat, readable sequence of per-field validators feeding `super`
  with no transport-specific sub-builder to extract (every validator applies to all
  transports). Shaving two lines by folding two validators onto one line would not improve
  it; consistent with the accepted repo debt, left as is.
- **[minor][STATE] rejected — the fix conflicts with the repo's enforced style.** The leak
  is real (the pattern constants lexically resolve to `Tamoz::Mcp`), but the only clean
  relocation onto `ServerConfig` is `class ServerConfig < Data.define(...)`, which:
  (1) trips `Style/DataInheritance` ("Don't extend an instance initialized by Data.define;
  use a block") — a cop the repo enables and applies everywhere, and (2) trips
  `Metrics/ClassLength [372/250]` that the block form does not. Re-homing at runtime via
  `const_set` + `remove_const` is exactly the metaprogramming the bar bans. The leaked
  constants are inert internal validation patterns — no external consumer (grep-proven) and
  no collision — and the public `Budgets` is already re-homed. Cost exceeds benefit; kept as
  the original comment documents.
