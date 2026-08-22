# Frontier round — communication capabilities Tamoz does not have yet

C1–C9 measure what Tamoz can or nearly can do. The frontier round measures what
it **cannot do yet**, so the benchmark pulls the roadmap forward instead of only
guarding what works. These are exactly the surfaces the study deferred: *"Do not
expand groups, media, multi-agent routing, or affirmative remote approvals until
these stages and their evidence gates pass"* (`../../04-tamoz-target-architecture.md`).

Each F scenario is a capability request with an acceptance test. It:

- **fails honestly today** — fail-closed, with a named reason, never a fabricated
  pass;
- **names the smallest increment** to an existing seam that would close the gap;
- **defines the machine-checkable PASS** once built.

When an F scenario starts passing on a real run, it **graduates** into the ladder
and the scoreboard records the date the capability came online.

| Rung | Scenario | Primary axes | The capability it requests |
| --- | --- | --- | --- |
| F1 | [F1-group-and-multi-user-routing.md](F1-group-and-multi-user-routing.md) | `context_integrity`, `commands` | Group / multi-user routing with per-actor isolation and explicit authorization. |
| F2 | [F2-rich-media-turns.md](F2-rich-media-turns.md) | `identity`, `delivery_truth` | Bounded, digest-bound inbound and outbound rich media. |
| F3 | [F3-affirmative-approval-and-multi-agent.md](F3-affirmative-approval-and-multi-agent.md) | `context_integrity`, `commands`, `recovery` | Affirmative Telegram approval and multi-agent routing with authority containment. |

## Why these are fail-closed, not missing tests

The study's non-goals are deliberate: each of these surfaces weakens a current
safety property unless a new contract is built first. Groups break actor
isolation; media breaks the bounded, digest-bound identity contract; affirmative
approval and multi-agent routing break the deny-only posture and delegation
authority containment. The frontier scenario is the acceptance test that must pass
**before** the surface ships — not a reason to ship it early. A run today must
return `UNAVAILABLE` with the named reason; a fabricated pass is a hard-zero.

## Graduation rule

An F scenario graduates when a real run satisfies its defined PASS with two
agreeing witnesses and no hard-zero. On graduation:

1. move the scenario into the C ladder at the rung its difficulty warrants;
2. add its axis to the affected canonical scenarios;
3. record the graduation date and the build in the scoreboard notes.
