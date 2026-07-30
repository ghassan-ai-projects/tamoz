# M3.1 phase 2C implementation review

Review target: intentional subprocess intervention and evidence termination semantics.

Base revision: `5cba492`.

Decision: accepted for commit on 2026-07-30. No unresolved correctness, security,
reliability, or maintainability finding remains in this slice.

This decision accepts Phase 2C only. It does not claim a durable selector-control file,
control-record authenticity, exact hook matching, crash atomicity, scenario completeness,
independent database classification, recovery convergence, or Phase 2 completion.

## Scope reviewed

- optional parent intervention without changing ordinary subprocess callers;
- exact `WUNTRACED` child-stop observation and retained stop state;
- a minimal poll protocol containing only stop-signal name and monotonic remaining budget;
- fixed `nil` or `"kill"` intervention decisions;
- process-group `SIGKILL`, exact reaping status, output draining, and bounded cleanup;
- monotonic timeout/intervention arbitration;
- normalization of intervention failures as harness infrastructure errors;
- absence of process ids in callback arguments and serialized process results;
- separate termination action, reason, timeout, and observed-status fields;
- schema and semantic-verifier relations for normal, timeout, intervention, and cleanup
  outcomes;
- selector-evidence binding to at least one intentional `SIGKILL` process record;
- the prohibition on treating cleanup termination as passed evidence;
- compatibility with output bounds, exact environments, timeout escalation, retained
  descendant detection, packaging, and M0-M2 conformance.

The subprocess primitive knows only process state and a bounded intervention protocol. It
does not read or interpret selector-control data; that security boundary belongs to Phase
2D.

## Review method

The review followed four process lifecycles from spawn through final serialization:

1. ordinary exit without a stop;
2. cooperative and TERM-resistant timeout;
3. `SIGSTOP`, repeated parent polling, and intentional parent `SIGKILL`;
4. stopped child with a nil, invalid, late, or raising intervention.

The adversarial pass varied stop timing, decision timing, return type, callback failure,
timeout crossing, inherited TERM handling, process exit, output retention, and evidence
field combinations. It separately reviewed the runner-generated state machine and the
untrusted artifact verifier so a fabricated process record cannot rely on constructor
behavior.

## Findings resolved

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | Phase 1 represented every harness kill as a timeout, making intentional crash evidence contradictory. | Harness action and harness intent shared one field. | Add `termination_reason` and bind it relationally to `termination`, `timed_out`, and observed status. |
| High | A stopped status could be lost after the first `WUNTRACED` observation. | A stop is a wait-state transition, not a terminal status repeatedly returned by `waitpid`. | Retain the exact stop-signal name and poll from that retained state until exit, decision, or deadline. |
| High | A kill decision started before the deadline could return after it and be misclassified as an intervention. | The deadline was checked before, but not after, parent polling. | Re-read the monotonic clock after every valid decision; timeout wins once the deadline has elapsed. |
| High | Exception cleanup used an unbounded blocking `waitpid`. | SIGKILL delivery was treated as proof that reaping had completed. | Poll reaping under the configured grace budget and raise infrastructure failure if cleanup exceeds it. |
| High | A callback exception could escape as an arbitrary application exception. | Only subprocess and IO exceptions were normalized by the outer execution boundary. | Wrap intervention `StandardError` as `ExecutionError`, retain the cause internally, and run bounded cleanup in `ensure`. |
| High | Structurally valid evidence could combine timeout, action, reason, and signal fields inconsistently. | JSON Schema enums do not express the complete cross-field state machine. | Add fail-closed semantic relations and a contradiction matrix for every termination reason. |
| Medium | Selector-bearing evidence could contain only an ordinary process record. | Selection and process semantics were verified independently. | Require selector evidence to contain an intentional, non-timeout `SIGKILL` process record. |
| Medium | An invalid decision returned after the deadline could be ignored as a timeout. | Deadline arbitration happened before decision-shape validation. | Validate the fixed decision vocabulary first, then arbitrate a valid result against the deadline. |
| Medium | Callback exception messages could expose control paths or other internal material. | Error context was copied verbatim into the public harness error. | Report only the bounded exception class while retaining the original exception as the Ruby cause. |

## Five Whys: timeout versus intervention

1. Why must timeout and intervention be distinct? A selector kill is expected evidence,
   while a timeout means the selected handshake did not complete in budget.
2. Why is the configured callback alone insufficient? Its decision can race the same
   monotonic deadline that controls the child.
3. Why check time after polling? The callback may begin with remaining budget but consume
   that budget before returning.
4. Why does timeout win at the boundary? Accepting a late kill would convert missing or
   slow control verification into false crash coverage.
5. Why still validate a late return value? A protocol violation is infrastructure failure
   and must not be concealed by timing.

## Gate evidence

Focused gates under rbenv Ruby 3.3.11:

- subprocess lifecycle/intervention tests: 16 runs, 131 assertions;
- evidence schema/semantic tests: 11 runs, 75 assertions;
- timeout/intervention stability treatment: 30 consecutive seeded focused runs;
- syntax and `git diff --check` passed.

Full gate under rbenv Ruby 3.3.11:

- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI: 260 runs, 4,955 assertions, 0 failures, 0 errors, 0 skips;
- syntax, packaging, public API, M0-M2 conformance, and SQLite regressions passed.

The first combined evidence-focused run inside the outer workspace sandbox reached the
M1/M2 tests but could not create their nested macOS network sandbox
(`sandbox_apply: Operation not permitted`). The full gate passed outside that outer
restriction. This is harness infrastructure, not a product failure.

## Residual limits and non-claims

- Phase 2C trusts the configured intervention object to keep each poll within the supplied
  remaining budget. Phase 2D supplies the only production intervention and must prove its
  fixed file operations are bounded; arbitrary blocking Ruby callbacks cannot be safely
  interrupted with asynchronous thread exceptions.
- Phase 2C observes and reports any stop signal. Phase 2D must require exact `SIGSTOP` and
  reject missing, different, changed, or unauthenticated control state.
- An evidence process record proves termination-state consistency, not selector-control
  authenticity. Phase 2D adds the fsynced control protocol; Phase 2G binds its reference
  into the evidence envelope.
- The runner targets the Phase 2 POSIX process-group and signal contract. Unsupported
  platforms must refuse this evidence path rather than report a pass.
- Local evidence covers Ruby 3.3.11. Ruby 3.4 and 4.0 remain exact-revision CI gates.

## Acceptance checklist

- [x] Ordinary subprocess behavior remains backward compatible.
- [x] A stop is observed with `WUNTRACED` and retained without being mistaken for exit.
- [x] The intervention receives no process id or mutable process object.
- [x] Only nil or the exact kill decision is accepted.
- [x] Timeout wins over a valid decision returned after the monotonic deadline.
- [x] Invalid or raising interventions fail as infrastructure and trigger bounded cleanup.
- [x] Intentional kill reports kill/intervention/KILL/not-timed-out exactly.
- [x] Timeout reports timeout reason exactly for TERM and KILL escalation.
- [x] Ordinary success requires both termination action and reason to be none.
- [x] Cleanup termination cannot support passed evidence.
- [x] Selector evidence requires an intentional SIGKILL process record.
- [x] Focused and full regression gates pass.
- [x] No Phase 2D control-protocol work is mixed into this commit.
