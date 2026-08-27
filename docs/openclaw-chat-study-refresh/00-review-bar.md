# OpenClaw/Tamoz chat experience refresh — review bar

## Purpose

This refresh is a decision-grade re-review of `docs/openclaw-chat-study/` and
the current Tamoz implementation on this branch. It must explain why the
implemented durability and lifecycle work may still feel unhelpful to a human
operator, identify missed weaknesses, and define the smallest useful next
program for Telegram, durable CLI, and a future channel-neutral surface.

The output is a product-and-architecture study, not a claim that a fixture
provider is intelligent and not an excuse to create a second agent runtime.

## Required evidence discipline

Every material statement must be classified as one of:

- **Fact** — verified in current source, test, documented behavior, or a
  reproducible runtime observation.
- **Inference** — a reasoned conclusion from named facts.
- **Hypothesis** — plausible user or model behavior that still needs measurement.
- **Proposal** — a recommended future behavior, boundary, or experiment.
- **Evidence gap** — an important claim the repository cannot currently prove.

Each fact needs an exact repository-relative path plus symbol/line or test name.
Each runtime claim needs the command, environment class, inputs, and output. A
focused test is plumbing evidence; it is not perceived-quality or real-provider
evidence. Claims about OpenClaw must be traced to the existing study's cited
source or to a freshly verified source path. Do not silently promote a design
preference to an OpenClaw fact.

## Completeness bar for every specialist lane

The report must:

1. read the prior study, its review log, implementation plan, benchmark protocol,
   and current evidence artifacts before reaching conclusions;
2. inspect the current code and tests end to end for the assigned seam;
3. distinguish what the prior study already closed from what remains open,
   stale, contradictory, or insufficiently measured;
4. name the user-visible failure mode and the underlying system cause;
5. rank recommendations by user value, safety/reliability risk, dependency, and
   implementation cost;
6. map each recommendation to an existing Tamoz owner/seam, with an explicit
   reason if a new seam is genuinely necessary;
7. define acceptance scenarios, failure cases, telemetry/benchmark measures,
   and a real-transport/real-provider evidence gate where relevant;
8. record disagreements, uncertainty, rejected complexity, and non-goals; and
9. end with a verdict: `MEETS BAR`, `MEETS BAR WITH GAPS`, or `NEEDS FIXES`,
   including the exact missing evidence or correction required.

## Specialist outputs

### Lane A — gap audit of the previous study

Find omissions, stale claims, contradictions, untested assumptions, and user
experience problems that survived Phases 0–3. Reconcile the study against the
current source tree and evidence. Do not merely summarize the old report. The
minimum output is a prioritized gap ledger with evidence, root cause, impact,
and a proposed closure test or deliberate non-goal.

### Lane B — interaction and product experience

Study how a person actually asks for work, waits, changes direction, answers a
question, recovers from failure, and returns later. Design a more interactive,
enjoyable, and productive conversation contract for Telegram and durable CLI.
Include concrete example transcripts, attention/noise tradeoffs, progressive
disclosure, user controls, and measures for responsiveness, comprehension,
trust, completion, and recovery. Keep model answer quality separate from chat
plumbing quality.

### Lane C — chat/Telegram architecture and channel expansion

Trace gateway, admission, request, session, worker, event, projection, outbox,
drainer, Telegram identity, and CLI seams in the current code. Propose the
smallest architecture that improves interaction while preserving authority,
effect journaling, ownership fencing, delivery ambiguity, and channel-neutral
semantics. Assess whether and when another channel is justified, with a typed
channel contract, capability matrix, migration order, and explicit security and
operability gates.

## Brainstorming bar

After the three reports pass their bars, two independent agents must challenge
the consolidated findings:

- **Facilitator** — run a bounded brainstorming session that turns the evidence
  into divergent options, clusters them, exposes assumptions, and converges on
  decision-ready bets without allowing unsupported ideas to become facts.
- **Fourier lens** — examine the problem at multiple scales and frequencies:
  individual turn, conversation, work session, operator workflow, channel,
  organization, and long-term learning/measurement. Look for periodic failure,
  feedback, queueing, latency, information loss, and cross-scale interactions.

The session must produce options, tensions, synthesis, discarded ideas, and a
small set of testable bets. It must not turn brainstorming into implementation
authorization by itself.

## Product-engineering review bar

Three final reviewers must independently assess the consolidated study through
different lenses: (1) product usefulness and agent vision, (2) architecture,
security, reliability, and channel boundaries, and (3) implementation/evidence
readiness. Each must identify hard-zero risks, missing seams/tests, scope creep,
and the smallest correction. The final package cannot be marked ready while a
reviewer has an unresolved high-severity finding.

## Completion bar for the package

The refresh folder is ready only when it contains an indexed README, this bar,
the three specialist reports, the two brainstorming reports, the consolidated
study, the three product-engineering reviews, a correction log, a decision and
implementation roadmap, and an evidence index. The consolidated document must
separate current facts, hypotheses, proposals, and evidence gaps; preserve the
prior study's hard-zero safety invariants; state what is not proven; and be
concrete enough to drive bounded implementation slices without repeating this
investigation.
