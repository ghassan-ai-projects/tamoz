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
- Candidate-only profile/skill/config proposals resolve operator-owned
  artifacts, validate narrowed authority, and enter the durable lifecycle
  through exact approval, apply, restart-health verification, activation, and
  rollback stages.
- `GovernedBrowserSource` defines the browser adapter boundary, exact HTTPS host
  allowlist, bounded untrusted output, required allowlisted final-location
  evidence, and fail-closed behavior when the external adapter is absent.
- Commit `1b1cc9b` adds the candidate-only profile/skill/config lifecycle:
  operator-resolved candidate validation, exact human approval digests,
  durable apply, restart/health verification, activation, and rollback with
  typed unknown outcomes. Focused lifecycle coverage is 6 runs/13 assertions;
  the existing improvement candidate suite is 14 runs/284 assertions.
- Commit `b66be46` adds a durable parent-scoped child concurrency reservation
  with CAS retry/release on terminal settlement, revalidates candidate content
  before approval/effect execution, and covers browser redirect/missing-location
  and child-sibling budget failures.

## Not delivered

- A live browser run remains blocked by the absence of an approved browser
  connector/adapter in this repository; the new source refuses before network
  execution until one is injected.
- Child cross-process restart coverage remains outside this slice; the child
  runtime coverage currently proves durable request/adoption and bounded local
  delegation, not a separate process witness.
- Approval/reconciliation and unknown-outcome scenarios for new capability
  families remain unproven.
- The browser source remains an injected adapter seam rather than a live
  connector registration; no network execution is claimed.
- No real-provider family run is claimed.

## Verification

```text
/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_governed_database_source_test.rb
2 runs, 7 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_cli_mcp_test.rb
7 runs, 27 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_child_task_test.rb
8 runs, 23 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_child_task_runtime_test.rb
4 runs, 11 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_worker_test.rb
23 runs, 107 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_schedule_test.rb
8 runs, 61 assertions, 0 failures, 0 errors, 0 skips

/opt/homebrew/bin/rbenv exec bundle exec ruby -Itest test/agent_phase4_capability_test.rb
7 runs, 30 assertions, 0 failures, 0 errors, 0 skips
```

These are policy and persistence tests, not evidence that an agent selected or
used a capability safely in a live mission.
