# ADR-040 — One monorepo, multiple independently publishable gems

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete
**Amended by:** [ADR-055](./adr-055-two-repo-authority-split.md) (the Go continuous plane is a second repository)
**Relates to:** [ADR-052](./adr-052-a-gem-owns-one-dependency-boundary-and-is-reached-only-through-its-facade.md) (when a concern becomes a gem)

Framework gems, Tamoz Agent, conformance fixtures, examples, and release tooling live in one
repository. Each gem has its own manifest and dependency boundary and packages on its own. Being in
the same repository grants no runtime dependency.

## Context

Separate repositories from the first commit multiply cross-repo changes, CI, fixtures, and release
coordination before ownership or release cadence has diverged. But one repository tempts gems to
reach into each other because the code is right there.

## Decision

- One repository for all Ruby gems and the reference application.
- Each gem declares its runtime dependencies in its gemspec and loads only those; a gem that
  `require`s another must declare it. Packaging each gem alone must work.
- Before 1.0, releases coordinate through one compatibility matrix, and versions change only for
  affected gems.
- A component in another language with its own release cadence may live in its own repository
  (ADR-055 is the one case).

## Consequences

Cross-gem changes land atomically with their tests. **Cost:** CI and tooling must check per-gem
dependency closure, because the repository will not stop an undeclared `require`.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| A repository per gem from the start | Multiplies coordination before ownership diverged |
| One gem for everything *(retrospective, 2026-10-01)* | No dependency boundary; the graph engine would load agent and provider code |

## Reopen when

Two gems need different owners or release cadences that one repository's CI cannot serve.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Each gem loads only its declared closure | gemspecs | `test/dependency_isolation_test.rb` | Covers the gems listed in that test |
| Each gem packages and runs from its release files alone | packaging | `test/packaging_test.rb` — `test_every_gem_is_strict_valid_and_contains_only_release_files` | — |
