# Memory — search, authority, replay

- **SQLite's `porter` tokenizer stems a prefix query differently from the indexed word.**
  `deployment` indexes as `deploy`, but the query `"deploy"*` stems to `deploi*` and matches
  nothing. `tamoz_memory_fts` uses `unicode61`; the query side strips one common suffix and
  prefix-matches words of four letters or more (`MemoryStore.query_token`).
- **Never `return` out of a Store `open_transaction` block.** The non-local exit leaves the
  connection in a state where the *next* statement fails with a bare
  `SQLite3::SQLException` that names neither cause. Assign inside the block, return after it.
- **A write's authority must be structural, and narrow.** "The quote is a substring of a user
  message" was not enough: a clause cut from "never deploy on Fridays" reverses it, an
  unrelated eight-byte quote could `forget` anything, and a child task's text is written by a
  model. Quotes are whole clauses, `forget` must name its target, children get no memory.
- **Tool writes outside the effect journal must be idempotent.** A superstep can replay; the
  same `remember` returns the existing record and a repeated `forget` reports `already`.
- **Materialize an FTS5 match before joining it.** Joined directly to `tamoz_memory_index`,
  SQLite ran `MATCH` once per candidate row: 26 s per search at 10,000 records. A
  `WITH fts AS MATERIALIZED (...)` runs it once: 21 ms. Re-check with
  `docs/memory-next-level-2026-09-28/probes/bench_scale.rb` after touching the search SQL.
- **Outside the memory gem, use `Memory::Access` only.** The first CLI and work-route code
  read repository rows, the store namespace, and record scopes directly, and each re-implemented
  "who may see this record" — three copies of an authorization rule. `engine.access(owner:,
  workspace:)` owns scopes and visibility; `test/memory_boundary_test.rb` fails on a leak.
