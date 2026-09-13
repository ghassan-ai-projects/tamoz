# Audit 012 — `test/comms_gateway_test.rb`

Rank 12 · 1114 lines · 2026-09-11 · **Verdict: IMPROVE** (3 minor) · Bar fails: DEAD, TEST, DUP

Strong loop-level coverage marred by leftover debug output, pervasive private-state probing, and a
duplicated graph fixture.

## Findings

- **[minor][DEAD]** Leftover debug scaffolding in the aggregate-status test: two `warn(...)` dumps
  of outbox rows/status plus a verbatim duplicate of the `State: queued` assertion five lines later.
  (comms_gateway_test.rb:513-521)
- **[minor][TEST]** Private-implementation probing: five helpers drive raw SQL through
  `store.__send__(:read)` over internal tables, plus `gateway.instance_variable_get(:@store)` and
  `send(:clarification_reply_reference/:append_control)`. Owning seam: a public store
  read/observable-outbox seam. (comms_gateway_test.rb:127-151, 381, 400-406, 425-431, 526-533,
  795, 959-964)
- **[minor][DUP]** `build_checkpoints` re-declares the `with_gateway` graph definition nearly
  verbatim; one shared graph fixture owns it. (comms_gateway_test.rb:39-45, 968-976)

## Resolution — 2026-09-11

- **[minor][DEAD] fixed.** Removed the two leftover `warn(...)` debug dumps (and the now-unused
  `stx` fetch) plus the verbatim duplicate `State: queued` assertion in the aggregate-status test.
- **[minor][DUP] fixed.** `build_checkpoints` and `with_gateway` re-declared the same single-node
  graph; both now compile `gateway_graph(name)`, which keys the graph and its node
  implementation by name so the two callers stay distinct.
- **[minor][TEST] deferred.** The `store.__send__(:read, raw_sql)` probes and
  `gateway.instance_variable_get(:@store)` need a public CommsStore read/observable-outbox seam
  — the same cross-cutting seam named by 005/037/073/092. Tracked with the CommsStore projection
  work (006) rather than adding one-off raw-SQL replacements here.
