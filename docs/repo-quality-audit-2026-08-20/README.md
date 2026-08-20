# Tamoz repository quality audit — 2026-08-20

This folder contains a repo-wide software-quality audit across the Ruby monorepo.

The audit covers `gems/`, `apps/`, `bin/`, `script/`, `test/`, repository configuration, and relevant documentation/contracts. Generated files, fixtures, and tests are classified explicitly rather than silently treated as hand-maintained production code.

Seven independent passes are included:

1. code quality
2. duplication
3. dead code
4. missing abstractions
5. incorrect use of existing code
6. code placement and gem boundaries
7. patterns and pattern usage

Reports:

- [`code-quality.md`](code-quality.md)
- [`duplication.md`](duplication.md)
- [`dead-code.md`](dead-code.md)
- [`missing-abstractions.md`](missing-abstractions.md)
- [`incorrect-existing-usage.md`](incorrect-existing-usage.md)
- [`gem-boundaries.md`](gem-boundaries.md)
- [`patterns.md`](patterns.md)

Six passes were delegated to repository sub-agents. The seventh pass (patterns)
was completed in the main thread because only six sub-agent slots were
available. Every pass used the same full-repository component checklist and
continued until it had recorded coverage and blind spots. Findings are tied to
code, callers, tests, or executable quality signals; they are not based on file
size alone. No production or test code was changed as part of the audit.

The consolidated report is `REPORT.md`.
