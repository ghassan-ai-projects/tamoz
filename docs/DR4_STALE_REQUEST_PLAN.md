# DR-4 — Stale durable-request framework fix (D-6 and the `:retry` latent defect)

Status: design round — revision 2 (deep review ACCEPT-WITH-REQUIRED-CORRECTIONS on
revision 1; C1–C6 + duplication findings integrated; see
`docs/reviews/DR4_STALE_REQUEST_PLAN_REVIEW.md`)
Origin: gauntlet ledger §5.2 (D-6) and §5.7 (`:retry`). Verified fault chain:
`merge_resume_values` raises `InvalidUpdateError` at compiled.rb:925/933/938/945/954
(the stale-relevant raise 938 "does not match an outstanding task/call index");
`retry_failed_with_writer` raises `CheckpointConflictError` at compiled.rb:567
("latest checkpoint is not failed"); `resume_with_writer` raises at compiled.rb:527
("latest checkpoint is not paused") BEFORE merge is reached whenever the thread moved
to running/completed — the D-6 scenario produces BOTH classes depending on where the
thread landed; `run_next` (durable_runner.rb:56-87) has no rescue; `claim_next_request`
claims only `queued` — a crashed-claimed request is never claimable again (it wedges
the queue; only `recover_request` re-executes it, with NO validation).
Authoritative inputs: invariants 17, 21, 23, 52–55; compiled.rb, durable_runner.rb,
checkpoint_store.rb, cli.rb.

## 1. Problem (corrected)

A stale durable request — claimed after its dispatch context became invalid — must fail
as a **terminal request value**, never take the thread down, never be silently
re-claimed. Verified failure modes:

1. stale resume against a **paused checkpoint with different interrupt generation** →
   `InvalidUpdateError` (compiled.rb:938);
2. stale resume against a **running/completed checkpoint** → `CheckpointConflictError`
   (compiled.rb:527) — NOT covered by an InvalidUpdateError-focused fix;
3. retry of a not-`:failed` target → `CheckpointConflictError` (compiled.rb:567);
4. stale `:turn`/`:continue`/`:fork` (compiled.rb:470/605/821) — same latent shape;
5. `recover_request` (durable_runner.rb:90-120) calls `execute_durable_request` with NO
   validation — a recovered stale claimed request re-crashes.

## 2. Requirement (unchanged)

A stale request fails as a terminal request value — recorded, idempotent, never
re-claimable — without taking the thread down; the CLI renders it as a typed outcome.
A stale request is never retried.

## 3. Design (corrected)

**Claim-time validation IN the claim transaction (C1 — the central fix).** The plan's
"same transaction as the claim" was unachievable at the run_next hook (claim commits
its own transaction before the hook runs; a kill between claim-commit and terminal-
write leaves a claimed request with no outcome forever). Fixed: `claim_next_request`
takes a **validation callback invoked with `(tx, request_row)` before commit**; on
stale, `apply_request_transition_in_transaction!` (which already permits a `claimed`
request to become `failed`) writes the terminal-fail IN THE SAME TX. There is no window:
a claimed request always carries its outcome.

**Typed staleness (C2 — the rescue boundary).** `CheckpointConflictError` is raised
from nine sites in three categories (stale preconditions at 470/527/567/605/910;
a LEGITIMATE wait condition that must retry — the redirect-wait at 745; genuine store
conflicts that must propagate — append_checkpoint/advance-commit/lease-loss). A class-
based rescue is impossible. Fixed: `Compiled` raises a distinct **`StaleRequestError`**
subclass at the four precondition sites (470/527/567/605); the rescue boundary (Option
A) rescues ONLY that subclass (drift backstop) — genuine conflicts and the redirect-
wait propagate untouched. A stale redirect-wait abort must NEVER terminal-fail.

**Per-operation validation, shared predicate (C3/C4/D1/D2).** One
`stale_request_reason(checkpoint, request)` predicate in `Compiled` (refactored from
`merge_resume_values`' task/call-index matching + the 954 pre-merge check + the retry
status check):
- `:resume` → (a) checkpoint status `:paused`, (b) answers' task/call indices match the
  current interrupts, (c) no answer index already present in `checkpoint.resume_values`;
- `:retry` → target checkpoint still `:failed`;
- `:turn`/`:continue`/`:fork` → status-precondition (thread state) check;
- `:redirect` → NOT validated (its wait condition is legitimate).
The validation runs at CLAIM time (in the claim transaction) AND in BOTH execution
paths: `run_next` AND `recover_request` (C4). Queued-but-unclaimed stale requests are
handled at claim time (each is claimed FIFO, validated, terminal-failed) — not
proactively cleared; a wedging stale request unblocks when claimed.

**One terminal-fail helper (D2):** `DurableRunner#terminal_fail(request, reason:,
evidence:)` — the single write path used by claim-time validation, the A backstop, and
both execution paths.

**Terminal value format (C5):** maps onto the existing status model —
`status: "failed"` + `terminal_error: {"graph_status" => "failed", "reason" => ...,
"evidence" => ...}`; `failed` is excluded from claim and `RequestRecord.terminal?`
includes it. `prior_attempt` is dropped (requests have no attempt_id; the request's own
`execution_id` is the attempt-like identity if needed downstream).

**Hook ownership (C6):** the graph OWNS the predicate (staleness logic is already
graph-owned in `merge_resume_values`); the agent supplies nothing. No no-op hook, no
"forgotten hook" failure mode.

**CLI rendering (D3):** `run_next` returning a terminal-failed request is rendered by
`drain_to_terminal` from the returned request's `terminal_error` (typed reason line);
the drain loop's "advance any queued request first" idiom and the rendering agree on
one meaning.

## 4. Failure model

| Situation | Type | Behavior |
|---|---|---|
| stale request at claim/execute/recover | `StaleRequestError` (typed; D-7 value mapping: repairable? NO — terminal value) | terminal-fail with reason + evidence; thread continues; never re-claimed |
| redirect-wait condition | existing wait semantics | retried/waited, NEVER terminal-failed (asserted) |
| genuine store conflict (append/commit/lease) | `CheckpointConflictError`/`LeaseLostError` | propagate (invariant 17 list unchanged) |
| duplicate delivery, identical input | existing `enqueue_request` idempotency | prior outcome returned |
| duplicate delivery, different input | `CheckpointConflictError` at enqueue (pre-existing) | unchanged; documented, out of scope |

## 5. Tests (DR-4 acceptance, revised)

- F1 exact D-6 repros in BOTH shapes: stale resume against paused-different-generation
  (InvalidUpdateError path) AND against running/completed (527 path) → terminal value,
  no crash, not re-claimable, duplicate delivery returns the prior outcome (identical
  input).
- F2 `:retry` repro → terminal value, no crash.
- F3 claim-time atomicity: validation + terminal-fail in the SAME claim transaction
  (kill between claim-commit and terminal-write impossible by construction — one tx);
  asserted by a kill-injection test at the claim boundary.
- F4 propagation preserved: genuine corruption/lease-loss/append conflicts propagate;
  the redirect-wait retries, never terminal-fails (P3).
- F5 kill matrix: kill at claim/validate/terminal-write seams → terminal state recorded
  exactly once.
- F6 CLI rendering: typed reason rendered from `terminal_error`; drain loop exits
  cleanly; stale `:turn`/`:continue`/`:fork` covered (P2); recovered stale request
  covered (P5 — recover path validates).

## 6. Consuming phases

Framework surgery on the P6/P7 runtime; closes before P15-B (old-session resume
claims); prerequisite for the P15-A row "D-6 closed". No dependency on P11–P14;
scheduled as its own reviewed round once the P10 slice-3 close frees the coordinator
(it touches compiled.rb/durable_runner.rb/checkpoint_store.rb, which P10 slices do not).

## 7. Review checklist (re-review)

1. Is the claim-time validation callback implementable on `claim_next_request`'s
   transaction without a second lease path (read-only on tamoz_checkpoints)?
2. Does the `StaleRequestError` subclass cover exactly the four precondition sites and
   nothing else (the redirect-wait at 745 and genuine conflicts remain
   CheckpointConflictError)?
3. Does the shared `stale_request_reason` predicate serve claim-time AND both
   execution paths without drift?
4. Does `terminal_fail` via `apply_request_transition_in_transaction!` exist and fit
   the failed-status + terminal_error format?
5. Do F1–F6 catch the six deep-review probes (stale-resume-not-paused, stale
   turn/continue/fork, redirect-wait under class rescue, kill at claim seam, recover
   path bypass, different-input duplicate)?
