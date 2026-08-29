# docs/ — internal working archive

This directory is the project's **internal working archive**, not the public
documentation set. It holds phase plans, design reviews, audit reports,
machine-generated evidence artifacts, and the authoritative design package
`design-v0.1/` (validated by `rake design:validate`).

The curated public documentation lives in
[`documentation/`](../documentation/README.md). Start there for anything
user-facing — installing, running, operating, or understanding Tamoz.

This archive is not a current status board. Dated plans, reviews, and audits
record decisions at the time they were written; verify present behavior against
the source, tests, and the curated documentation before acting on them.

## What stays here

| Area | Examples |
|---|---|
| Phase plans and working slices | `P*_PLAN.md`, `M*_PLAN.md`, `DR*_PLAN.md` |
| Reviews and corrections | `reviews/`, `reviews/codebase-review-2026-08/` |
| Audits and investigation logs | `REQUIREMENTS_AUDIT.md`, `GRAPH_SURFACE_AUDIT.md`, `GAUNTLET_PROGRESS.md`; latency evidence is in `documentation/operations/ux-latency-investigation/` |
| Canonical benchmark contracts | `documentation/benchmark/` (migrated because scripts and tests consume these protocols and scenario indices) |
| Gem-boundary audits | `gem-boundary-audit-2026-08-25/` |
| Gem-boundary implementation | `gem-boundary-implementation-2026-08-26/` |
| Machine evidence | `requirements-manifest.json`, `requirements-audit.json`, `public-api.json`, `autonomy-scorecard.json`, `benchmark.json`, `code-quality-baseline.json`, `dependency-review.json`, `release-*.json` |
| Authoritative design package | `design-v0.1/` (CI-validated, see `rake design:validate`) |
| Quality program records | `QUALITY_PROGRAM.md`, `QUALITY_PROGRAM_STATE.md`, `CODING_STANDARD.md` |

## Policy

- **New public documentation goes in `documentation/`**, organized by topic and
  reachable from its index. Do not add user-facing pages here.
- **Working artifacts stay here.** Plans, reviews, audits and evidence are the
  project's history; they are not rewritten for a public audience. Canonical
  contracts consumed by scripts or tests belong in `documentation/` and are
  linked from its index.
- Cross-gem interfaces and behavioral contracts are governed by
  `design-v0.1/INVARIANTS.md` and the authoritative ADR catalog in
  `documentation/adr/`.
