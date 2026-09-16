# F07-REL-01 — bounded request-claim scan can starve a queued resume

| Field | Assessment |
| --- | --- |
| Functionality | F07 `tamoz-sqlite` request inbox; affected flows CF02 and CF06 |
| Severity | **major** — durable liveness failure for an accepted control request |
| Confidence | **high** — source trace plus an independent temporary-database probe |
| Status | **open**; no implementation was made in this audit |
| Scanner signal | Bounded scan left a queued resume behind nine deferred turns |
| Independent judgment | Confirmed at the `DurableRunner` claim boundary; worker-level delivery effects remain partly unmeasured |

## Finding and trigger

`RequestInboxClaimer#candidate_rows` selects nonterminal requests in `enqueue_sequence` order but returns only eight rows (`gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb:216-231`). The transaction then skips a queued `:turn` only when the graph validator returns the intentional early reason, `latest checkpoint is not terminal` (`.../request_inbox_claimer.rb:160-180,183-190`). The comment says this lets a resume behind the turn reach the claim, but the fixed window makes that true only while the resume is inside the first eight rows.

The exact trigger is a nonterminal checkpoint, nine or more queued `:turn` requests admitted behind it, and a valid queued `:resume` after those turns. `RequestStaleness#turn_reason` returns the early reason for each turn (`gems/tamoz-graph/lib/tamoz/graph/request_staleness.rb:14-40`). The first eight rows are therefore skipped and remain queued; the resume is never returned by the query. `DurableRunner#run_next` returns `nil` when no row is returned (`gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb:66-74`). Repeating the call sees the same first eight rows, so the resume remains unclaimable until another state change alters the candidate set. The threshold is strictly more than eight deferred rows before the control request.

This is an intentional deferral policy with an accidental starvation boundary. It preserves accepted turns and prevents them from forking a live graph. The finite scan was intended to bound table work, but no progress or control-request escape rule accompanies it.

## Effects across the path

The worker explicitly gives an open occurrence priority over queued work and waits for that occurrence to settle (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:227-240`). For a paused occurrence, it searches request history for a queued resume targeting that occurrence (`.../worker.rb:289-320`), then calls the same durable runner (`.../worker.rb:301-333`). Thus the worker can correctly discover the resume while the SQLite claimer repeatedly returns no request. The accepted resume is not failed, duplicated, or executed against the wrong checkpoint; it is indefinitely delayed, leaving the thread paused and its occurrence open.

The safety effect is favorable: lease fencing and the shared validator still run, and no authority or effect-journal bypass is shown. The liveness and fairness effects are major: one thread's control action can be held forever by an unbounded backlog of messages it is intentionally deferring. Each retry re-enters the paused settlement path; `settle` accepts a nil request and `settle_paused_view` can project waiting/approval or clarification again (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:635-658,754-777`). Sink deduplication was not exercised, so repeated user-visible notifications are a possible secondary effect, not a confirmed one. There is no distinct claim-deferred/starvation event or age metric, making this state look like ordinary no work.

## Evidence and test gap

The existing focused suite passes: `bundle exec ruby -Itest test/sqlite_stale_request_test.rb` produced 26 runs, 176 assertions, with no failures, errors, or skips. Its early-turn test covers one deferred turn and then a terminal checkpoint (`test/sqlite_stale_request_test.rb:115-149`). Its FIFO wedge test covers stale resumes that terminal-fail and allow later work (`.../sqlite_stale_request_test.rb:235-267`); it does not cover multiple early turns. The worker test covers one queued turn behind one paused occurrence and verifies eventual completion (`test/agent_worker_test.rb:594-630`). The shared predicate test confirms the exact early reason (`test/sqlite_stale_request_test.rb:366-413`). None asserts a backlog larger than the candidate limit, control-request priority, bounded claim progress, or a starvation signal.

An independent no-repository-write probe paused one graph, enqueued nine turns followed by a valid resume, and called `run_next`. It returned `nil`; all ten requests remained `queued`. The source makes repeated starvation deterministic while those first eight rows remain unchanged. The probe did not run the worker loop or inspect a production sink.

## Five Whys

1. **Why did the valid resume not run?** The claimer never returned it to the runner.
2. **Why was it never returned?** The first eight candidates were early turns; the query stopped at `LIMIT 8` and every one was skipped without state change.
3. **Why did skipping not make progress?** The early-turn policy has no bounded-scan fallback for a control request behind the window.
4. **Why is there no fallback?** The policy change treated “more than one row” as sufficient to look behind an early turn while separately optimizing for a bounded scan; it did not define fairness for arbitrary deferred backlog.
5. **Why was that contract missed?** The acceptance tests cover one deferred turn and ordinary stale FIFO, but encode neither the backlog bound nor the requirement that a valid resume must remain reachable. The root cause is an incomplete claim-query progress contract at the existing inbox seam.

## Recommendation and disposition

Keep the lease, one-transaction claim, validator, and early-turn deferral. At `RequestInboxClaimer#candidate_rows` / `claim_request_in_transaction`, make a valid queued control request for the open occurrence visible when the bounded window contains only deferrable early turns. A small two-part candidate read can retain the normal ordered window and add the oldest eligible `:resume` beyond it only in that case; apply the existing validator and fencing to the selected row. Any implementation should confirm the index/query plan. Merely increasing `8` moves the same liveness hole.

Add a regression at `test/sqlite_stale_request_test.rb` with nine early turns plus a valid resume, asserting the resume claims while turns stay queued, then add a worker-level paused-resume check for eventual settlement and notification behavior. A starvation age/reason metric would make future bounded deferrals diagnosable.

Historical overlap is limited. `docs/DR4_STALE_REQUEST_PLAN.md:63-76` establishes claim-time shared validation and deferred stale handling, while `docs/design-v0.1/PERSISTENCE_DESIGN.md:261-262` and `documentation/architecture/data-model.md:36-39` describe claim-next as strict FIFO/no skipped earlier items. Those statements do not document the intentional early-turn exception or its finite-window limit. The 2026-09-11 top-100 audit has no direct request-claimer starvation finding.

**Disposition: accept as an open major finding for F07, with cross-flow follow-up in CF02 and CF06.**
