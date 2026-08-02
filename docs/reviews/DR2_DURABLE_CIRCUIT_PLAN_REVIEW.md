# DR-2 durable circuit design review

Verdict: accept-with-required-corrections (revision 2 integrated C1–C10).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/DR2_DURABLE_CIRCUIT_PLAN.md` revision 1 against
`SELF_HEALING_DESIGN.md` §10, `SCHEDULER_DESIGN.md` §10, `P10_MCP_PLAN.md` §8, the
Store CAS machinery, StateCodec constraints, and the landed P10 supervisor circuit.

## Findings and dispositions

| # | Sev | Finding | Disposition (rev 2) |
|---|---|---|---|
| C1 | High | Open transition not crash-atomic; write-through unstated; a success after a crash-between-increment-and-open loses the open forever | Every `record_failure`/`record_success` is ONE atomic CAS append evaluating the threshold inside the write; read-time self-heal rule; state written through per event |
| C2 | High | Multi-owner counter semantics undefined; one owner's success masks another's failures (P13's 2–50 pollers) | Per-owner scope keys (`scope:.../owner:...`); per-owner counters; any owner over threshold opens the scope; two-owner interleave test |
| C3 | High | Window/rate conditions (verification-twice-in-window, fingerprint-thrice-in-run, budget rate) have no state home; consecutive-counter model can't express them | Per-condition accumulator/window sub-state evaluated inside the atomic append, OR documented in-process evaluation with the record persisting only the open verdict; D1 rewritten to include non-consecutive pairs |
| C4 | High | Reset authority not reconciled with P10's "caller reset"; same-process enforcement undefined (evidence-free public reset in the supervisor) | Per-scope reset evidence weight (`:server` = operator command record, not a plan review); `reset(evidence:)` at the Supervisor API; evidence gate on the record write |
| C5 | High | Re-home seam missing; tamoz-mcp may not touch tamoz-sqlite; the ledger doesn't record the contract | Caller-injected duck-typed `CircuitStore` seam (EffectDispatcher pattern); re-home contract recorded at slice-3 close |
| C6 | Medium | Corruption repair path + notification owner undefined | Reset-with-authority permitted on corrupt records (CAS reads the head row; overwrite IS the repair); per-scope escalation owner named |
| C7 | Medium | "Evidence unioned" presumes a merge-retry loop | Merge protocol specified (read → merge → CAS, bounded retry, escalate on exhaustion, no silent evidence drop); D6 asserts both digests |
| C8 | Medium | Data.define with Symbols rejected by StateCodec; conditions_met unbounded | String-keyed Hash storage (sorted keys = canonical); conditions_met ring-buffered; collision-free scope_id encoding |
| C9 | Low | Naming/consistency (three error names, two namespace strings, migration note, ungrounded egress scope) | One class (`CircuitOpen`); one namespace scheme; migration stated (already-migrated Store tables); egress scope marked provisional pending P17; "precision/confidence" wording |
| C10 | Low | next_probe_at stale under clock rollback; open-vs-in-flight effects; missed-occurrence reasons; pool.rb de-scope | Probe window stored as duration (derived at read); open never blind-cuts in-flight non-idempotent effects (journaled `:unknown`, reconciled); missed reasons recorded by the first post-reset claim; pool.rb explicitly not an instantiation |

## Held-out probes

Crash between increment and open then success; two owners interleaved fail/success;
non-consecutive window condition; corrupt record + authorized reset; circuit opens with
a non-idempotent effect in flight; same-process P10 caller reset without evidence.

## Status

Corrections integrated in `docs/DR2_DURABLE_CIRCUIT_PLAN.md` revision 2. Time-critical
guidance (freeze `open?`/`record_failure`/`record_success`/`reset(evidence:)` +
CircuitStore seam) sent to the in-flight P10 slice-3 builder. P12/P13 cite DR-2.
