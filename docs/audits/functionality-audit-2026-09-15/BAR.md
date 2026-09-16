# Functionality audit — quality bar

## Scope and stop condition

The audit covers every responsibility in the current 27-gem `gems/*/lib`
inventory exactly once, plus the reference app, executable entry points,
support scripts, `Rakefile`, and the cross-gem flows listed in `COVERAGE.md`.
Gems are the primary queue. Cross-gem rows may overlap gem rows because they
test behavior across boundaries; they do not replace any gem review.

The audit may be called complete only when:

1. all 27 gem rows have a source-grounded scanner pass and an independent
   analyst pass, with the coordinator's synthesis and disposition recorded;
2. the app, entry-point, support-script, and `Rakefile` inventories have been
   reviewed at the item level or explicitly marked as an evidence gap;
3. every listed cross-gem flow has an end-to-end source trace, boundary owners,
   relevant test/contract evidence, and recorded blind spots;
4. each functionality assesses correctness, security/authority, reliability
   and durability, observability/evidence, scalability/resource bounds, and
   maintainability/architecture;
5. every critical or major finding has an independent challenge, source
   citations, a five-whys root cause, a simple recommendation at the existing
   seam, and a disposition; and
6. the final counters distinguish mapped, scanned, independently reviewed,
   synthesized, and closed rows. Unknown or unreviewed work stays incomplete.

No implementation, test fix, generated-artifact refresh, or commit is part of
this audit package. Tests and quality commands may be read or run only when a
later bounded brief explicitly permits them; their absence is recorded rather
than implied away. The setup phase ran no test suite.

## Review lenses

Each analyst follows the whole behavior path for the assigned functionality,
then checks the following lenses. A lens is marked `not evidenced` when the
repository does not prove it.

| Lens | Required questions | Typical evidence |
|---|---|---|
| Correctness | Do normal, failure, retry, replay, cancellation, and boundary paths preserve the stated contract? | implementation path, public API, behavior tests, error identity, wire bytes |
| Security and authority | Can untrusted content widen capability, approval, egress, filesystem, or secret access? | policy data, validators, trust boundaries, negative tests, secret scans |
| Reliability and durability | What happens across crashes, ambiguous effects, leases, transactions, timeouts, and partial completion? | effect/checkpoint/store seams, transaction code, recovery tests, run evidence |
| Observability and evidence | Is the outcome, refusal, unknown state, and failure visible and correlated without leaking secrets? | signal catalog, receipts, logs, metrics/traces, scorecards, evidence artifacts |
| Scalability and resource bounds | Are work, bytes, concurrency, retries, queues, and memory bounded with backpressure? | limits, pools, pagination, drain behavior, load/soak evidence |
| Maintenance and architecture | Is ownership clear, dependency direction honest, public surface narrow, vocabulary consistent, and duplication justified? | gemspecs, requires, Enola, API docs, coding standard, tests |

## Finding contract

Use finding IDs of the form `<functionality-id>-<lens>-<number>`, for example
`F07-REL-01`. A finding is recorded only when the analyst can name the
observable behavior or contract at risk and the owning seam.

| Field | Required content |
|---|---|
| Severity | `critical`, `major`, `minor`, or `info`; use the definitions below |
| Confidence | `high`, `medium`, or `low`; explain what is and is not proven |
| Status | `open`, `closed`, `duplicate`, `deferred`, or `unconfirmed` |
| Source evidence | Concrete `file:line` citations for the path, guard, contract, or absence claimed |
| Test/contract evidence | `file:line`, command/result if run, or an explicit `not found`/`not run` |
| Scanner signal | The search, static result, or inventory lead; `none` is valid |
| Independent judgment | What the analyst confirmed, rejected, or could not establish |
| Root cause | Five-whys chain for critical/major findings; concise causal explanation for minor findings |
| Recommendation | Smallest credible action at the existing owner seam; no speculative rewrite |
| Disposition | Why the coordinator accepts, rejects, duplicates, defers, or leaves it open |

Severity follows the existing top-100 bar while applying to behavior, not file
size:

- `critical`: active defect or invariant/boundary violation that can cause an
  unsafe action, authority bypass, data loss, false completion, broken
  durability/effect semantics, or materially misleading evidence;
- `major`: material correctness, security, reliability, observability,
  scalability, dependency, or ownership gap with real operational cost;
- `minor`: bounded maintainability, naming, documentation, testability, or
  local observability debt with limited immediate impact;
- `info`: a verified design fact, limitation, or question that is useful for
  later work but is not itself a defect.

Confidence describes evidence, not agent certainty:

- `high`: the relevant source path and boundary are directly verified, and a
  test, contract, deterministic source proof, or reproducible runtime result
  supports the conclusion;
- `medium`: source evidence is real but a caller, failure path, test, or
  runtime condition remains unverified;
- `low`: the item is a scanner/heuristic lead or depends on an assumption. It
  remains `unconfirmed` until an analyst proves it.

`closed` means the current audit has disproved the lead or verified an existing
resolution with current evidence. It does not mean “the owner should fix it.”
An unresolved verified finding remains `open`; this read-only package does not
claim closure by writing a report.

## Required reasoning discipline

Analysts read the implementation, relevant callers, public contract, and
behavior tests before grading. They use the existing seam and repository
vocabulary (`validate`, `verify`, `assert`, `enforce`, `encode/decode`, and
`render/parse`) when naming evidence. File size, a lint result, an Enola
heuristic, a stale earlier report, or a missing test is a lead until its impact
is source-grounded.

For each critical or major issue, ask “why?” until the answer reaches a
controllable design, ownership, evidence, or process cause rather than merely
restating the symptom. The five-whys chain must connect the symptom to the
recommendation and name the contract that would prevent recurrence. If the
chain cannot be supported from the checkout, mark the finding `medium` or
`low` confidence and state the missing evidence.

## Verdict and coverage rules

A functionality is `IMPROVE` when it has at least one accepted critical/major
finding or three or more accepted minor findings. It is `PASS` only after all
six lenses and required evidence are reviewed and no such threshold is met.
It is `INCOMPLETE` when either analyst lane, a required lens, or the source
trace is missing. A `PASS` may still list `info` items and limitations.

Scanner coverage and analyst coverage are separate counters. A scanner may
reduce search cost but cannot close a row. One analyst cannot count as
independent review of its own scanner signal without a distinct challenge
record. The coordinator records known overlap with prior packages and does not
silently promote historical findings to current defects.
