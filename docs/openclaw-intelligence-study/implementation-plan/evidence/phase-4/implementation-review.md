# Phase 4 implementation review

Date: 2026-08-21
Status: partial; the Phase 4 exit bar and global implementation bar are not met.

## Scope delivered

- Database-shaped MCP sources can be marked operator-owned and pass through a
  read-only policy that rejects write statements, multiple statements, and
  configured query/row limits before MCP invocation.
- Governed websearch has a separate operator-owned source, egress declaration,
  bounded result/circuit policy, and untrusted-content handling; an end-to-end
  browser mission is still outside this slice.
- The policy is wired through `McpSourceBuilder`, so configured database
  servers do not rely on a dead wrapper path.
- Child-task durable records bind their identity to parent/request/task/profile
  content and reject profiles wider than the pinned parent authority, depth, or
  concurrency budget.
- Child tasks now enqueue through the existing request inbox, execute under a
  local-only narrowed toolbox, persist terminal status, and support exactly-once
  digest-bound parent adoption.
- Child bindings and thread authority bindings are immutable after admission;
  worker reconciliation repairs missing requests and settles terminal requests
  left behind by a crash. Recoverable in-flight errors retain the child and open
  occurrence for same-execution recovery.
- Scheduler occurrences are joined to the ordinary request by deterministic
  request identity and move through acknowledgement and terminal completion
  after the graph produces a durable view.
- `delegate_child_task` is now a sealed, approval-required local capability. It
  derives parent thread/request identity from the durable context, intersects
  requested local capabilities with the trusted profile, and enqueues through
  `WorkerRuntime#enqueue_child_task`.
- Candidate-only profile/skill/config proposals now have a small promotion
  value object that resolves an operator-owned artifact, records the existing
  next-boundary transition, and returns `activated: false`; it has no activation
  method or authority-writing path.
- `GovernedBrowserSource` defines the browser adapter boundary, exact HTTPS host
  allowlist, bounded untrusted output, and fail-closed behavior when the
  external adapter is absent.

## Not delivered

- A live browser run remains blocked by the absence of an approved browser
  connector/adapter in this repository; the new source refuses before network
  execution until one is injected.
- Child cross-process restart coverage and the full profile apply/restart/health
  workflow remain outside this minimal wiring slice.
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
6 runs, 17 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_child_task_runtime_test.rb
3 runs, 9 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_worker_test.rb
23 runs, 107 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_schedule_test.rb
8 runs, 61 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_phase4_capability_test.rb
3 runs, 19 assertions, 0 failures, 0 errors, 0 skips
```

These are policy and persistence tests, not evidence that an agent selected or
used a capability safely in a live mission.
