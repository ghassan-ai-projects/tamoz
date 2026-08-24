# File-by-File Clean-Code Refactor Plan — tamoz-agent-capabilities

## Scope

Refactor every `.rb` file in `gems/tamoz-agent-capabilities` in the isolated
worktree `/Users/ghassan/my-projects/tamoz-agent-gems-refactor`, branch
`refactor/agent-gems-clean-code`.

## Principles (the quality bar)

1. A function name states its intent.
2. A function is short and does one thing.
3. A function stays at one level of abstraction.
4. Public, top-level functions read like a small domain-specific language.
5. Each function calls functions one level below it, stepping down until the
   remaining operations are small and concrete.

## Per-file loop

For every file:

1. **Read** the file and note its public contract.
2. **Get candidates** — use a subagent for files >200 lines; analyse directly
   for smaller files.
3. **Refactor** the file with minimal, behavior-preserving changes.
4. **Review** with `rubocop` and a second read; fix any new warnings.
5. **Commit** with a message naming the file.
6. **Check the bar** by ticking the file off in `progress.md`.

Any behavior change that makes the code cleaner must be recorded in
`behavior_changes.md` before the commit.

## File order

| # | File | Lines | Strategy |
|---|------|-------|----------|
| 1 | `lib/tamoz/agent/capabilities/version.rb` | 9 | Review only. |
| 2 | `lib/tamoz/agent_capabilities.rb` | 31 | Loader — review only. |
| 3 | `lib/tamoz/agent/governed_database_source.rb` | 96 | Direct analysis. |
| 4 | `lib/tamoz/agent/child_task_dispatcher.rb` | 155 | Direct analysis. |
| 5 | `lib/tamoz/agent/governed_browser_source.rb` | 168 | Direct analysis. |
| 6 | `lib/tamoz/agent/mcp_capability_source.rb` | 263 | Subagent candidates + refactor. |
| 7 | `lib/tamoz/agent/child_task.rb` | 271 | Subagent candidates + refactor. |
| 8 | `lib/tamoz/agent/mcp_source_builder.rb` | 276 | Subagent candidates + refactor. |
| 9 | `lib/tamoz/agent/capability_binding.rb` | 402 | Subagent candidates + two-pass refactor. |

## End-state validation

After all files are processed:

1. Run the test suite for `tamoz-agent-capabilities`.
2. Run `rubocop` on the gem and fix any remaining issues.
3. Run `enola check` and compare against the pinned baseline.
4. Ensure `progress.md` shows every file ticked.
5. Push the branch and refresh the PR.

## Notes

- No cross-gem interface changes are planned. If one becomes necessary, it will
  be flagged in `behavior_changes.md` and approved before committing.
- Test files are out of scope; we only refactor library source files.
- Comments are removed or rewritten only to match the new structure; no
  explanatory comments are added unless they capture a non-obvious “why”.
