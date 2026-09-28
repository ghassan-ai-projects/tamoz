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
