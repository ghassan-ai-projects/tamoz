# CF03 reviewed plan, approval, execution, verification, and repair — IMPROVE

Row / queue / baseline (commit, date) / analyst / budget

- Row: **CF03** — reviewed plan, approval, execution, verification, and repair.
- Queue: cross-gem flow inventory in `COVERAGE.md`.
- Baseline: branch `audit-15-09`, code commit `582ae55`, 2026-09-15.
- Analyst: coordinator direct read-only review after the standalone cross-flow scan.
- Budget: bounded source review and focused contracts; no implementation.

## Scope and source map

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-agent-session/lib/tamoz/agent/session_deliberation.rb` | 29-99 | plan/review loop and repair-phase planning |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_plan_attempt.rb` | 29-45, 120-235 | model plan, structural review, semantic review, acceptance/clarification |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb` | 20-48, 60-98, 113-195, 213-301 | step gate, approval interrupt, effect dispatch, outcome recording |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` | 19-53, 75-185, 279-330, 362-390 | model/tool effects, intent binding, approval projection |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_lifecycle.rb` | 19-41, 81-104, 116-188 | evaluation, verification, terminal and check enforcement |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb` | 20-65, 88-181, 192-216 | bounded observations, failure signatures, repair and blocked states |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` | 33-109, 141-221, 243-328 | durable effect decision, execution, failure/unknown and reconciliation |
| `gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb` | 161-169, 201-247 | sealed local/MCP admission and effect classification |
| `gems/tamoz-tools/lib/tamoz/tools/toolbox.rb` | 25-72, 90-164 | validated tool catalog, previews, effects and output bounds |
| `gems/tamoz-tools/lib/tamoz/tools/local_dispatcher.rb` | 25-64 | local capability host dispatch and safety mapping |
| `gems/tamoz-approval/lib/tamoz/approval/engine.rb` | 31-100, 225-334 | policy decision, durable answer resolution and grant lifecycle |
| `gems/tamoz-approval/lib/tamoz/approval/evaluator.rb` | 15-80 | deny-first policy evaluation and decision construction |
| `gems/tamoz-agent/lib/tamoz/agent/worker.rb` | 434-505, 754-777 | decision claim, approval-engine resolution, resume and delivery |
| `gems/tamoz-agent/lib/tamoz/agent/runtime/step_execution.rb` | 15-173 | one-shot plan gate and approval parity |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_graph.rb` | 43-83, 107-156 | durable node/branch and state-channel ordering |
| `test/agent_acceptance_workflow_test.rb` | 1-250 | end-to-end durable approval and resume contract |
| `test/approval_engine_test.rb` | 1-300 | policy, decision, resolve and grant contracts |
| `test/agent_decision_flow_test.rb` | 1-230 | exact interrupt-set routing and decision consumption |
| `test/healing_remediation_test.rb` | 1-220 | bounded repair/remediation behavior |

The flow starts when `SessionDeliberation` accepts a reviewed plan, then enters
`SessionSteps#step_gate`. A tool step is argument-resolved, bounded, converted
to an effect intent, and evaluated by the approval engine. An ask becomes a
durable graph interrupt. The production worker claims the matching decision,
resolves the engine record, resumes the same request, and the graph dispatches
the committed intent through `EffectDispatcher`. The outcome becomes bounded
observation/effect-receipt evidence, `evaluate` routes to the next step or
verification, and repairable failures return through a bounded repair plan.
The one-shot runtime follows the same approval engine but resolves `:once`
inside its synchronous step gate (`runtime/step_execution.rb:112-173`).

## Behavior path

1. `SessionDeliberation#deliberate` builds a bounded planning context and runs
   up to `max_plan_attempts`; `SessionPlanAttempt` records the plan, performs
   deterministic structural checks, then obtains and records the semantic
   review (`session_deliberation.rb:29-99`; `session_plan_attempt.rb:29-45,
   120-235`). Acceptance stores the plan digest and resets the step cursor
   (`session_plan_outcomes.rb:42-52,107-135`).
2. `SessionSteps#step_gate` resolves mutation arguments once, checks observation
   headroom, builds the intent, and asks `SessionEffects#decide_step_tool` for
   the policy decision (`session_steps.rb:20-34,60-90`; `session_effects.rb:362-375`).
   A replayed gate reuses the local journaled verdict rather than deciding twice.
3. For an ask, the descriptor contains the decision id, policy reason/rule,
   plan/step digests, arguments and preview (`session_steps.rb:147-180`). The
   graph pauses before the update containing the approval record. The worker is
   the courier: it claims the exact interrupt-set decision, calls
   `Approval::Engine#resolve`, supplies boolean answers, resumes the same
   occurrence, and consumes the decision record (`worker.rb:434-478,491-505`).
4. After resume, the graph records the approval and committed effect intent, then
   `step_execute` finds that intent and dispatches through the effect journal
   (`session_steps.rb:37-48,183-195`; `session_effects.rb:75-85`). The dispatcher
   fences `prepare/start/complete`, returns recorded receipts on replay, and
   makes an ambiguous effect terminal `:unknown` (`effect_dispatcher.rb:33-109,
   175-221`).
5. A successful result is bounded and recorded with provenance, bytes, effect
   key and receipt; a repairable failure becomes a typed failure observation.
   `evaluate` routes a failed check or failure signature through bounded repair,
   while an unknown effect blocks the session (`session_steps.rb:213-301`;
   `session_evidence.rb:88-181`; `session_lifecycle.rb:19-31,81-104`).
6. Verification is itself a journaled model call. The parsed answer is forced
   unsatisfied when a configured check did not pass, and terminal assembly
   records the final reason, blocked state, and optional memory admission
   (`session_lifecycle.rb:33-75,116-188`).

## Lens: correctness

Reviewed. The source path preserves plan digest → approval descriptor → effect
intent → receipt → verification ordering. The approval decision is resolved
before the graph resume, and `journaled_verdict` prevents a resumed gate from
asking twice for the same plan/step. The durable acceptance workflow passed **1
run / 33 assertions / 0 failures**; exact interrupt-set routing passed **5 runs
/ 23 assertions / 0 failures**.

The flow remains IMPROVE because the accepted approval cross-boundary findings
are real: scheduled occurrences ignore their persisted approval profile
(`F13-COR-01`), a policy reload can drop the configured profile overlay
(`F13-COR-02`), and the session layer relies on the worker for profile-binding
verification (`F22-SEC-01` / `F21-SEC-01`). These are carried under their
existing owners and are not counted again here.

## Lens: security and authority

Reviewed. `Evaluator` applies deny rules before ask/allow rules, capability
admission is computed before the host exists, and local dispatch forwards only
to the sealed toolbox (`evaluator.rb:15-25,29-65`; `capability_binding.rb:161-169,
201-247`; `local_dispatcher.rb:25-64`). The worker does not invent an approval
answer; it resolves the exact decision id embedded in the interrupt
(`worker.rb:434-505`).

The approval-policy weaknesses remain open and cross this flow: tool overrides
can reintroduce `:session` for no-session tiers (`F13-SEC-01`), the grant-scope
vocabulary is open (`F13-SEC-02`), and actor evidence is not supplied by the
production worker/CLI resolution callers (`F13` observability note). MCP/profile
authority drift is adjacent and remains owned by `F09-SEC-02`, `F09-SEC-01`,
and `F22-SEC-01`; this report does not duplicate those findings.

## Lens: reliability and durability

Reviewed. Approval answers, effect intents, receipts, observations and terminal
state are graph state channels; effect execution is journaled and reconciliation
is required for reconcilable mutations (`session_graph.rb:107-156`;
`effect_dispatcher.rb:69-109,289-328`). The worker's claim/resume path derives
the resume request id from the decision and fences concurrent claimers
(`worker.rb:440-478`). The repair contract is bounded by attempt count and
failure-signature deduplication (`session_evidence.rb:124-148`).

Known reliability gaps cross the path: a recorded approval resolution can lose
its session grant if the separate grant insert fails (`F13-REL-01`); mode rebind
can expose a new revision before its audit record (`F13-REL-02`); a crashed
worker can leave durable session grants usable (`F13-SEC-03`); and late effect
success can be replayed as failed (`CF04-REL-01`). Existing challenge and
re-review records own these findings; CF03 carries their impact only.

## Lens: observability and evidence

Reviewed. Approval descriptors and records bind decision id, rule, required
evidence, plan/step digests, arguments and preview digest. Effect receipts bind
attempt identity, status, reconciliation and iteration; observations carry
bounded output, provenance, source id, truncation and byte count
(`session_steps.rb:160-195,246-301`; `session_evidence.rb:30-48`). Unknown
effects produce a blocked record with explicit operator actions
(`session_evidence.rb:164-181`). The worker emits approval, resume and terminal
events around the same execution id (`worker.rb:465-477`).

The evidence gap is actor attribution: `Engine#resolve` accepts
`actor_evidence`, but the worker's `resolve_approval_asks` omits it and the
session approval record stores only the boolean verdict. F13 recorded this as a
quality gap because channel binding, not this node, owns the evidence check.
CF03 does not promote it to a second finding.

## Lens: scalability and resource bounds

Reviewed. Planning attempts, repair attempts, observation bytes, maximum effect
output, patch size, directory/search results and check output are bounded
(`session_deliberation.rb:91-99`; `session_steps.rb:93-98,276-281`;
`toolbox.rb:25-44,105-110`). Effect attempts are capped at three before an
ambiguous outcome becomes unknown (`effect_dispatcher.rb:12-15,141-159`).

No sustained worker load or approval-table retention measurement was run. The
append-only decision log has no retention seam (`F13-SCA-01`), and the planner
can still create many durable plan/review records up to its configured attempt
bound. These are explicit evidence limitations, not new CF03 findings.

## Lens: maintenance and architecture

Reviewed. Ownership is legible: session owns graph ordering and evidence,
approval owns policy and grants, capabilities own admission, toolbox owns local
execution, and the worker owns human-decision couriering. The one-shot runtime
uses the same approval engine and mirrors the denial record shape
(`runtime/step_execution.rb:112-177`). No second approval evaluator or raw tool
execution path was found in this flow.

The architectural risk is the number of boundary contracts that must stay in
sync: the session local approval record, approval-engine decision log, comms
decision record, and effect receipt each represent part of one human-approved
step. Existing F13/F22 reports document the concrete drift; no rewrite is
indicated by this flow review.

## Tests and contracts

- `ruby -Itest test/agent_acceptance_workflow_test.rb` → **1 run / 33 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/approval_engine_test.rb` → **26 runs / 95 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_decision_flow_test.rb` → **5 runs / 23 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/healing_remediation_test.rb` → **13 runs / 74 assertions / 0 failures / 0 errors / 0 skips**.
- No production provider, network service, or full CI run was used in this bounded review.
- No new finding was counted; carried findings retain their original challenge,
  probe and disposition records.

## Findings and disposition

No independent CF03 finding was added. The following accepted findings cross the
flow and remain owned by their existing seams:

| Finding | Owner | CF03 disposition |
|---|---|---|
| F13-COR-01, F13-COR-02 | schedule/reload policy binding | carried; open, challenged in `challenge-f13-approval.md` |
| F13-SEC-01, F13-SEC-02, F13-SEC-03 | policy schema/grant/session lifecycle | carried; open, challenged in `challenge-f13-approval.md` |
| F13-REL-01, F13-REL-02 | grant handoff/mode switch | carried; open, challenged in `challenge-f13-approval.md` |
| F20-REL-02, F20-SEC-01 | repair/remediation | carried; F20-REL-02 re-reviewed in `review-f20-rel02.md` |
| F09-SEC-01, F09-SEC-02, F22-SEC-01 | MCP/profile authority binding | carried; owned by existing authority reports |
| F07-SEC-01, CF04-REL-01 | effect resolver/replay | carried; separate owner and challenge records |

## Blind spots

- No worker crash was induced at the exact interval between approval-engine
  resolution and graph resume; existing kill/decision records were read as
  adjacent evidence.
- No multi-process approval-resolution race or grant-store failure was run in
  this flow; F13's injected probes are the current evidence.
- No sustained approval-log retention or worker throughput measurement was run.
- Real provider and external MCP execution were not used; all focused contracts
  use test models and local fixtures.

## Verdict

**IMPROVE** under `BAR.md`: the complete source trace and six lenses are present,
but accepted authority and reliability findings cross the plan → approval →
execution boundary. They remain under their original owners and are not
double-counted in the CF03 machine counters.
