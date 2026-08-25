# File-by-File Clean-Code Refactor Plan — tamoz-agent-healing

## Scope

Refactor every `.rb` file in `gems/tamoz-agent-healing` in the isolated
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
| 1 | `lib/tamoz/agent/healing/version.rb` | 9 | Review only. |
| 2 | `lib/tamoz/agent_healing.rb` | 24 | Loader — review only. |
| 3 | `lib/tamoz/agent/healing.rb` | 55 | Loader — review only. |
| 4 | `lib/tamoz/agent/healing/remediation/outcome.rb` | 28 | Review only. |
| 5 | `lib/tamoz/agent/healing/remediation/preflight_check.rb` | 28 | Review only. |
| 6 | `lib/tamoz/agent/healing/promotion_gate.rb` | 54 | Direct analysis. |
| 7 | `lib/tamoz/agent/healing/remediation/compensation_flow.rb` | 55 | Direct analysis. |
| 8 | `lib/tamoz/agent/healing/scope.rb` | 55 | Direct analysis. |
| 9 | `lib/tamoz/agent/healing/remediation/attempt_evidence.rb` | 56 | Direct analysis. |
| 10 | `lib/tamoz/agent/healing/effect_identity.rb` | 68 | Direct analysis. |
| 11 | `lib/tamoz/agent/healing/remediation/effect_execution.rb` | 72 | Direct analysis. |
| 12 | `lib/tamoz/agent/healing/remediation/escalation_payload.rb` | 79 | Direct analysis. |
| 13 | `lib/tamoz/agent/healing/remediation/plan_builder.rb` | 80 | Direct analysis. |
| 14 | `lib/tamoz/agent/healing/remediation/plan_review.rb` | 84 | Direct analysis. |
| 15 | `lib/tamoz/agent/healing/classification/legacy_text_adapter.rb` | 94 | Direct analysis. |
| 16 | `lib/tamoz/agent/healing/remediation.rb` | 112 | Direct analysis. |
| 17 | `lib/tamoz/agent/healing/oracle.rb` | 117 | Direct analysis. |
| 18 | `lib/tamoz/agent/healing/classification/matrix.rb` | 122 | Direct analysis. |
| 19 | `lib/tamoz/agent/healing/errors.rb` | 158 | Direct analysis. |
| 20 | `lib/tamoz/agent/healing/rule_registry.rb` | 183 | Direct analysis. |
| 21 | `lib/tamoz/agent/healing/seams.rb` | 183 | Direct analysis. |
| 22 | `lib/tamoz/agent/healing/preflight.rb` | 213 | Subagent candidates + refactor. |
| 23 | `lib/tamoz/agent/healing/classification.rb` | 259 | Subagent candidates + refactor. |
| 24 | `lib/tamoz/agent/healing/remediation/session.rb` | 249 | Subagent candidates + refactor. |
| 25 | `lib/tamoz/agent/healing/failure_record.rb` | 384 | Subagent candidates + refactor. |
| 26 | `lib/tamoz/agent/healing/rule.rb` | 502 | Subagent candidates + two-pass refactor. |

## End-state validation

After all files are processed:

1. Run the test suite for the gem.
2. Run `rubocop` on `gems/tamoz-agent-healing` and fix any remaining issues.
3. Run `enola check` and compare against the pinned baseline.
4. Ensure `progress.md` shows every file ticked.
5. Push the branch and refresh the PR.

## Notes

- No cross-gem interface changes are planned. If one becomes necessary, it will
  be flagged in `behavior_changes.md` and approved before committing.
- Test files are out of scope; we only refactor library source files.
- Comments are removed or rewritten only to match the new structure; no
  explanatory comments are added unless they capture a non-obvious “why”.
