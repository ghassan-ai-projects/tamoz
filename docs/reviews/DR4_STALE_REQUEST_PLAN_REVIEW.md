# DR-4 stale durable-request fix design review

Verdict: accept-with-required-corrections (revision 2 integrated C1–C6 + duplication
findings).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/DR4_STALE_REQUEST_PLAN.md` revision 1 against the verified fault
chain (compiled.rb, durable_runner.rb, checkpoint_store.rb, cli.rb) and invariants
17/21/23/52–55.

## Findings and dispositions

| # | Sev | Finding | Disposition (rev 2) |
|---|---|---|---|
| C1 | High | "Terminal-fail in the SAME Store transaction as the claim" is false at the stated hook: `claim_next_request` commits its own tx; a kill between claim-commit and terminal-write leaves a claimed request with no outcome forever | Validation callback invoked INSIDE the claim transaction with `(tx, request_row)` before commit; `apply_request_transition_in_transaction!` writes the terminal-fail in the same tx; no window by construction |
| C2 | High | Option-A class rescue unimplementable: `CheckpointConflictError` comes from nine sites in three categories (stale preconditions; the legitimate redirect-wait at 745 that must RETRY; genuine store conflicts that must propagate) | Distinct `StaleRequestError` subclass raised at exactly the four precondition sites (470/527/567/605); A rescues only that subclass; redirect-wait and genuine conflicts propagate |
| C3 | High | Stale-resume-not-paused shape (compiled.rb:527) uncovered — a running/completed checkpoint still carries its interrupts, so the B hook can say "valid" while execute raises | `stale_request_reason` checks (a) status `:paused`, (b) answers match current interrupts (reusing the merge_resume_values predicate), (c) no answer index already in resume_values |
| C4 | High | Enum closed at six ops (turn/resume/retry/continue/fork/redirect), only two covered; `recover_request` bypasses validation | Per-operation validation (default status-precondition for turn/continue/fork); runs in BOTH run_next and recover; queued-but-unclaimed stale requests handled at claim time |
| C5 | Medium | Terminal value format unspecified; `prior_attempt` has no source | Maps onto `failed` status + `terminal_error {graph_status, reason, evidence}`; prior_attempt dropped (execution_id is the attempt-like identity if needed) |
| C6 | Medium | Hook interface underspecified and wrong-owner (agent-supplied no-op hook reinstates the crash) | The graph OWNS the predicate (staleness logic is graph-owned in merge_resume_values); agent supplies nothing |

Duplication findings integrated: ONE `stale_request_reason` predicate (refactored from
merge_resume_values + the retry status check) used by claim-time, B, and A; ONE
`DurableRunner#terminal_fail` helper for all paths; the drain loop's semantics
specified.

## Held-out probes

Stale resume against running/completed (527 path); stale turn/continue/fork;
redirect-wait under a class-based rescue (must never terminal-fail); kill at the claim
seam; recovered stale request (recover path validates); different-input duplicate
(pre-existing, documented out of scope).

## Status

Corrections integrated in `docs/DR4_STALE_REQUEST_PLAN.md` revision 2. Prerequisite
for P15-B's old-session resume claims and the P15-A "D-6 closed" row.
