# Documentation Review Audit

Date: 2026-08-13  
Branch: `docs/open-source-documentation`  
Base: `main`  
Scope: committed branch changes plus the documentation surface currently present in the working tree.

## Executive summary

The documentation tree is structurally healthy: relative links resolve, public documentation files are reachable from the index, substantive-page checks pass, and the focused documentation consistency tests are green.

No P0 findings were identified. The main risks are documentation drift and an unclear boundary between the curated public set under `documentation/` and the internal archive under `docs/`.

## Findings

### P1 — `ci_full` documentation does not match the Rake task

The public documentation describes `ci_full` as the complete gate. The Rake task runs `design:validate`, `syntax`, `test`, and `test_slow`, but does not directly include `stream:proto:check` or `quality:architecture`, even though those are part of `ci` and are described as required quality checks.

Evidence:

- `Rakefile:387-400`
- `CONTRIBUTING.md:33-42`
- `documentation/governance/quality.md:12-27`
- `documentation/guides/evaluation.md:61-66`

Recommendation: either make `ci_full` depend on the complete intended gate or describe its exact dependency set and list the additional required checks separately.

### P1 — Public pages depend on the internal `docs/` archive

`docs/README.md` explicitly defines `docs/` as an internal working archive, but multiple public pages link directly into it. This makes the public documentation boundary unclear and makes the curated set fragile when copied, packaged, or mirrored without the repository archive.

Examples:

- `documentation/adr/README.md`
- `documentation/design/README.md`
- `documentation/reference/public-api.md`
- `documentation/guides/agent-operator.md`
- `documentation/limitations.md`

Recommendation: publish stable public counterparts for reader-facing material, or label these links explicitly as repository-internal implementation sources and keep them out of normal user journeys.

### P1 — Telegram guidance is duplicated across public pages

Telegram setup and operations appear in the root `README.md`, `documentation/getting-started/install.md`, `documentation/guides/agent-operator.md`, and `documentation/guides/telegram.md`. The overlap includes configuration, gateway startup, approvals, and troubleshooting.

Recommendation: make `documentation/guides/telegram.md` the canonical walkthrough. Keep the other pages to a short prerequisite or pointer section.

### P1 — ADR index is not navigable at the individual-decision level

`documentation/adr/README.md` catalogs ADR-001 through ADR-049, but most entries do not link to their rationale. Readers must search large internal design documents to find the decision text.

Recommendation: add stable public decision pages or deep links where the source format permits them. If that is intentionally out of scope, rename the page description to make clear that it is a status catalog rather than a navigable ADR index.

### P2 — Incorrect semantic label for the repository-root link

`documentation/overview/product.md` labels `../README.md` as “the repository entry point.” From that file, the target resolves to `documentation/README.md`, not the repository-root `README.md`.

Recommendation: change the target to `../../README.md`, or relabel it as the documentation home.

### P2 — “Value in ten minutes” remains in navigation copy

The quickstart correctly warns that installation, native builds, and a gate run take time, but `documentation/README.md` and `documentation/overview/product.md` still describe it as “value in ten minutes.”

Recommendation: use neutral wording such as “quickstart — install, ask, and try an approved change.”

### P2 — Internal phase vocabulary remains in public documentation

Public pages still expose implementation-specific labels such as `P3`, `P14`, `DR-2`, and `MIGRATION_13`. These labels are useful in the internal archive but are not consistently meaningful to public readers.

Examples:

- `documentation/overview/concepts.md`
- `documentation/overview/compatibility.md`
- `documentation/limitations.md`
- `documentation/roadmap.md`

Recommendation: lead with the public capability or limitation, and retain the internal phase/ migration identifier only when it provides useful traceability.

## Verification performed

Commands run from the repository root:

```text
rbenv exec bundle exec rake docs:check
```

Result: 7 runs, 1068 assertions, 0 failures, 0 errors, 0 skips.

```text
rbenv exec bundle exec ruby -Itest test/documentation_surface_test.rb test/comms_adr049_consistency_test.rb
```

Result: 9 runs, 89 assertions, 0 failures, 0 errors, 0 skips.

```text
git diff --check main...HEAD
```

Result: clean.

## Working-tree note

The pre-existing `docs/STREAM_WORKER_IMPLEMENTATION_AUDIT_2026-08-12.md` was not modified by this review.
