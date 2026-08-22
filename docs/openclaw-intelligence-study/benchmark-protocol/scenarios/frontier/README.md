# Round F — Frontier (capability-forcing) scenarios

These scenarios are **not** meant to pass today. They describe things a genuinely
capable agent should do that Tamoz **cannot do yet**, so the benchmark can pull
the roadmap forward instead of only guarding what already works. This is the
same idea as the repo's autonomy scorecard: a **milestone gate**, not a
regression gate — it "describes the product Tamoz is being built into and fails
until that product exists."

T1–T11 measure capabilities Tamoz has or nearly has. Round F measures the ones it
is missing. The two are scored differently and must never be confused: a T-rung
failure is a **regression**; an F-rung failure is a **known frontier** with a
named increment.

## The honesty rule for a not-yet-supported capability

A frontier scenario is only useful if "we can't do this yet" is a **truthful,
fail-closed result**, never a fabricated one. The capability seven-tuple
(`exists → reachable → authorized → attempted → effective → completed → verified`,
from [../../01-protocol-design.md §3](../../01-protocol-design.md#3-the-capability-state-model-already-in-readinessrb))
is the mechanism: today, each F scenario stops at a specific field and **names
the gap**. The `native-envelope` track already reports capability availability
separately from model performance — Round F is that track, aimed at the future.

So every F scenario is defined by four things:

1. **The gap** — what Tamoz cannot do, and the exact seven-tuple field it stops
   at today (`exists=false`, `reachable=false`, …).
2. **Today's honest result** — the fail-closed behavior the current system must
   produce (an `unavailable` mission, a typed refusal), which is a PASS *for
   honesty* even though the capability is absent.
3. **The increment** — the smallest extension to an existing seam that closes the
   gap (never a new parallel runtime — same rule as the plan).
4. **The acceptance bar** — the machine-checkable PASS once the capability exists,
   and the anti-cheat that stops a faked or scripted "capability."

## The frontier round

Roughly ordered by how far each is from today's surface (the number is an id,
not a rank). Each names the seam its increment extends.

| # | Scenario | Missing capability | Increment extends |
| --- | --- | --- | --- |
| F1 | [F1-live-browser-actuation.md](F1-live-browser-actuation.md) | Real governed web navigation/actuation | `GovernedBrowserSource` (defined, unwired + adapter absent → fail-closed today) |
| F2 | [F2-heterogeneous-tool-composition.md](F2-heterogeneous-tool-composition.md) | Compose 2+ real external services with governed data-flow between them | multi-source capability host + `GovernedDatabaseSource` + provenance chaining |
| F3 | [F3-closed-loop-self-improvement.md](F3-closed-loop-self-improvement.md) | Author a change to itself that *measurably* improves, proven on the benchmark | `Improvement::CandidateLifecycle` ↔ the scoreboard |
| F4 | [F4-novel-skill-acquisition.md](F4-novel-skill-acquisition.md) | Recognize a capability gap, author a governed skill, and use it in-session | `Tools::Skills` + `load_skill` + candidate lifecycle for skill scope |
| F5 | [F5-long-horizon-autonomous-project.md](F5-long-horizon-autonomous-project.md) | A multi-day project with self-set milestones and scheduled continuation | scheduler occurrences + durable session + a project/milestone ledger |
| F6 | [F6-calibrated-uncertainty-and-abstention.md](F6-calibrated-uncertainty-and-abstention.md) | Calibrated confidence and abstention when it should not act | adaptive decision confidence ↔ the protocol's `calibration`/`risk_coverage` scoring |
| F7 | [F7-self-inspection-surface.md](F7-self-inspection-surface.md) | Agent-facing inspection of its own durable state (machinery for the catalog's `self-inspection` mission) | a governed read-only self-inspection capability over the runtime's status/trace records |
| F8 | [F8-agent-initiated-deferred-work.md](F8-agent-initiated-deferred-work.md) | Agent-created schedules (creation is operator-only today) | `ScheduleStore#put_schedule` behind an approval-gated capability + per-occurrence budgets |
| F9 | [F9-agent-initiated-clarification.md](F9-agent-initiated-clarification.md) | Agent-initiated free-form clarification (elicitation is MCP-originated only) | the elicitation/interrupt machinery, agent-initiated direction |

Agent-vs-agent (facing a *real* autonomous adversary rather than a scripted
one) is the horizon beyond this round — noted in F6's "what comes after."

## How Round F is driven and scored

A driver uses the same evidence and result-state contract as a T scenario (see
[../00-implementation-bar.md](../00-implementation-bar.md)); the frontier
documents use gap/increment/acceptance headings rather than pretending that an
unimplemented capability has a runnable T-tier fixture. There are two
differences in execution:

- **Today (capability absent):** the PASS is the *honest fail-closed* result — the
  mission is `unavailable`/`blocked`, the seven-tuple stops at the named field,
  and no fabricated success appears. A silent fallback or a faked result is the
  **only** way to fail an F scenario today (it is a `silent_fallback` hard-zero).
- **After the increment ships:** the same scenario is re-run against the
  acceptance bar. When it passes on a real-provider run, it **graduates** into the
  regular ladder (renumbered as a T-rung) and the scoreboard records the date the
  capability came online — so "we added a capability" is a dated, attributable,
  measured event, not a claim.

This makes the frontier round a **roadmap driver**: each F scenario is a
capability request with an acceptance test attached, and the benchmark tells you
the day it starts passing.

## Reading Round F today

- **Honest-absent (the expected result now)** — every F scenario stops at its
  named seven-tuple field and fails closed. That is the correct current state and
  it defines the backlog.
- **Dishonest-absent (a real bug)** — an F scenario "passes" by faking the
  missing capability (a silent fallback, a fabricated result, a scripted
  improvement). This is the one outcome Round F must never produce and the most
  important thing it can catch about the *current* system.
- **Graduated** — the increment shipped and the scenario passes its acceptance bar
  on a real run. Move it into the ladder and record the capability's arrival.
