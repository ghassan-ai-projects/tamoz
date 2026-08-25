# Behavior Changes — tamoz-mcp clean-code refactor

Date: 2026-08-24
Branch: refactor/mcp-clean-code
Worktree: /Users/ghassan/my-projects/tamoz-mcp-refactor

## Summary

No intentional behavior changes were made. Every refactor was an internal extraction or rename of private helpers; public method signatures and return values are unchanged.

## Notes on specific decisions

1. **Public API names preserved.** The subagent analysis suggested renaming `Elicitation.build`, `Elicitation.denial`, and `Elicitation.answer` to more intention-revealing names. These names are part of the documented public API (`docs/public-api.json`, `test/public_api_test.rb`), so the names were kept and only internal helpers were extracted.

2. **`EgressPolicy#operator_authority?` kept as-is.** The predicate name is slightly misleading because it returns the string `"owner"` rather than a boolean, but changing it would break callers. It was left untouched.

3. **Budget accounting in `Invocation.attribute_blocks`.** The extraction into `fit_to_budget` sets `remaining = 0` when a block is truncated, instead of letting `remaining` go negative. This has no observable effect because the loop breaks on `remaining <= 0` and `remaining` is not exposed.

## Verification

- Full test suite: `bundle exec rake test` — 2157 runs, 0 failures, 0 errors, 1 skip.
- RuboCop on all touched files: no offenses.
- enola structural check: PASS — no structural regression.
