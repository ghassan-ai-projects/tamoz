# tamoz-scheduler

Durable scheduling for Tamoz: validated Schedule/Occurrence values, the
structural `ScheduleStore` contract, and (via `tamoz-sqlite`) an atomic
`materialize_due` that claims → creates → enqueues one logical occurrence per
recurrence into the ordinary durable request inbox.

```ruby
require "tamoz/scheduler"

schedule = Tamoz::Scheduler::Schedule.new(
  id: "daily-summary", owner: "human:operator",
  kind: :interval, expression: "3600",
  start_at: 1_700_000_000,
  payload_ref: "sha256:…",
  thread_policy: "thread.scheduler",
  capability_grant: {"scopes" => ["read"]},
  behavior_version: "tamoz.agent.session/1",
  approval_policy: {"mode" => "deterministic", "risk" => "read_only"},
  delivery_policy: {"mode" => "inbox"},
  budgets: {"max_steps" => 10},
  created_by: "human:operator",
  created_at: 1_700_000_000
)
```

## v1 scope

- Kinds: `at` (one-shot UTC instant) and `interval` (elapsed-time cadence from
  an explicit anchor). `cron` (IANA + DST) is a recorded deferral with entry
  conditions in `docs/P13_SCHEDULER_PLAN.md` §12.
- The gem never executes agent logic, approves actions, retries effects, or
  reports delivery as execution success.
