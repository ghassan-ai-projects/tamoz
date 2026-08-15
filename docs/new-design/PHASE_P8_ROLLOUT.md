# P8 — Controlled rollout

Bar rules exercised: B1, B6, B8, B10.

## Goal

Ship the reasoner to production data without ever lying about authority. Shadow first. Automation
last, and only with calibration evidence.

## In scope

- **Explicit modes.** `ExecutorName=native|tamoz|fixture` × `dispatch_policy=active|shadow`,
  durable, bound to the episode with a policy epoch. No hidden fallback in any mode. `fixture` is
  rejected on production routes; it exists for demos and tests only.
- **Shadow first.** Initial production is `tamoz + shadow`: Tamoz proposes, Agentic Stream
  persists and scores, nothing enters action governance. Then `active` watch-only (R0/R1).
- **Calibration-gated automation.** Automatic consequential intents stay disabled until an exact
  calibration artifact exists: model revision + profile digest + prompt + diagnosis catalog +
  domain + policy digest. Missing or mismatched = watch-only.
- **Drain and kill.** Graceful drain: stop new episodes, let in-flight finish under their recorded
  mode. Emergency kill: cancel in-flight provider calls; Agentic Stream refuses every later
  decision under the killed epoch — independently of the worker.
- **Freshness.** Agentic Stream rechecks the situation version immediately before dispatch. p95/p99
  latency gated against snapshot freshness and action deadlines. Validity windows are never
  extended to make the model pass.
- **Production privacy.** Durable artifact backend with tenant scoping, encryption, access audit,
  retention TTL/deletion, provider egress/residency controls, redaction. If retention policy
  forbids exact bytes, that run claims digest verification only, never exact replay.
- **Graph versioning.** A graph definition change = new version + fresh database/checkpoint
  namespace. No legacy-row shims (per repo policy).
- **Channel unification decision.** Three divergences survive to this phase by design: two
  approval pipelines (stream `ApprovalRelay`, comms approvals), two decision types (stream
  decision-v1, comms `DecisionRecord`), three auth models (capability token, subscriber bearer,
  bot token). Present the owner a merge recommendation for each. Until decided, they stay as they
  are. We do not silently keep the duplication.

## Exit gate

1. Agentic Stream independently blocks shadow, killed, and stale decisions. Tested with a hostile
   worker.
2. Kill cancels in-flight provider calls; later decisions refused under the killed epoch.
3. No fallback path exists: code inspection + adversarial test.
4. Privacy/egress/retention gates pass for the first tenant's data class.
5. Automatic action attempted without a calibration artifact → refused.
6. Latency/freshness SLOs measured and reported honestly, including stale-decision rejection rate.

## Allowed claim

**"Production-ready for watch-only (then calibrated automation) in domain X."** Level 6 of 6 —
only after P7 passed for that domain.
