# Approval / permission policy redesign

Status: design complete and reviewed; implementation not started. The
implementation plan (`05`) is ready for a coding agent to execute.

This folder isolates every *policy* decision in tamoz — "does this action need
approval, and under what evidence?" — into one dedicated gem, `tamoz-approval`,
whose entire policy content is data (`policy/*.yaml`, digest-pinned). It follows the
same discipline as the OpenClaw intelligence study (`docs/openclaw-intelligence-study/`):
an explicit acceptance bar, evidence traced to source, independent staff reviews, an
acceptance-scenario matrix, and a phased plan mapped to real seams.

## Executive conclusion

"Approval" in tamoz today is three mechanisms sharing one word, with the rule that
answers "does this need approval?" split across a nine-method delegation chain in
three gems, the channel-evidence policy frozen in a Ruby constant, no scoped grants
(the only escape from per-call prompting is a blanket `--all` flag), an unanswered
approval that parks the turn forever, and denial that kills the turn silently
(`02-current-state-audit.md`).

The redesign (`03-redesign-adr.md`) converges the two local pipelines onto one
`Engine#decide`, moves all policy content into digest-pinned YAML, replaces the `--all`
floodgate with session-scoped grants that opaque-argv tools can never hold, makes
denial a structured result the model reacts to, and delivers policy changes to live
workers through a validate-before-activate reload. The stream relay (Pipeline C) is
argued out of scope as a pure relay, not a policy owner. No legacy shims: the old
constant, the classification chain, `ApprovalDeniedError`, and the scheduler's dead
hash are deleted outright.

## Reading order

1. [00-acceptance-bar.md](00-acceptance-bar.md) — the contract every other document is
   graded against: end-state, global invariants, hard-zero failures, definition of done.
2. [01-independent-study.md](01-independent-study.md) — green-field study: what
   approvals protect against, policy-model options, prior art, the recommended stack.
3. [02-current-state-audit.md](02-current-state-audit.md) — the current three-pipeline
   reality, every decision point with `file:line`, strengths, weaknesses, coupling.
4. [03-redesign-adr.md](03-redesign-adr.md) — the decision: the gem, the interface,
   policy-as-data, pipeline convergence, the weakness/strength mapping, review
   incorporation (rev 2).
5. [04-review-security.md](04-review-security.md),
   [04-review-simplicity.md](04-review-simplicity.md),
   [04-review-api.md](04-review-api.md) — three independent staff reviews; every
   finding is mapped and resolved in `03` §10.
6. [05-implementation-plan.md](05-implementation-plan.md) — the executable plan: 12
   ordered steps, each a single green commit, mapped back to the ADR and forward to
   the acceptance scenarios.
7. [06-acceptance-scenarios.md](06-acceptance-scenarios.md) — the end-to-end approval
   journeys the finished system must pass, each an acceptance test with a hard-zero tag.
8. [07-evidence-index.md](07-evidence-index.md) — every load-bearing `file:line` claim,
   its confidence, and its re-verify-at-implementation status.

## Owner directives (binding on every document here)

- **Simpler, materially.** The redesign must reduce decision points and policy owners,
  not relocate them. The complexity budget in `03` §6 is the scorecard.
- **Policy/profile changes never touch `tamoz-core` / `tamoz-agent`.** Reclassifying a
  tool to a stricter tier is a YAML edit. This is the headline goal and the first
  thing the acceptance bar checks.
- **No backwards compatibility.** Old tables, code paths, and profile keys are deleted
  in the step that replaces them — no shims, no legacy-row handling. Databases may be
  reset.
- **Real LLM, never fake; tests are plumbing.** Fixture/scripted tests prove
  invariants; they are never presented as evidence that the *policy* is well-authored.
  That is what the `simulations:` block and a real run demonstrate.

## Status

| Gate | Status |
| --- | --- |
| Green-field design study | Complete (`01`) |
| Current-state audit with `file:line` evidence | Complete (`02`) |
| Redesign ADR | Complete, rev 2 (`03`) |
| Three independent staff reviews | Complete; all MUST/SHOULD/NIT resolved (`03` §10) |
| Acceptance bar written down | Complete (`00`) |
| Acceptance-scenario matrix | Complete (`06`) |
| Evidence index with verified anchors | Complete (`07`) |
| Implementation plan | Ready for execution (`05`) |
| Implementation | Not started |

No production code is changed by this study. The plan changes code; nothing in it has
been executed yet.
