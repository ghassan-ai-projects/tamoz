# Git — never rewrite published history

- No `--force` / `--force-with-lease`, on any branch, including your own. A rewritten SHA
  invalidates a reviewer's diff and any CI run against it.
- Amend and rebase freely *before* pushing. Once it is published, correct it with a new
  commit; ask first if a rewrite ever seems genuinely necessary.
