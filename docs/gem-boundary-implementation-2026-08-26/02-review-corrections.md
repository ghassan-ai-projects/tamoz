# Phase 1 review corrections

The five implementation reviews found no extraction semantic regression. The
correction pass closes the packaging, contract-characterization, inventory, and
documentation gaps before commit.

## Deferred baseline findings

The security lane re-confirmed existing live-provider debt in the moved code:
post-read response bounding, incomplete credential scrubbing, ambient proxy
behavior, non-wired live circuit/profile binding, and malformed redirect input.
Those are recorded as a follow-on egress-hardening slice. They are not changed
here because the accepted boundary audit calls for moving the governed adapter
verbatim and explicitly excludes an egress redesign. This phase bar therefore
requires no extraction regression, not a claim that those baseline properties
are already production-complete.

## Corrections applied

- The operator script now loads the four gem libraries explicitly; it does not
  discover repository gems through an ambient glob.
- The websearch package has exact lockstep `tamoz-mcp` and `tamoz-core`
  dependencies, package-content ownership checks, parent constant absence
  checks, and an installed closure/operator-gate subprocess proof.
- Contract tests characterize the result fields, truncation and immutability,
  error ancestry, categories, safe messages, visibility/repairability, nested
  validation, and circuit reset evidence.
- The direct eval harness consumer and its dependency are reflected in the
  gemspec, lockfile, inventories, generated requirements/dependency artifacts,
  public API reference, and component documentation.
- Enola is refreshed after the structural move and the focused boundary,
  packaging, and operator tests are run before the phase commit.
