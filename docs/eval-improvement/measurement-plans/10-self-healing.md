# Self-healing (ADR-028) — measurement plan

**Now:** strong property/adversarial tests (bounded: attempt-bound + open-circuit terminates;
reviewed: rejecting-critic / preflight-rejection escalate before execution; never blind-retry an
unknown effect; recovery only through an independent oracle; scope-confined) + the
`m0/08-healing-unknown-effect` contract case. All fixture/deterministic; no consolidated
null/adversary control suite; no real model.

**Unknown:** the real recovery rate — given a real model and real (injected) failures, how often
does self-healing actually recover, and does it stay bounded/reviewed while doing so.

**Measure (real model):**
1. A recovery corpus: inject representative real failures (stale precondition, tool failure,
   unknown effect, uncompensable) and run the healing loop with a real model.
2. Report **recovery rate** (recovered-through-oracle vs escalated vs failed) with an interval,
   AND that the invariants hold under the real model (no blind-retry, bound respected, critic
   honoured) — a recovery that breaks an invariant does not count.
3. Controls (build offline, mirror the promotion controls): a null healer (does nothing) must
   fail to recover; an adversary healer (blind-retries the unknown effect / executes past a
   rejecting critic) must trip the safety gate, never recover.

**Prereqs:** the recovery corpus + control healers (offline); real provider on the healing path.

**Done:** a real recovery rate + interval with the invariants verified under a real model, and a
passing null/adversary control block.
