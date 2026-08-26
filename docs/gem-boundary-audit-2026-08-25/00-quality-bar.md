# Audit quality bar

## Scope

The scan covers every directory under `gems/` that has a gemspec and Ruby
library, all gemspec dependency declarations, umbrella entrypoints, direct
`require` statements, production consumers, and relevant architecture/docs
contracts. Tests are read for boundary and public-surface evidence but are not
executed.

## Evidence required for an accepted candidate

An extraction is accepted only when the report can name all of the following:

1. **One responsibility:** the files form a named adapter, contract,
   capability, or runtime with a coherent owner; size alone is insufficient.
2. **A source seam:** the parent require path, namespace, or dependency edge
   shows where the responsibility starts and ends.
3. **Consumers:** direct production consumers and reverse dependents are
   enumerated; test-only references are labelled as such.
4. **Dependency direction:** the proposed gemspec dependencies are one-way,
   with no upward dependency on a caller, CLI, eval harness, or implementation
   detail.
5. **Concrete payoff:** reduced eager load graph, optional external dependency,
   package-truth correction, or independent reuse/release boundary.
6. **Known risk:** public constants and requires, security/authority,
   durability, transaction/migration, event ordering, and documentation impact
   are named explicitly.

Each candidate receives a confidence level:

- **High:** all six items are source-verified and the target graph is obvious.
- **Medium:** the seam is real but naming, public entrypoints, or consumer
  topology needs a design decision.
- **Deferred:** an internal cluster exists, but extraction does not yet buy an
  independent package boundary.

## Stop condition

I stop this audit only when:

- all 24 current gems appear in the inventory;
- declared dependencies and observed entrypoint imports are compared;
- at least three independent reviews cover disjoint gem surfaces;
- every accepted candidate has six-part evidence and a proposed dependency
  direction;
- every high-suspicion rejected split has a documented reason;
- static-tool findings are separated from source-verified conclusions;
- sequencing, gates, risks, and blind spots are written in the report package;
- the documentation-only diff has no whitespace errors.

## Explicit non-goals

- No production code, gemspec, test, fixture, generated artifact, or public page
  is changed by this audit.
- No test, lint, benchmark, install, provider call, or service is run.
- No candidate is promoted merely because a file exceeds 250 lines or because
  Enola calls a symbol a hotspot.
- No compatibility alias is designed as a substitute for a deliberate namespace
  decision; Tamoz's owner convention is no backwards compatibility shims.
