# ADR-010 — Ruby 3.3 floor; 3.4 and 4.0 primary targets

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Partial — CI runs only the pinned 3.3.11; 3.4 and 4.0 are untested targets

MRI 3.3 is the minimum supported Ruby; 3.4 and 4.0 are the versions Tamoz is meant to run on. CI
tests the exact version in `.ruby-version`.

## Context

Ruby 3.2 reached end of support before the design date, so the floor is 3.3. Separately, the
sealed-build fingerprint binds `RUBY_VERSION` and patchlevel: a floating "3.3" in CI regenerates
committed pins under a different Ruby than the repository's.

## Decision

The supported floor is MRI 3.3. `.ruby-version` pins the development and CI version (3.3.11), and CI
runs exactly that version. 3.4 and 4.0 are intended targets; a version becomes *supported* only when
CI runs the full gate on it. JRuby is out of scope until the SQLite and concurrency adapters pass
without conditional semantics. 3.3 may be dropped after its end of life while Tamoz is pre-1.0.

## Consequences

One exact Ruby keeps sealed-build pins reproducible. **Cost:** nothing proves Tamoz runs on 3.4 or
4.0 today; a user on those versions is on an untested target.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Keep 3.2 as the floor *(retrospective, 2026-10-01)* | It was already past end of support |
| A floating multi-version CI matrix | Regenerates sealed-build pins per version; needs pins keyed by Ruby version first |

## Reopen when

Before the first public release (decide whether 3.4/4.0 enter CI or leave the promise), or when
3.3 reaches end of life.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| CI runs exactly `.ruby-version` | `.github/workflows/ci.yml` | `test/ci_configuration_test.rb` | 3.4 and 4.0 are not exercised anywhere |
