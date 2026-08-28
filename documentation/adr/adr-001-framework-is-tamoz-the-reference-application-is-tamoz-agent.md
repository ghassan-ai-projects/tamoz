# ADR-001 — The framework is Tamoz; the reference application is Tamoz Agent

**Status:** Accepted 2026-07-30.
**Date:** 2026-07-30

## Decision

Ruby namespace `Tamoz`, CLI `tamoz`, require paths `tamoz/*`, gems prefixed `tamoz-`.
Application-owned code lives under `Tamoz::App`; reusable agent recipes under `Tamoz::Agent`.
The rename was intentionally breaking (no runtime package had shipped); no compatibility
aliases preserve former names.
**Open action:** reserve the exact RubyGems names and record a trademark/domain check before
public release (audit item O2).

## Verification

Verified against code: 2026-08-29 — the `Tamoz::` namespace and `tamoz-*` gem prefix hold across all 27 gems.

## Next reads

- [`README.md`](./README.md) — the ADR catalog
- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — how this ADR is graded
