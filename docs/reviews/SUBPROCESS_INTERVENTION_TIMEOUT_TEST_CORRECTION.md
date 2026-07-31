# Subprocess intervention-timeout test correction

Review target:
`SubprocessRunnerTest#test_nil_intervention_decision_remains_bounded_by_process_timeout`.

Reviewed base: `9f8b4e9`.

Decision: accepted test-only correction on 2026-07-31, subject to focused stability and
full CI.

## Finding

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Medium | Under full-suite process load, the 75 ms timeout could expire before the Ruby child started and entered `SIGSTOP`, leaving the intervention poll count at zero. The timeout result was correct, but the test then failed its unrelated `polls > 0` assertion. | One deadline was expected both to cover unconstrained process startup and to exercise repeated nil intervention decisions. | Increase the test-only deadline to 500 ms and its bounded poll ceiling from 10 to 75. Production timeout behavior is unchanged. |

## Five Whys

1. Why was `polls` zero? The child was not observed stopped before the 75 ms process
   deadline.
2. Why can startup exceed 75 ms? Full CI concurrently performs many Ruby, SQLite, and
   process operations; scheduling latency is not bounded to that value.
3. Why did timeout still pass? The runner correctly terminated and reaped a child that
   missed its deadline.
4. Why did the test fail anyway? It combined timeout correctness with the separate
   requirement that the nil-returning intervention branch be reached.
5. Why increase only the test deadline? Production semantics are correct, and 500 ms
   remains a tight bounded test while providing enough startup budget to exercise the
   intended branch reliably.

The poll ceiling remains finite and proportional to the runner's 10 ms loop. The change
does not weaken assertions for timeout classification, termination action/reason,
`SIGKILL`, or callback bounds.

## Gate evidence

Executed under rbenv Ruby 3.3.11:

- the original full-suite run reproduced zero intervention polls while still returning
  the correct bounded timeout result;
- the original test and complete subprocess-runner file passed immediately in isolation
  with the same seed, confirming load sensitivity;
- corrected focused test: 20 fixed seeds, 0 failures;
- complete subprocess-runner regression: 16 tests, 239 assertions;
- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI, including the in-progress Phase 2F superset: 313 tests, 26,899 assertions,
  0 failures, 0 errors, 0 skips.
