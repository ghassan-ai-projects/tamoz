# CF04-REL-01 — failed effect replay loses the current failure after a late success

| Field | Assessment |
| --- | --- |
| Functionality | CF04 model/tool effect identity, journal, unknown outcome, and replay; affected F07 `tamoz-sqlite`, F17 `tamoz-agent-kernel`, and F22 session consumers |
| Severity | **major** — a durable failed effect replays without its failure detail and bypasses the bounded repair path |
| Confidence | **high** — source trace plus an independent temporary-database probe using the public journal and dispatcher |
| Status | **open**; no implementation was made in this audit |
| Scanner signal | Competing attempts: a late success is retained, then an operator resolves the head as `:failed`; dispatcher selects a historical succeeded attempt for the failed replay |
| Independent judgment | **Confirmed**. The sequence is reachable for `:idempotent` effects and produces `status=:failed`, `attempt_number=2`, `reused=true`, `error=nil` |

## Finding and exact trigger

The trigger is an idempotent effect whose first running attempt expires, a new
fenced attempt is granted, that current attempt records a typed failure, and the
old owner later commits success. Recovery grants the second attempt for
`read_only`/`idempotent` effects (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:158-160,203-216`),
while a success from an attempt older than the head changes the head to
`:reconcile` and retains the late receipt (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_completion.rb:153-167`).

An operator can then resolve the reconcile head as `:failed`: `resolve` permits
the `reconcile` head, updates only the head status, and preserves
`requires_reconciliation` for every non-success resolution
(`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb:188-206`). The current
attempt remains attempt 2, whose persisted status is `:failed` and whose error
detail is the repairable `ToolArgumentError`.

On the next dispatch, `prepare` maps a failed head to action `:failed`
(`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:150-160`). The
dispatcher handles that action with `terminal_attempt` and uses its error
(`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:91-101`). That
helper deliberately searches all attempts in reverse for the first succeeded
attempt before falling back to the last attempt
(`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:280-283`). It is
appropriate for a successful replay that needs a late receipt, but it is wrong
for a failed head: the historical attempt 1 success has no error. The resulting
outcome still reports the head's current attempt number and identity through
`recorded_outcome` (`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:162-173`), creating a contradictory
receipt: attempt 2 failed, but its error is absent.

The probe output was:

```text
after_late status=:reconcile current=2 requires=true
after_resolve status=:failed current=2 requires=true
replay status=:failed reused=true error=nil attempt=2
```

The persisted attempts were `[1, :succeeded, nil error]` and
`[2, :failed, ToolArgumentError, repairable=true]`.

## Downstream impact and lens assessment

For a normal session tool step, `SessionSteps#handle_outcome` sends a failed
outcome to `failed_update` (`gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb:213-227`).
The repair branch requires a hash containing `repairable=true`; a nil error
therefore raises a terminal `ToolError` and uses the generic message
`"tool effect failed"` (`gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb:230-243`;
`gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb:183-187`). The
current typed argument failure is not recorded as failure evidence, no bounded
repair attempt is offered, and the graph executor commits a failed checkpoint
with `retryable: false` (`gems/tamoz-graph/lib/tamoz/graph/executor.rb:60-78,382-415`).
Model-call consumers treat any non-success as blocked, so this particular error
loss is most material on the session tool path; direct dispatcher callers also
receive a failed outcome with no diagnostic.

| Lens | Assessment |
| --- | --- |
| Correctness | **Defect confirmed**: failed status, attempt identity, and error describe different attempts. The documented `:failed -> surface the recorded failure` contract is violated (`docs/P6_DURABLE_SESSION_RECOVERY_PLAN.md:440-450`). |
| Security/authority | No authority widening or unapproved execution was found. Fencing, immutable terminal attempt receipts, and operator audit evidence remain active. |
| Reliability/durability | **Major impact**: recovery after a legitimate late-receipt race changes a repairable typed failure into a generic terminal failure. The effect is not re-executed, but the durable behavior is not crash-equivalent. |
| Observability/evidence | Transition history and effect census retain both attempts, but the dispatcher outcome drops the only useful failure detail; session evidence and operator diagnostics are consequently incomplete. |
| Scalability/resource bounds | No separate bound defect: attempt count is capped by `MAX_ATTEMPTS`, and the reverse scan is bounded. |
| Maintenance/architecture | The shared `terminal_attempt` helper conflates “find a succeeded value” with “find the current failed receipt,” making one generic selection policy serve incompatible outcome types. |

## Evidence and test gap

The focused existing tests pass: `ruby -Itest test/sqlite_effect_journal_test.rb -n '/late_old_success|human_resolution/'`
ran 2 tests and 10 assertions; `ruby -Itest test/agent_session_effect_test.rb -n '/reconcilable|unknown_effect/'`
ran 4 tests and 26 assertions. The SQLite test verifies a late success beside a
new **succeeded** head (`test/sqlite_effect_journal_test.rb:316-379`) and human
resolution of an unsafe effect followed by a late failure
(`test/sqlite_effect_journal_test.rb:381-437`); neither creates a late succeeded
attempt beside a current failed attempt and then replays it. Runtime tests cover
a single typed failed receipt, not mixed attempt history
(`test/agent_runtime_effects_test.rb:42-66`). No session-graph regression proves
that a replayed repairable failure reaches `seen_failure_signatures` and the
bounded repair loop.

## Five Whys

1. Why does a failed replay lack its failure detail? The dispatcher selects a prior succeeded attempt.
2. Why does it select that attempt? `terminal_attempt` always prefers any succeeded receipt, regardless of the requested head action.
3. Why is one selector used for both actions? Successful late receipts and failed replays were treated as sharing one terminal-value lookup.
4. Why was the distinction not enforced? The effect record stores attempt history and current-head identity separately, but the dispatcher does not bind receipt selection to the head status.
5. Why did tests miss it? They cover each race outcome separately, not the mixed late-success/current-failure history. The root cause is an incomplete replay contract at the dispatcher boundary: status-specific outcomes need status-specific attempt selection.

## Recommendation and disposition

At `EffectDispatcher#resolve_decision`, make the `:failed` branch read the
current head attempt (`record.current_attempt`) and return that attempt's error,
identity, and number. Keep the succeeded-attempt lookup for `:return`, because a
late succeeded receipt is the value that a successful replay must recover. Add a
regression that drives expiry → attempt 2 repairable failure → late attempt 1
success → human `:failed` resolution, then asserts the replay returns attempt 2’s
error and identity. Add a session-level assertion that the same replay records a
repair failure instead of raising the generic terminal `ToolError`. A separate
test should define the expected behavior when an operator resolves a head as
failed while its current attempt has no persisted error (for example, an
operator-resolved unknown); this audit does not infer that contract.

Historical overlap is limited. P6 documents late receipts and the `:failed`
“surface the recorded failure” rule (`docs/P6_DURABLE_SESSION_RECOVERY_PLAN.md:438-450,552-563`),
but no prior audit report found this mixed-attempt replay defect. The existing
tests above are related coverage, not a resolution.

**Disposition: accept as an open major finding for CF04, with F07/F17/F22 owner follow-up.**
