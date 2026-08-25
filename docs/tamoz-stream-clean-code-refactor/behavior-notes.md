# Behavior notes — tamoz-stream clean-code refactor

Record of any place where cleaner code suggested changing observable behavior.
Either applied deliberately (with rationale) or left as a recommendation.

## 2026-08-25 — approval_relay.rb
- **Applied, cosmetic:** port-validation error text now lists missing methods
  comma-joined ("must implement deliver, edit_in_place") where HEAD used " and "
  ("deliver and edit_in_place"). No test asserts on these messages; raise
  conditions and order are unchanged.
- **Rejected:** simplifying `require_field!`'s empty-check to a single
  `value.to_s` check — it would stop rejecting empty Array/Hash values
  (`[].to_s == "[]"`), an observable change on malformed approval hashes for
  zero readability gain.
- Everything else in the working-tree diff is pure extraction/move; check
  order in `submit_decision`, the public surface, and `escalate` semantics
  are identical to HEAD.

