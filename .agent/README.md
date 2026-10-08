# `.agent/` — rules earned in real sessions

`AGENTS.md` is the entry point; rules needing evidence live here.

- [`rules/testing.md`](rules/testing.md) — tests, time, the `ci` lane, file modes.
- [`rules/git.md`](rules/git.md) — history stays published.
- [`rules/evaluation.md`](rules/evaluation.md) — grading an agent: decisions, not narration.
- [`rules/context.md`](rules/context.md) — the prompt cache is prefix-exact; append, never rewrite.
- [`rules/memory.md`](rules/memory.md) — full-text search, write authority, replay-safe writes.
- [`rules/files.md`](rules/files.md) — one atomic write primitive; what may bypass it.
- [`rules/subgraphs.md`](rules/subgraphs.md) — child effect identity and checkpoint recovery.
- [`rules/adr.md`](rules/adr.md) — ADRs match the code; policy edits are ADR changes.
- [`rules/mcp.md`](rules/mcp.md) — a server being down costs a call, never a session.

Record a rule in the same change that taught it; rewrite any rule it contradicts.
