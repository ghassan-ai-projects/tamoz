# Gem-boundary implementation bar

## Scope

This branch implements the accepted extraction sequence from the 2026-08-25
audit, one gem at a time. The first slice is `tamoz-mcp-websearch`; the next
slice is `tamoz-evals-runner`. Each slice is independently reviewed and
committed before the next slice starts.

## Phase bar: `tamoz-mcp-websearch`

The phase is complete only when every item below is true:

- [x] The four existing websearch implementation files move without semantic
      simplification, retaining `Tamoz::Mcp::Websearch` and its public error,
      policy, client, circuit, and result contracts.
- [x] `tamoz-mcp-websearch` has a valid gemspec, version, README, LICENSE,
      explicit one-way dependency metadata, and a package that contains the
      moved runtime files but not the parent gem's copy.
- [x] `tamoz-mcp` remains loadable without `websearch`, `net/http`, or the new
      package; the new gem declares exact lockstep runtime dependencies on
      `tamoz-mcp` and `tamoz-core`, and nothing upward.
- [x] The operator script uses the new package explicitly; the direct
      `tamoz-evals` consumer and its runtime dependency are documented. The root Gemfile, lockfile,
      gem inventory, install documentation, public API inventory, requirements
      inputs, and dependency review agree with the new gem count.
- [x] Existing websearch tests pass unchanged or with only load-path ownership
      updates. They still cover SSRF/allowlist and per-hop pinning, redirects,
      credential hygiene, bounded bytes, circuit opening/reset authority, MCP
      invocation, and operator adapter behavior.
- [x] New isolation/packaging assertions prove the parent/new-gem boundary in a
      clean subprocess or installed package, not only in the monorepo bundle.
- [x] The focused test suite, targeted RuboCop, Enola architecture check, and
      relevant documentation/dependency gates are green, with pre-existing
      unrelated failures listed separately rather than hidden. Reek exits
      successfully but remains an advisory raw report because the repository
      has not yet baselined its existing smells; this slice adds no new Reek
      configuration or claimed smell cleanup.
- [x] Five independent read-only review lanes report PASS or their findings are
      fixed by the same implementation agent: security/egress, authority/error
      contracts, package isolation, operator/eval behavior, and
      documentation/API. Each report names inspected paths and severity; no
      P0/P1 extraction regression remains. Pre-existing live-provider security
      debt is recorded and explicitly deferred because this slice is a verbatim
      boundary move, not an egress redesign.

Evidence for the completed phase: the websearch-focused suites pass; the
contract suite is 4 runs/52 assertions; dependency isolation is 19 runs/206
assertions; packaging is 12 runs/586 assertions; public API is 3 runs/1,048
assertions; the requirements audit has 493 passing direct cases and 15
pre-existing missing rows; Reek exits successfully with its existing raw
report; and Enola reports `PASS — no structural regression`.

## Phase bar: `tamoz-evals-runner`

Before starting Phase 2, freeze a separate bar. It must preserve verifier API,
artifact bytes, digest rules, decisions, exit codes, evidence labels,
subprocess isolation, executable behavior, and the explicit runner dependency
closure while allowing the base verifier to load without runtime gems.

## Stop rules

Do not rename public namespaces, add compatibility aliases, redesign egress
policy, simplify moved code, or combine deferred candidates into either phase.
If a review finds that the proposed boundary cannot meet this bar without a
contract decision, stop that phase and record the blocker instead of lowering
the bar. Existing websearch behavior, including known live-provider baseline
debt, is not redesigned as part of this packaging slice.
