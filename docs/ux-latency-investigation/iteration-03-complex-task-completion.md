# Iteration 3 — Complex multi-step task (completion failure)

> Historical measurement from the pre-Phase-3 provider boundary. References to
> RubyLLM describe the measured implementation and are not current support.

## Journey analyzed

Input: `tamoz --root <dir> --json "Read every file in this workspace, explain
what each one contains, and suggest one improvement to calc.rb."` — a
moderately complex read-only task requiring discovery-then-read (live
`deepseek-chat`, workspace: `sample.txt`, `calc.rb`, `notes.md`).

Expected experience: quick acknowledgement, a short plan, directory listing,
per-file reads, a synthesized answer, and a truthful terminal report — in well
under a minute.

This report is the pre-implementation baseline. Durable v2 now accepts a route
provided discovery plan and transitions to an evidence-scoped read-only plan; the
current implementation boundary, including the intentionally absent generic second
discovery pass, is recorded in
[`IMPLEMENTATION_EVIDENCE.md`](IMPLEMENTATION_EVIDENCE.md).

Observed outcome **[measured]**: **exit 1 after 23.6 s and 6+ model calls with
zero tool calls executed.** All 3 plan attempts were rejected by semantic
review; the CLI printed `tamoz: no plan passed review after 3 attempts: the
plan did not pass review; the last feedback is not discloseable`. Raw log:
`tmp/ux-probe/run5.jsonl`.

## Completion breakdown

Execution stopped at the `deliberate` node — it never left planning. Terminal
condition: `PlanRejectedError` (`runtime.rb:275`, attempts cap
`max_plan_attempts = 3` at `runtime.rb:22`). The terminal result is *truthful*
(it does report failure) but *uninformative*: the review feedback that would
let the user help is deliberately withheld ("not discloseable").

The failure mechanism, from the logged review rationales, is a **structural
deadlock between review's concreteness bar and pre-discovery planning**:

- Reviewer (attempt 1): "`read_all_files` is under-specified: it cannot know
  which file paths to read until directory listing is performed."
- Reviewer (attempt 3): "The plan does not explicitly enumerate the actual file
  paths to be read; it relies on dynamic discovery and executor behavior."
- The planner *cannot* enumerate file paths before `list_directory` runs, and
  the reviewer rejects any plan that defers enumeration to execution. Three
  rounds of increasingly detailed plans all fail the same check. The
  planner never receives the structural constraint "discovery-first plans are
  legitimate"; the reviewer never receives "paths cannot be known yet."

This is not a model-quality fluke — the same signature dominates the committed
live evaluation `agenteval/reports/baseline-20260805.json` **[measured]**:
decision `fail`, 10/22 solved, with `diagnose 0/3` and `implement 0/3`, the
failing scenarios ending in "Review (semantic): revise" loops and
acceptance-suite failures. Median scenario duration 35.1 s.

## Inventory of "fails to finish" terminal conditions (from source)

| Terminal condition | Where decided | What the user sees | Truthful? |
|---|---|---|---|
| `PlanRejectedError` (3 attempts) | `runtime.rb:275`; `session_plan_outcomes.rb:66` | "no plan passed review… feedback not discloseable", exit 1 | Yes, but opaque |
| `repair_attempts_exhausted` (2 repairs) | `runtime.rb:181-186`; `session_evidence.rb:155-161` | Answer + "Verification: not satisfied", exit 2 | Yes |
| `repeated_action` stop | `runtime.rb:130-138`; `session_plan_outcomes.rb:115-128` | Verification output; the stall is implicit | Partially — the *stop* is not narrated as the cause |
| `repeated_failure` / `repeated_tool_failure` | `session_evidence.rb:146-154` | Same shape | Partially |
| `repair_plan_rejected` | `session_plan_outcomes.rb:56-64` | Routes to verify, unsatisfied | Yes |
| Budget exhaustion (worker only) | `worker.rb:281-296,401-411` | **Nothing** — no channel notification; operator finds it via `tamoz status` | No — silent to the requester |
| Approval pause in non-interactive mode | `cli.rb:247-250` | Exit 3, descriptor on stderr; durable wait for `tamoz resume` | Yes (CLI) |
| Blocked on unknown effect | `session_evidence.rb:186-203` | Exit 3 + resolve instructions | Yes |
| Observation budget (>160 KiB tool output) | `runtime.rb:13,387-388` | ToolError, exit 1 | Yes |
| Answer produced but not delivered (Telegram) | `comms_gateway.rb:278-279` | Nothing, ever | No |

Interactive CLI turns have **no budget check at all** — budgets are
worker-only (`worker.rb:281-296`), so the two execution environments have
different stop semantics for the same task. **[supported]**

## Planning-quality assessment (per the loop's rubric)

Measured against run5 and the code: plans do define concrete outcomes and
verifiable steps (`done_when` exists), but the plan is **never updated after
new evidence** — there is no re-plan-after-discovery transition, only
re-plan-after-rejection, and each attempt restarts from the same prompt plus
reviewer feedback rather than from accumulated observations. Plans cannot
express "enumerate, then act on what was found" in a way review accepts.
Complete/failed/blocked/cancelled states exist and are durable; what is
missing is the *decomposition* path that would let a complex task make partial
verified progress instead of all-or-nothing acceptance of a static plan.

Net assessment: on simple tasks planning adds latency without value
(iteration 1); on genuinely complex tasks it blocks execution at the gate.
Planning is currently helping neither end. **[supported + measured]**

## Five Whys

Symptom: complex tasks frequently fail to finish.

1. Why did run5 fail? Three semantic-review rejections → `PlanRejectedError`.
2. Why did review reject executable-looking plans? Reviewer demands concrete
   arguments (exact file paths) that only exist after discovery runs.
3. Why can't the system satisfy that demand? The graph has one
   deliberate-then-execute ordering per phase; there is no interleaved
   "discover → re-plan with evidence" cycle, so concreteness and
   pre-execution review are mutually exclusive for discovery-dependent tasks.
4. Why does the cap make it fatal? Attempts are capped at 3 and malformed
   model output burns attempts too (run2 attempt 1 was a `Review (protocol):
   revise`), so a systematic planner/reviewer disagreement is guaranteed to
   exhaust them.
5. Why is the failure useless to the user? Review feedback is classified as
   non-discloseable and the stop reasons (`repeated_action`, budget) are not
   narrated, so the user cannot distinguish "bad task" from "system
   limitation" nor fix the request. Root cause: **a single static plan-review
   gate applied before any evidence exists, plus stop-paths that don't report
   themselves.**

## Findings

| # | Finding | Severity | Frequency | Confidence | Components | User impact |
|---|---|---|---|---|---|---|
| 3.1 | Discovery-dependent plans are structurally unreviewable: reviewer demands concrete post-discovery arguments; no discover→re-plan cycle exists | Critical | Every task whose steps depend on discovery (diagnose/implement classes: 0/6 in agenteval) | **[measured]** (run5 + agenteval baseline) | `deliberation.rb`, `runtime.rb:213-306`, session graph `session.rb:341-366` | Whole task classes fail before doing any work |
| 3.2 | Plan-attempt cap (3) is consumed by protocol/parse errors and by systematic reviewer disagreement; exhaustion is fatal | High | Common on complex tasks | **[measured]** run2/run5; **[supported]** `runtime.rb:261-273` | `runtime.rb`, `session_plan_attempt.rb` | 20+ s spent, nothing attempted, exit 1 |
| 3.3 | Stop reasons are not narrated: "feedback not discloseable", repeated-action stops implicit, budget stops silent to the channel | High | Every non-clean stop | **[supported]** | `cli.rb:66-69`, `worker.rb:301-320`, `session_plan_outcomes.rb` | User cannot recover, rephrase, or approve — abandonment |
| 3.4 | No partial-progress model: verification is all-or-nothing at turn end; completed verified steps are not reported as progress toward the goal | Medium | Long tasks | **[supported]** | `session_lifecycle.rb:105-147` | Long work indistinguishable from no work until the end |
| 3.5 | Budget semantics differ between interactive (none) and worker (enforced, silently) paths | Medium | Worker tasks | **[supported]** | `worker.rb:281-296` vs absence in `cli.rb` | Inconsistent behavior; silent unattended stops |
| 3.6 | Model context is rebuilt statelessly per stage; review/plan/verify re-send full context (cost × latency multiplier on loops) | Medium | Every revise/repair loop | **[supported]** | `ruby_llm_model.rb:49-56` | Loops cost 2× model calls each, slowing convergence |

## Recommended change (behavior, not code)

- Split planning into **discovery-tolerant** and **commitment** phases: plans
  may declare discovery steps whose outputs feed a *re-plan with evidence*
  transition; review applies its concreteness bar only to steps that consume
  already-available evidence. Mutation authority stays bound to the reviewed
  action plan exactly as today — only the timing of concreteness changes.
- Make every stop self-narrating: terminal messages name the stop reason, the
  last reviewer objection (in summarized, discloseable form), and the concrete
  user action that would unblock (rephrase / approve / raise budget / resume).
- Report verified partial progress at verify time ("3 of 5 steps verified;
  stopped because …") so incomplete ≠ invisible.
- Align budget enforcement and notification across interactive and worker
  paths; route worker budget stops to the channel sink.
- Tradeoffs: re-planning adds a model call per discovery round (offset by
  fewer doomed full attempts); disclosing review rationale needs a sanitization
  pass to avoid leaking system-prompt internals.

## Validation plan

- Re-run `agenteval` pack after change: target diagnose + implement ≥ 2/3 each,
  zero `PlanRejectedError` on discovery-dependent scenarios, decision ≥ current
  10/22 baseline improved, hard gates (`no_false_success`) still zero.
- New scorecard cases: "discovery-dependent plan completes", "plan rejection
  message names actionable cause", "budget stop notifies the requester".
- Thresholds: complex read-only corpus (≥10 tasks) completion ≥ 80%; median
  model calls per completed complex task ≤ current baseline.

## Open questions

- Whether deeper models (gpt-5-class) escape the review deadlock — the
  mechanism is structural, so confidence is high the failure survives a model
  swap, but a one-run cross-check on a second provider would firm this up.
  **[hypothesis: model-independent]**

## Next iteration

Consolidate the live-run latency data (all four experiments) and the
observability gaps that made stage timing hard to obtain.
