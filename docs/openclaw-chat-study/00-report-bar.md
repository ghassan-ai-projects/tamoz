# Chat experience study: report quality bar

## Purpose

This study is complete only when it gives Tamoz a trustworthy, implementation-ready
understanding of why OpenClaw feels useful in Telegram and CLI, which parts of that
experience are product choices versus infrastructure, and what Tamoz should change.

The report is an engineering and product decision artifact. It is not a feature wish
list, a shallow file tour, or a claim that Tamoz should copy OpenClaw wholesale.

## Scope

The study covers:

- OpenClaw's end-to-end communication lifecycle: inbound message, identity and
  routing, session selection, command handling, model/tool execution, streaming,
  persistence, delivery, retries, and failure recovery.
- Telegram and CLI behavior, plus the shared abstractions that make other channels
  possible.
- User-visible interaction patterns: first use, normal conversation, long-running
  work, approvals, errors, cancellation, progress, context control, and multi-session
  behavior.
- Guards and trust boundaries: authorization, pairing, allowlists, rate/size limits,
  prompt-injection assumptions, tool policy, sandboxing, secrets, and observability.
- Tamoz's current behavior through the real CLI, Telegram, comms, session, graph,
  effect, storage, and test seams.
- A proposed Tamoz target model, migration increments, acceptance criteria, and tests.

Out of scope unless they materially affect communication: unrelated OpenClaw product
surfaces, broad model benchmarking, visual redesign of a web UI, and implementation
changes to Tamoz. This phase produces the decision record for a later redesign.

## Evidence standard

Every material claim must be traceable to one of these evidence types:

1. **Source code** — exact repository-relative file path and symbol or line range.
2. **Tests or fixtures** — exact test path and test name, with what behavior it proves.
3. **Documentation/configuration** — exact path and section, used only for stated
   intended behavior; code/tests take precedence for actual behavior.
4. **Runtime observation** — command or scenario, inputs, and observed output. Mark
   environment-dependent observations explicitly.
5. **Inference** — a reasoned conclusion built from cited evidence, labeled as an
   inference and separated from direct fact.

Use confidence labels:

- **High**: confirmed by code plus a test or repeated runtime observation.
- **Medium**: confirmed by code or documentation and corroborated by one other source.
- **Low**: plausible but not yet verified; it must become a follow-up investigation,
  not a design premise.

Do not present a design preference as an OpenClaw fact. Do not infer behavior from a
filename alone. When code and documentation disagree, state the disagreement.

## Completeness dimensions

The OpenClaw review must answer all of these:

| Dimension | Required questions |
| --- | --- |
| Product model | What is the user's mental model? What makes a message feel handled? |
| Lifecycle | What exact stages transform an inbound message into a delivered answer? |
| Shared architecture | Which Gateway, session, event, channel, and agent seams are shared? |
| Telegram | How are pairing, allowlists, commands, replies, media, streaming, limits, and failures handled? |
| CLI | How does interactive and one-shot CLI behavior differ? How is output and failure presented? |
| Context | How are sessions, history, compaction, reset/new, thinking, verbosity, usage, and traces controlled? |
| Work execution | How are tools, approvals, progress, cancellation, retries, and long-running work exposed? |
| Safety | What are the trust boundaries and the guards at every boundary? |
| Reliability | What happens on duplicates, restarts, timeouts, partial streams, provider failure, and channel failure? |
| Operability | What is logged, persisted, observable, diagnosable, and recoverable? |
| Tests | Which scenarios are covered, and which important cases are absent? |
| Tradeoffs | What complexity, coupling, or trust assumptions does each pattern introduce? |

The Tamoz review must answer the same questions, then add:

- Where Tamoz already has the necessary seam and should extend it.
- Where behavior is missing, fragmented, or accidentally user-hostile.
- The root causes of the current poor experience, not only symptoms.
- A target architecture mapped to existing Tamoz modules and boundaries.
- A staged plan with explicit non-goals, risks, tests, telemetry, and rollout gates.

## Required report artifacts

The final folder must contain:

- `00-report-bar.md` — this acceptance bar and definition of done.
- `01-openclaw-technical-report.md` — evidence-backed architecture and behavior.
- `02-openclaw-product-report.md` — plain-language experience patterns and reasons they matter.
- `03-tamoz-current-state.md` — current behavior, gaps, and root-cause analysis.
- `04-tamoz-target-architecture.md` — proposed model and boundaries.
- `05-comparison-and-priorities.md` — OpenClaw-to-Tamoz mapping, priorities, and tradeoffs.
- `06-scenario-matrix.md` — lifecycle scenarios, guards, expected behavior, and test gaps.
- `07-evidence-index.md` — source/test/runtime citations and confidence labels.
- `08-review-log.md` — the two five-review passes, disagreements, corrections, and final audit.
- `README.md` — reading order, executive summary, and definition of done status.

## Decision quality gates

The report passes when:

- A reader can trace every important claim to evidence without searching the whole repo.
- The technical and non-technical reports agree on the same lifecycle and tradeoffs.
- Telegram and CLI are treated as concrete user journeys, not only adapters.
- Security and reliability are described at the boundary where they are enforced.
- Tamoz recommendations name existing files/modules to extend and do not invent
  duplicate machinery.
- Recommendations are prioritized by user value, risk reduction, dependency, and cost.
- At least five meaningful end-to-end scenarios have acceptance criteria and test ideas.
- Independent reviewers have challenged omissions and overclaims; resolved disagreements
  are recorded in the review log.
- The final audit can distinguish confirmed behavior, absent behavior, and proposed design.

## Definition of done

The study is done when all required artifacts exist, all completeness dimensions are
addressed, the evidence index has no unresolved high-impact claims, the review log
records both five-agent passes and the correction loop, and the final recommendations
are concrete enough to become a sequence of Tamoz implementation slices without first
repeating this investigation.
