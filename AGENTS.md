# AGENTS.md — tamoz

Ruby monorepo (see README.md for the component map: tamoz-core, tamoz-agent, tamoz-mcp, tamoz-graph, tamoz-scheduler, tamoz-sqlite, tamoz-stream, tamoz-tools, tamoz-evals).

- Ruby version pinned in `.ruby-version`; gems live in `gems/`, entry points in `apps/` and `bin/`.
- Tests: `test/` (Minitest), run via `rake`.
- Ask before changing cross-gem interfaces; most bugs live at gem boundaries.

<!-- enola:begin -->
## enola — architecture before and after a change

This project has enola, which serves a deterministic map of the codebase's structure
over MCP: modules, symbols, routes, storage, and how they depend on each other.

Before changing code whose blast radius is not obvious:

- `impact_analysis` — what transitively depends on this, before you touch it.
- `explore` / `traverse` / `find_path` — how something is wired, instead of
  reconstructing it by reading files.
- `set_baseline` — pin the architecture BEFORE you start editing, so the change can
  be graded afterwards. Do this once, early.

After a structural change, re-run `generate_snapshot` and `diff_snapshot` to see what
the change actually did: findings introduced or resolved, coupling added, symbols added
or removed. A dependency cycle or unintended coupling is a reason to fix the change
before presenting it, not something to mention afterwards.

Prefer these over re-deriving structure by grepping. They are exact, and they cost a
fraction of the file reading they replace.

enola's hook is installed for this project: at the end of a session it reports the
architectural delta if — and only if — the change introduced a structural regression.
It never blocks, and it stays silent when the change is clean.

It speaks in one other case: when it could not grade the change at all, because the
baseline is not comparable to the current snapshot. That is NOT a verdict about your
change — it means no verdict was reached — and the remedy is to re-pin the baseline.
Said once per cause, not once per session.
<!-- enola:end -->
