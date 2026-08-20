# Intelligence, tools, and capabilities study: report quality bar

## Purpose

This study is complete only when it explains, with evidence, why OpenClaw feels
more capable than Tamoz, how its intelligence and tool system actually works,
which autonomy patterns are safe to reuse, and how Tamoz can gain capability
without weakening its durability, authority, or audit guarantees.

“Intelligence” in this study means observable capability: selecting useful
actions, using tools, maintaining state, recovering from failure, and completing
multi-step work. It does not mean claiming that a model is generally smarter
based on a few successful answers.

The result must be an engineering and product decision record, not a feature
wish list or a catalog of tool names.

## Scope

The OpenClaw review must cover:

- agent loop, planning, routing, model selection, continuation, and stopping;
- core tools and tool groups, schemas, discovery, registration, and invocation;
- workspace/config/state inspection and self-modification behavior;
- database, filesystem, shell, browser/web search, messaging, and MCP access;
- memory, transcript, context compaction, session continuity, and delegation;
- autonomous triggers, scheduled/background work, retries, and approvals;
- capability policy, trust boundaries, sandboxing, secrets, prompt injection, and
  confirmation gates;
- durable effects, idempotency, concurrency, rate/size budgets, and recovery;
- Telegram, CLI/TUI, and shared capability surfaces;
- observability, tests, evals, failure modes, and operator recovery;
- the user-visible reasons the system feels capable.

The Tamoz review must answer the same questions and additionally identify:

- existing Tamoz seams to extend rather than duplicate;
- capabilities already present but hidden or fragmented;
- missing capabilities and unsafe capability shortcuts;
- a target intelligence architecture mapped to real modules and boundaries;
- staged implementation slices, tests, telemetry, and explicit non-goals.

## Evidence standard

Every material claim must be traceable to:

1. source code, with a repository path and symbol or line;
2. tests or fixtures, with the behavior they prove;
3. documentation/configuration, clearly marked as intended behavior;
4. runtime observation, including command/scenario and environment limits; or
5. inference, explicitly labeled and derived from cited evidence.

Use these confidence labels:

- **High** — source plus focused test or repeated runtime observation;
- **Medium** — source/documentation plus corroboration, but a live or composed
  path remains unverified;
- **Low** — plausible inference requiring follow-up before becoming a design
  premise.

Tool existence is not proof of useful autonomy. A tool test is not proof that an
agent selected the tool correctly. A real-provider run is evidence for that run,
not a general intelligence guarantee.

## Completeness dimensions

| Dimension | Required questions |
| --- | --- |
| Intelligence model | What loop turns a request into actions, observations, decisions, and stopping? |
| Capability catalog | Which tools exist, how are they grouped, discovered, described, and versioned? |
| Invocation | How are schemas validated, calls authorized, results bounded, and failures represented? |
| External access | How do web, databases, MCP, shell, filesystem, and messaging differ in authority and durability? |
| Self-inspection | Can the agent inspect config, state, health, logs, sessions, and tool availability? |
| Self-modification | What can it change, under what confirmation, and how is rollback/audit handled? |
| Autonomy | What triggers work, how are loops bounded, and when does the system ask the user? |
| Context/memory | How are history, memory, summaries, artifacts, and cross-session facts managed? |
| Multi-step work | How are plans, substeps, delegation, parallelism, retries, and continuation handled? |
| Safety | Where are authority, sandbox, secrets, injection, approval, and egress guards enforced? |
| Reliability | What happens on duplicate calls, crashes, timeouts, partial results, and ambiguous effects? |
| Product experience | Why does the user perceive capability, and how is uncertainty communicated? |
| Operability | What is observable, explainable, recoverable, and measurable? |
| Tests/evals | Which capability journeys are covered, and which are only asserted locally? |
| Tradeoffs | What complexity, latency, cost, coupling, and trust assumptions are introduced? |

## Required artifacts

The dedicated folder must contain:

- `00-report-bar.md` — this acceptance bar and definition of done;
- `01-openclaw-technical-report.md` — architecture, loop, tools, capabilities,
  guards, and implementation evidence;
- `02-openclaw-capability-report.md` — plain-language capability model and why
  the system feels more intelligent;
- `03-tamoz-current-state.md` — Tamoz's current intelligence/tool surface and
  root causes of capability gaps;
- `04-tamoz-target-architecture.md` — target intelligence architecture mapped to
  existing Tamoz seams;
- `05-comparison-and-priorities.md` — adopt, adapt, reject, and staged order;
- `06-capability-scenario-matrix.md` — user journeys, guards, test gaps, and
  acceptance criteria;
- `07-evidence-index.md` — claim-to-source/test/runtime index and confidence;
- `08-review-log.md` — two five-agent passes, disagreements, corrections, and
  final audit;
- `README.md` — reading order, executive conclusion, and study status.

## Decision-quality gates

The report passes when:

- the OpenClaw and Tamoz reports distinguish model behavior from runtime
  machinery and tool availability;
- every important capability claim names the actual registry, loop, adapter,
  policy, or test that supports it;
- the analysis distinguishes “tool exists,” “tool is reachable,” “tool is
  authorized,” and “agent uses it effectively”;
- self-inspection and self-modification are analyzed as separate risk classes;
- MCP, web, database, shell, filesystem, and messaging access are not treated as
  interchangeable capabilities;
- recommendations extend existing Tamoz effect, capability, session, and
  outbox seams instead of inventing a second runtime;
- at least eight end-to-end capability scenarios have acceptance criteria;
- five independent reviewers have challenged omissions and overclaims in both
  repositories;
- the final roadmap puts authority, durability, and observability before breadth;
- unresolved live/runtime gaps are explicit rather than hidden.

## Definition of done

The study is done when all required artifacts exist, all completeness dimensions
are addressed for both systems, high-impact claims have indexed evidence or an
explicit verification task, the two five-agent passes and correction loop are
recorded, and the roadmap is concrete enough to become implementation slices
without repeating this investigation.
