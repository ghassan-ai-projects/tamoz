# Analyst re-review: F20-REL-02 failed-effect return contract

Date: 2026-09-15
Checkout: `audit-15-09`, code baseline `582ae55`
Scope: re-review the new challenger finding proposed in `challenge-healing.md`.
Mode: read-only; no production, test, configuration, or coordinator-document changes.

## Verdict

| Finding | Re-review result | Severity / confidence | Status | Owner |
|---|---|---|---|---|
| F20-REL-02 | Confirmed: failed remediation returns a transitions `Array` instead of `Outcome` | major / high | open | `Remediation::Session#handle_ambiguous_effect` via `AttemptEvidence#record` |

The finding is real and source-grounded. It is major today because an exhaustive
repository search found no production caller of `Remediation.run`; it would become
critical when the healing protocol is wired because the failed-effect path skips
verification, compensation, terminal validation, and escalation. It is distinct from
CF04-REL-01 (kernel receipt selection) and F20-REL-01 (missing repetition bound).

## Source trace and reproduction

`Remediation.run` constructs a `Session` and returns `session.call`
(`gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation.rb:62-76`). In
`Session#call`, `execute_effect` returns an `EffectDispatcher::Outcome`, then
`handle_ambiguous_effect` is called (`session.rb:48-52`). The `:failed` branch only
calls `transition(:uncertain, ...)` and has no explicit return (`session.rb:169-185`).
`transition` delegates to `AttemptEvidence#record` (`session.rb:280-284`), whose last
expression is `@transitions << transition_for(...).freeze` (`attempt_evidence.rb:27-31`).
Ruby therefore returns the mutable ledger `Array`, which is truthy. `Session#call`
returns it at `return ambiguous_terminal if ambiguous_terminal` (`session.rb:49-50`),
so `verify_or_compensate` (`session.rb:187-216`) is never entered.

I reran the existing temporary control with the pinned Ruby:

```text
/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby /tmp/f20_probe9e.rb
```

The result was:

```text
CONTROL-D cycle 1: trace=trace.1 => Outcome state=escalated performed=true reused=false
CONTROL-D cycle 2: trace=trace.2 => RAW ARRAY (not Outcome); first=Hash keys=["state", "failure_format_version", "failure_fingerprint", "rule_id"]
CONTROL-D cycle 3: trace=trace.3 => Outcome state=escalated performed=false reused=
CONTROL-D cycle 4: trace=trace.4 => Outcome state=escalated performed=false reused=
CONTROL-D TOTAL performs (one fingerprint, changing trace+call_index): 2
CONTROL-D escalations: 3
```

The control also shows that the dispatcher is not the cause: cycle 2 receives a
proper failed dispatcher outcome, while the healing session returns the ledger array.
The healing remediation suite remains green (**13 runs, 74 assertions, 0 failures**):

```text
/Users/ghassan/.rbenv/versions/3.3.11/bin/ruby -Itest test/healing_remediation_test.rb
```

No test drives a failed effect through `Remediation.run`. A production caller sweep:

```text
rg -n 'Remediation\.run|Agent::Healing::Remediation|Tamoz::Agent::Healing::Remediation' gems apps bin script --glob '*.rb'
```

found only a source comment; no shipped caller exists. The probe is durable-plumbing
evidence, not model or provider evidence.

## Six-lens assessment

- **Correctness:** confirmed contract violation: a public remediation entry point can
  return a non-`Outcome` value on a failed effect.
- **Security and authority:** no direct bypass is demonstrated; skipped verification
  would matter once a caller can act on the returned value.
- **Reliability and durability:** failed effects do not reach compensation,
  `validate_terminal_state!`, or the escalation sink; the failure is not durably
  represented as the terminal result.
- **Observability and evidence:** the transitions array contains `uncertain`, but no
  `Outcome` or escalation payload is returned, so callers cannot rely on the declared
  terminal/evidence contract.
- **Scalability:** no new unbounded resource is introduced by this finding. It is
  separate from F20-REL-01's unbounded repeat behavior.
- **Maintenance and architecture:** the bug crosses one existing seam and is not a
  duplicate of the kernel's CF04 receipt defect; no new abstraction is warranted.

## Five whys and recommendation

1. A failed remediation returns an `Array` because `handle_ambiguous_effect` returns
   the result of `transition` for `:failed`.
2. `transition` returns the value of `AttemptEvidence#record`, which is the append
   operation's array.
3. `Session#call` treats any truthy ambiguous result as a terminal return and never
   invokes `verify_or_compensate`.
4. The `:unknown`/`:wait` branches explicitly call `terminate`, but the `:failed`
   branch was added as a transition-only path without the same terminal construction.
5. The focused suite never injects a failed dispatcher outcome through the public
   remediation entry point, so the declared `Outcome` contract has no regression
   gate at this boundary.

At the existing seam, make the `:failed` branch produce the established terminal
`Outcome` path (or explicitly route it through the existing compensation/escalation
policy) and add one failed-effect regression asserting `Outcome`, terminal state,
verification/compensation behavior, and escalation. Do not repair this by changing
the caller to tolerate arrays. Keep F20-REL-01 separate and retain its reachability
qualification.

## Disposition

**Confirmed, major/high/open.** The challenge-healing evidence and this independent
source/probe re-review agree. No implementation was performed; the coordinator should
remove the pending marker and record the recommendation for a future implementation
loop.

Created file mode is `0644`; probes remain under `/tmp`; no repository scratch,
production, test, configuration, or coordinator file was changed.
