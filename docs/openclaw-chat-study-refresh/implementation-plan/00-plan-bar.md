# Implementation-plan bar

This bar grades the implementation plan in `01-plan.md`, not the code. The plan
is ready to hand to an implementer only when it meets every criterion below.
The review loop in `02-plan-review-log.md` scores the plan against this bar and
iterates until all criteria pass.

The plan operationalizes `../02-decision-roadmap.md` and the canonical findings
in `../05-open-findings-ledger.md`. It does not authorize code changes by
itself; each phase still enters through its own change brief, review, and gates.

## What the plan must contain

### B1 — Finding coverage and traceability

Every canonical finding (CF-1..CF-6, EG-1..EG-7, DG-1..DG-4, MG-1..MG-4) is
assigned to exactly one phase or explicitly deferred with a reason. No finding
is silently dropped. Each phase lists the finding IDs it closes. The three
rescued findings (CF-5, CF-6, EG-7) appear in a phase, not only in the ledger.

### B2 — Correct dependency order

The phase order preserves the study's hard predecessor chain: typed
interruption and clarification ingress (CF-1, CF-4) and request/control
ownership (CF-2, CF-3, DG-1, DG-2) are frozen before any human-projection
phase (DG-3) can be claimed. Benchmark admissibility (EG-1, EG-2, EG-7) is
frozen before any phase's evidence is published as readiness. No phase depends
on an artifact a later phase produces.

### B3 — Each phase is a bounded change brief

Every phase states: goal in one sentence; exact owner seams (file + symbol);
the smallest correction; entry criteria; exit criteria; and named tests. A
phase that crosses a gem interface says so and flags the cross-gem approval
requirement. No phase bundles unrelated findings for convenience.

### B4 — Named acceptance tests, not "add tests"

Each phase names the specific tests it adds or changes, with the concrete
assertion each must make (e.g. "no `decision_evidence` lookup; same occurrence
resumes; wrong-caller answer rejected"). Two-request, replay, and
restart-after-crash cases are named wherever ownership or delivery is touched.

### B5 — Hard-zero preservation is explicit per phase

Every phase names which hard-zero invariants it touches and how it proves it
did not weaken them. A phase that adds a renderer proves it makes no
provider/tool call. A phase that adds an action proves no channel text becomes
authority. `unknown` is never converted to `delivered` or blindly retried.

### B6 — Evidence classes stay separate

The plan never lets a fixture/plumbing test stand in for real-provider,
real-Telegram, or human-comprehension evidence. Each phase says what its tests
prove and, explicitly, what they do not prove. The real-transport/provider gate
is a distinct phase with credential, privacy, cleanup, cost, provenance, and
independent-witness requirements.

### B7 — Scope discipline

The plan rejects, in writing, the discarded options: no second runtime, event
bus, status cache, model narrator, token streaming, generic channel plugin
registry, or new production channel in this program. A new surface is a
decision gate, not a build phase, and is entered only on measured need.

### B8 — Rollout, rollback, and stop conditions

Each phase that changes user-visible or durable behavior states how it rolls
out (fresh-schema, no legacy-row tolerance) and how it rolls back without
replaying an unsafe unknown send. Clarification and projection phases state
their fail-closed stop condition.

### B9 — Sequencing and parallelism are unambiguous

The plan gives one dependency graph and states which phases may proceed in
parallel and which are strict predecessors. It distinguishes "harness may be
built in parallel" from "readiness may be published," matching the roadmap's
own caveat.

### B10 — Honest status and non-goals

The plan states, up front, that it is a plan and not evidence of a working
experience; that the implementation-readiness verdict is NEEDS FIXES until the
gates pass; and it lists explicit non-goals. It does not overclaim that any
phase makes the chat "good" — only what each phase makes true.

## Review lenses the plan must survive

The review loop challenges the plan from each lens and records the result:

- **Product / agent-vision** — does the phase order deliver user-trust value in
  the right sequence, and does it avoid shipping a convincing-but-misleading
  card before its facts are authoritative?
- **Architecture / security / reliability** — are the seams correct, do phases
  preserve ownership/fencing/effect-journal invariants, and is there no hidden
  second state machine?
- **Implementation / evidence** — are the tests real (subprocess, process
  restart, two-ref, independent witness), and is readiness fail-closed?
- **Interaction / attention** — is the human contract bounded, and are noise
  and recovery treated as measured, not asserted?
- **Fourier / cross-scale** — does a local improvement in one phase reverse a
  gain at another scale (worker-health silence, notification feedback, proxy
  readiness)?

## Outcome bar (north star: does executing this make the chat meet expectations?)

B1–B10 grade the plan's *discipline*. They do not grade whether executing it
changes how the chat *feels*. Three prior improvement rounds passed a
discipline-style bar and still did not meet expectations, so the plan must also
pass an outcome bar:

- **O1 — Target experience is defined and user-judgable.** The plan states the
  concrete end-to-end moments a person will judge ("I delegated and it felt
  alive," "it asked me a question and I answered inline," "I came back and knew
  exactly where things stood"), and the acceptance signal is the user trying it
  on a real path — not a passing test.
- **O2 — A felt improvement reaches the user early.** The plan does not defer
  every perceptible change behind the full correctness-and-evidence stack. It
  includes an early, guarded, real-path spike the user can actually try, so
  expectations are checked against reality within the first round, not after
  all phases land. (Invisible correctness rounds are exactly what fell short.)
- **O3 — The right gap is targeted.** The plan distinguishes two failure modes
  and does not assume: (a) *lifecycle communication* — the agent feels dead,
  broken, noisy, or untrustworthy even when its answer is fine; and (b)
  *answer competence* — the agent's actual answers are not useful/smart enough.
  Phases 0–3 address (a) only. If the unmet expectation is (b), the plan says
  so explicitly and names it as a separate program rather than silently hoping
  lifecycle work fixes competence.

## Passing condition

The plan meets the bar when B1–B10 are all satisfied and every review lens
records no unresolved high-severity objection. The review log must show at
least one full iteration in which a lens raised an objection and the plan was
revised to resolve it; a plan that was never challenged has not met the bar.
