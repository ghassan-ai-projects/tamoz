# P15-I — owner decision request

This is the request, not the decision. Per `docs/P15_RELEASE_PLAN.md` §11 the
gate record must be a written OWNER decision naming the exact candidate commit,
with evidence of delivery and acknowledgment. A coordinator-written note is not
that record, and this file does not pretend to be one.

Until the owner decides, `docs/release-owner-decision.json` does not exist, and
the requirements audit therefore reports every pending residual as `missing`
rather than `owner-signed-residual`. That is deliberate: nothing here can sign
itself.

## What is being asked

Three decisions. Nothing is pushed, published, tagged, announced, or connected
to a physical actuator without them.

### Decision 1 — INV-39, cron and civil-time scheduling

`tamoz-scheduler` ships `at` and `interval`. Cron expressions and IANA
timezones are **not implemented** (a P13 §12 deferral). The misfire, overlap,
backlog and jitter half of invariant 39 has direct evidence; the civil-time
half is absent, so the clause cannot be claimed whole.

Because `tamoz-scheduler` ships in the release surface, P15-A's promotion
matrix makes invariant 39 release-blocking. The options:

| Option | Consequence |
|---|---|
| **A. Sign the residual** | v0.1 ships the scheduler with cron disclosed as absent. `LIMITATIONS.md` already says so. The audit row becomes `owner-signed-residual`. |
| **B. Exclude `tamoz-scheduler`** from the v0.1 release surface | Invariants 38–40 stop being release-blocking. The gem does not ship. |
| **C. Implement cron** | A new work package, with an IANA timezone database dependency and a DST conformance suite. |

### Decision 2 — INV-48, channel backpressure

`Tamoz::Stream::ChannelDescriptor` validates and digests `queue_capacity`,
`spool_capacity_bytes` and `overflow`. **No code outside the descriptor reads
any of the three** — measured across `gems/tamoz-stream` and `gems/tamoz-sqlite`
at this head. The declaration is recorded in the channel's content-addressed
identity and never enforced.

Implemented and tested: durable admission, idempotent dedup, quarantine on
identity reuse, typed rejection, acknowledgement only after durable admission.
Absent: any bound on queue or spool growth, and all six overflow behaviours.

| Option | Consequence |
|---|---|
| **A. Sign the residual** | v0.1 ships streaming with backpressure disclosed as declaration-only. A fast producer is bounded by nothing in the stream path. |
| **B. Exclude `tamoz-stream`** from the v0.1 release surface | Invariants 44–51 stop being release-blocking. The gem does not ship. |
| **C. Implement enforcement** | A new work package: the six policies, spool exhaustion, and a saturation suite. |

This one carries the most operational risk of the three: an unbounded queue is
a memory-exhaustion path, and the descriptor's own vocabulary invites an
operator to believe otherwise. `OVERFLOW_POLICIES` is deliberately excluded
from the documented public API for that reason.

### Decision 3 — OBJ-7, release readiness

The reproducibility and documentation halves are evidenced (below). What
remains is this decision itself: whether the candidate is a release candidate,
and what may be said about it publicly.

**Recommendation: stage, do not ship.** Sign residuals 1 and 2 if the disclosed
limitations are acceptable for a `0.1.0.alpha` audience, keep the gate open, and
make no stable-release claim. The three evidence gaps below are the reason.

## The candidate

| Field | Value |
|---|---|
| Candidate commit | see `docs/release-rehearsal.json` → `candidate_commit` |
| Scorecard decision digest | `sha256:08a7a5265c608dc8a89de04c789c45e8e4dc9e7eac89b923951f925446c26254` |
| Corpus | `tamoz.agent.smoke` v1, 22 cases, `sha256:498ccb87…` |
| Gate | 1233 runs / 38,389 assertions / 0 failures, identical under `LC_ALL=C` and `en_US.UTF-8` |
| Rehearsal | all fourteen steps pass on a clean clone with the pinned toolchain |
| Requirements audit | 333 pass with executed evidence, 11 deferred-by-contract, 4 indirect, 3 release-blocking gaps |

The scorecard digest is unchanged across the whole of P15 — including a
re-wiring of the production dispatch path — which is the behaviour-neutrality
proof for this phase.

## Evidence

| Artifact | What it is |
|---|---|
| [`requirements-manifest.json`](requirements-manifest.json) | 351 requirements generated from the invariants, ADRs, phase exit criteria, public API, CLI, migrations, objectives and non-goals |
| [`REQUIREMENTS_AUDIT.md`](REQUIREMENTS_AUDIT.md) | every row's status derived by RUNNING its named test |
| [`RELEASE_REHEARSAL.md`](RELEASE_REHEARSAL.md) | clean-clone rehearsal on the pinned toolchain |
| [`release-evaluation-manifest.json`](release-evaluation-manifest.json) | the pinned corpus, case versions, case digests and decision digest |
| [`DEPENDENCY_REVIEW.md`](DEPENDENCY_REVIEW.md) | 22 runtime gems, zero licence violations, provenance controls |
| [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md) | invariant-24 sweep, 216 adversarial cases, findings and dispositions |
| [`BENCHMARK.md`](BENCHMARK.md) | gated counters and reported latency, offline model |
| [`LIMITATIONS.md`](LIMITATIONS.md) | what v0.1 does not do, bound to the measured audit |

## Risks the owner should weigh

1. **No independent review of this phase.** Every defect P15 found was found and
   fixed by the same coordinator. P6, P7, D-7 and rounds 28–29 sit in the same
   class. This is the largest evidence gap, and it is structural: the builder
   graded its own work.
2. **Backpressure is unenforced** (Decision 2). Memory exhaustion is reachable
   by a fast producer.
3. **The corpus is ASCII-heavy and offline.** Round 29 added non-ASCII coverage
   across the durable path, but three defect classes in this project's history
   were found only by running against a real model — never by the gate. A
   pre-release real-model smoke is cheap and has repeatedly paid for itself.
4. **`Tamoz::ConfigurationError` is not a `Tamoz::Error`.** A caller's
   `rescue Tamoz::Error` will not catch it. No exploitable consequence found;
   recorded rather than fixed because several suites pin error classes.
5. **Simulated actuation only.** Connecting a real effector is a separate
   decision with its own safety review, and nothing in this candidate should be
   read as readiness for one.

## What happens on approval

Recording a decision means writing `docs/release-owner-decision.json`:

```json
{
  "candidate_commit": "<the commit from release-rehearsal.json>",
  "decided_at": "<ISO-8601>",
  "decided_by": "<owner>",
  "outcome": "gate-open-staged | approved-to-publish | rejected",
  "acknowledged": true,
  "signed_residuals": {
    "INV-39": "reason the owner accepts the cron gap",
    "INV-48": "reason the owner accepts the backpressure gap"
  }
}
```

The audit then reports those rows as `owner-signed-residual` instead of
`missing`. **Push, tag, publish, announce and any real physical adapter remain
prohibited until the owner says so explicitly**, and "gate open" means the
candidate is staged and the release is not shipped.
