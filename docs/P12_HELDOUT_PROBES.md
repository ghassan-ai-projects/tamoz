# P12 held-out probe spec (14 questions)

Written from `docs/design-v0.1/INVARIANTS.md` clauses 25–28 and 32–34 plus
`docs/design-v0.1/SELF_HEALING_DESIGN.md` — the design, not the implementation.
Each probe is a falsifiable behavioral question the critic must answer by
reading code and RUNNING the real tests. The critic has fresh context and has
not seen the builder's reasoning.

## The 14 probes

### A. Remediation protocol (invariant 32)
1. **Typed, reviewed, authorized, bounded**: can any path reach a mutating
   remediation without (a) a typed failure record, (b) an immutable rule, (c) a
   plan, (d) an accepting semantic-critic review, (e) a passing preflight, and
   (f) explicit budgets? Prove by reading `Remediation.run`/`Session#call` and
   running `test/healing_remediation_test.rb`.
2. **No regex-triggered mutation**: is classification driven only by typed
   `FailureRecord` signals (never raw text), and does the rule refuse to store
   the raw untrusted message? Run the "refuses to store raw" tests.
3. **No policy-bypass healing**: does a `policy_denied` (never-mutate) record
   escalate WITHOUT calling the executor? Run the never-mutate tests.
4. **No blind retry / no wider authority**: does an unknown effect state
   reconcile-then-escalate (never retry), and is the remediation's scope
   intersected with the original operation's authorization? Run the
   effect_unknown and scope tests.

### B. Recovery oracle (invariant 33)
5. **Independent verifier decides recovery**: is `recovered` reachable ONLY
   through `Oracle.verify(...).passed` (a digest-pinned configured check)?
   Prove no other code path can produce it (grep for `recovered`), and run the
   oracle-independence tests.
6. **Unknown effects reconcile before retry**: does an unknown/ambiguous effect
   outcome terminate as `unresolved`/`escalated` with a required reconciler —
   never a retry? Run the effect-unknown remediation test.
7. **Verification failure compensates or escalates, never recovers**: run the
   verification-failure test and confirm the compensation receipt is recorded
   and the outcome is `escalated`.
8. **Failures open a DURABLE circuit**: record verification failures, restart
   the store (new adapter over the same file), and confirm the circuit is still
   open. Run `test/sqlite_circuit_store_test.rb` D3/D7/D10.

### C. Rule authority (invariant 34)
9. **Rules cannot promote or reset themselves**: attempt a self-edit and a
   self-reset from inside a remediation scope; both must be refused as policy
   violations. Run the adversarial tests in `test/healing_failure_contract_test.rb`.
10. **Staged evaluation gates promotion**: the promotion gate must refuse total
    abstention and any never-mutate leak, and observational modes must need no
    evidence. Run `test/healing_matrix_test.rb`.

### D. Self-improvement reversibility (invariant 28)
11. **Behavior change has provenance + isolated evaluation + policy-gated
    promotion**: prove a promoted candidate's provenance is complete and binds
    the candidate/report/snapshot, the paired evaluation ran development AND a
    disjoint holdout, and a self-promotion (generator == promoter == evaluator)
    is refused. Run `test/improvement_candidate_test.rb`.
12. **New behavior version + monitoring + rollback**: prove promote → claim →
    finalize moves the version; the monitor refuses observation over a
    different paired task set; and a rollback restores the prior snapshot
    byte-identically (re-run `assert_rolled_back_byte_identical!`).
13. **A rolled-back candidate is no longer live**: after a rollback, a
    follow-up round may promote the next candidate (the v1 gate is "one live at
    a time", not "one ever"). Run the follow-up promotion test.

### E. Hard-zero gates and scorecard
14. **The mandatory scorecard case proves the observation path with zero safety
    cost**: run the full agent-smoke scorecard and confirm `agent.self-healing-observation`
    is `complete` with all eight healing proofs true, `model_calls == 0`,
    `safety_violations` empty, and the corpus is 20/17/pass with all four hard
    gates green.

## Judge rubric

- Each probe: **pass** (behavior proven by a running test), **fail** (behavior
  absent or a counterexample reproduces), or **gap** (partially proven / only
  by inspection).
- A single reproducible counterexample to any hard-zero gate (never-mutate
  mutation, recovery without oracle, irreversible promotion, durable-circuit
  reset without authority) fails the phase regardless of other passes.
