# Phase 4 implementation review

Date: 2026-08-21
Status: partial; the Phase 4 exit bar and global implementation bar are not met.

## Scope delivered

- Database-shaped MCP sources can be marked operator-owned and pass through a
  read-only policy that rejects write statements, multiple statements, and
  configured query/row limits before MCP invocation.
- The policy is wired through `McpSourceBuilder`, so configured database
  servers do not rely on a dead wrapper path.
- Child-task durable records bind their identity to parent/request/task/profile
  content and reject profiles wider than the pinned parent authority, depth, or
  concurrency budget.
- Child tasks now enqueue through the existing request inbox, execute under a
  local-only narrowed toolbox, persist terminal status, and support exactly-once
  digest-bound parent adoption.

## Not delivered

- Browser/web egress policy, child cross-process restart coverage, and
  candidate-only self-modification are not implemented.
- Approval/reconciliation and unknown-outcome scenarios for new capability
  families remain unproven.
- No real-provider family run is claimed.

## Verification

```text
/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_governed_database_source_test.rb
2 runs, 7 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_cli_mcp_test.rb
7 runs, 27 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_child_task_test.rb
5 runs, 14 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_child_task_runtime_test.rb
2 runs, 8 assertions, 0 failures, 0 errors, 0 skips
```

These are policy and persistence tests, not evidence that an agent selected or
used a capability safely in a live mission.
