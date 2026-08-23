# 09 — Handbook ch. 7 (Human-in-the-Loop) × approval-policy redesign alignment

**Status:** alignment analysis, not a design document.
**Date:** 2026-08-23
**Inputs:** "Chapter 7: Human-in-the-Loop — AI-Native Engineering Handbook"
(HDBK-007, v1.2) vs this folder (`00`, `03`, `06`), the phase evidence rows in
`08`, and the code at commits `f21808d..931a832`.

## Summary verdict

The redesign implements the chapter's core discipline — per-action classification
in data, a gate that is a state machine rather than a prompt, immutable
request-binding, expiry with fail-closed defaults, policy-as-code enforced by an
engine instead of a prompt, and state-machine-level testing of the gate — and in
the durability dimension (crash/replay semantics, decision-record idempotence,
policy-version-pinned grants, mode switches that survive restarts) it exceeds
what the chapter specifies. The divergences are concentrated where the chapter
asks for human-attention management machinery the ADR deliberately declined:
friction budgets and batching, aggregate-value thresholds, async
continue-while-pending, and multi-role approver routing; each traces to a named
deviation in `03` §4.1 or §4.2, not to oversight. Genuine gaps are few: the ask
carries less decision context than the chapter's 30-second table wants
(no cost/risk/alternatives/why-now), no oversight *metrics* are computed from the
decision log, there is no paging rung on the escalation ladder, and belief review
(§5 of the chapter) is outside this redesign entirely. One caveat governs every
comms-boundary claim below: phases 8–9 (evidence-from-decision,
`ApprovalDeniedError` deletion) exist only as **uncommitted working-tree
changes** — `08`'s evidence log has no rows for them.

---

## 1. Autonomy as a per-action decision

| Chapter says | Implementation status |
|---|---|
| "Autonomy is a per-action decision, not a global setting… the same agent can be fully autonomous for internal refactors and gated for anything touching production" (§1). | **Implemented.** The verdict is computed per request from data: tier defaults per action class (`gems/tamoz-approval/policy/base.yaml` `tiers:`), evaluated by `Evaluator#evaluate` (`gems/tamoz-approval/lib/tamoz/approval/evaluator.rb`) as deny rules → ask/allow rules → tier default. Reads and workspace writes flow under `implement`; execution asks; nothing is decided "per agent". Phase 2/3 evidence rows (`08`). |
| Check order matters: authority/policy/value before the reversibility shortcut; "an action the policy cannot classify does not inherit permission by accident" (§1). | **Implemented, with a stricter fallback.** Evaluation order is pinned in code (deny-first regardless of document order, then rules, then tier default). An unclassified tool lands in `fallback_tier` → `:ask` (scenario C-7, hard-zero); nothing tool-supplied can change it (bar invariant §4.1). Where the chapter falls back to `AUTONOMY_ESCALATE`, tamoz fails closed to a structured ask backed by schema-level grant bars (below). |
| Levels form a spectrum used per action: teleoperate / approve-on-action / approve-on-commit / escalate-on-exception / full (§1). | **Implemented as profiles over the same evaluator.** `plan` (reads allow, everything else structured deny), `review` (mutations ask), `implement` (default), `auto` (workspace/local allow), `unattended` (mutations ask + timeout denies) in `gems/tamoz-approval/policy/profiles/*.yaml`. Each `decide` consults the session's bound document (`Engine#policy_for`, `engine.rb`), so the spectrum is per-session configuration of a per-action decision, matching the chapter's "mixture" requirement. Mode switching is bounded and audited (ADR §2.6; invariant 13; scenarios MS-1..MS-6). |
| Aggregate value over a window gates split actions ("Aggregation prevents a large action from being split into smaller calls", §1). | **Deliberately diverged.** No aggregation exists. Disposition: ADR §4.1 deviation 6 — spend is owned by the descriptor's `request_budget`/`output_budget` and the agent budget runtime; the approval layer gates initiation. Flood-by-repeat is terminated by the existing repeated-action guard (`session_plan_outcomes.rb`, kept per ADR §2.4). See gap G4. |
| Escalate on calibrated low confidence (§1, §5 "Calibrate, Don't Guess"). | **Not covered.** Tamoz escalates by classification only; there is no confidence signal on any `Request`. No ADR disposition addresses it — it is simply outside the policy-as-data scope. Gap G6. |

## 2. What deserves a gate (blast radius, placement)

| Chapter says | Implementation status |
|---|---|
| Classify by irreversibility, externality, value, policy; gate irreversible/external/high-value classes; external communication approves at send time (§2 table). | **Implemented in the tier vocabulary.** `network`, `external_publish`, `destructive` tiers default to ask and are schema-barred from `:session` grants (base.yaml; loader validation); `credential-files` deny rule covers confidentiality; `force-push` ask rule covers published-history rewrites. Honest note: the shipped `base.yaml` maps no named tool into network/publish/destructive yet — those classifications are declared but unreached; unlisted tools fail closed to the once-only fallback ask. The capacity is data-ready, not exercised. |
| "Gate at the tool boundary… A prompt can ask nicely; a permission layer refuses" (§2). Failure mode "prompt-only gates" (§8). | **Implemented — this was the audit's central fix.** Dispatchers only *describe* the call; `Engine#build_request` canonicalizes and `Engine#decide` decides before execution (`session_steps.rb` `prepare_step…` → `effects.decide_step_tool`; ADR §1.1 boundary rule). The nine-method `approval_required?` chain and all prompt/profile-key policy were deleted in commit c1de9be (phase 7+7B row, `08`). |
| "Gate before the irreversible step, not before the pipeline" (§2). | **Implemented.** The gate sits on each gated tool call at the step seam, not on plan start; reads/writes that need no gate skip it entirely (C-1/C-4). |
| Ask, don't narrate; reserve asks for classes that earned them (§2). | **Implemented.** Under `implement`, `read`/`workspace_write` default allow (no prompt), asks concentrate on `local_execute` plus rules, and session grants end repeat asks without weakening opaque-argv tools (G-1/G-2/G-3). |
| Treat novelty as evidence: first-time/out-of-distribution actions start under tighter supervision; repetition justifies a *reviewed* policy change only (§2). | **Implemented.** Unknown tool → fallback ask, once-only (fail-closed by construction). Repetition never widens authority at runtime: widening requires an operator YAML edit delivered via `tamoz approve --reload` or an operator-addressed `--mode` switch — the runtime never edits its own policy (matches §6 "Learn through policy review"; engine mutation surfaces are `reload`/`rebind_session` only, both operator-addressed and logged). |

## 3. The approval-gate lifecycle

| Chapter says | Implementation status |
|---|---|
| Lifecycle propose → present → decide → validate → execute, as a state machine (§3). | **Implemented across engine + worker + transport.** `decide` appends the decision and offers scopes (`Engine#decide`); presentation parks the turn carrying the full `Decision` in the interrupt descriptor (`session_steps.rb` `'decision' => {id, verdict, reason, rule_id, required_evidence, grant_scopes}`); channel delivery activates single-use prompts after a durable send receipt (`ApprovalPrompt`, comms transport, unchanged); validation is fenced claim + digest binding + rev binding (`worker.rb` `apply_decision`); execution resumes once under the derived resume id and consumes the decision. Scenarios C-*/RS-*/T-* pass per the 7+7B evidence row. |
| Bind approval to immutable intent: canonical digest of action/arguments/resource/policy version; "a screenshot or free-text 'yes' is not sufficient authority" (§3). | **Implemented and tighter than the chapter.** Targets are realpath-canonicalized in `Engine#build_request` (including the broken-symlink case, `engine.rb:347-360`); argv/targets enter the log as digests; `Decision#id` derives from request digest + `policy_rev`; the worker binds the answer to the exact interrupt set via interrupt digest (`pending_decision(..., interrupt_digest:)`), and edit tools carry path+content in argv so distinct edits are distinct questions (c1de9be). Policy version rides inside every decision and grant (chapter stores policy version only at contract level). |
| Authenticate and authorize the decider; "approval identity is separate from delivery identity" (§3). | **Implemented at the comms boundary — uncommitted.** Required evidence level comes from the `Decision` (`outbox_delivery_sink.rb` `decision_evidence`, phase 8) instead of the deleted constant; an approve button is offered only when the channel's verified evidence can meet it (`offered_actions`: chat_bound ≥ required, else deny-only); `resolve` validates actor evidence against the injected symbol set and records it, and deliberately does not re-compare a caller-supplied level against the requirement (self-attestation hole named in `engine.rb`). Caveat: phase 8 has no evidence row in `08`; `Comms::ApprovalPolicy` deletion exists only in the working tree. |
| Replay/consume-once protection (§3, §7 state-machine tests). | **Implemented.** `resolve` is idempotent under identical replay, raises `ConflictingResolutionError` on a different answer/scope, `InvalidScopeError` off-offer scopes, `UnknownDecisionError` unknown ids; lookup→record→insert runs in one critical section so concurrent replays mint one grant (`engine.rb:73-103`); the worker claims decisions under a fenced CAS before applying (`claim_decision`). Scenarios RS-1..RS-4 (RS-1 hard-zero). |
| Re-validate preconditions between approval and execution (§3). | **Implemented by exact binding rather than world-state checks.** The answer covers exactly one canonicalized request (argv incl. content for edits, realpath'd targets, step scope `execution_id.plan_id.step_id`) bound to one interrupt set; a changed question is a new decision and is never covered; `timeout_s` bounds time skew. There is no separate precondition-revalidation layer beyond request identity + expiry — acceptable because tamoz requests are content-bearing, but it is a narrower mechanism than the chapter's general version tokens. |
| Expiry mandatory; protected action fails closed; timeout may route to a fallback approver without weakening the gate (§3, FAQ). | **Implemented.** `ask.timeout_s: 900` bounds the channel prompt; `on_timeout: park\|deny` is enforced by the worker's poll pass (`enforce_ask_deadlines`, `worker.rb:935-956`), including across process restarts via durable open occurrences. Attended park keeps the decision resolvable indefinitely through `tamoz approve <id>` (T-1 — the operator CLI is the authorized fallback, same decision record, same evidence requirements); unattended resolves a durable structured denial (T-2); an answer racing a timeout is settled by resolve idempotence (T-3). Stream receipts gain injected TTL (phase 11 row). |
| Separate proposal identity from operation identity; executor needs atomic idempotency (§3). | **Implemented.** Decision id (one ask) vs derived resume request id (execution claim); journaled verdict reuse means a replayed gate never re-decides (`journaled_verdict` read in `session_steps.rb`; `Engine#decide_or_reuse` keys reuse on session + argv/targets digests + step scope, `engine.rb:61-71`); decision-log appends idempotent on `decision_id` (LG-2). |
| Sync / async / deferred modes (§3 table): async = agent keeps working while a commit waits. | **Sync and deferred implemented; async deliberately diverged.** One-shot runtime asks synchronously (phase 9 path — uncommitted); the durable session parks the whole turn while the human answers whenever convenient (park + operator CLI); allowed tiers execute-and-log = deferred review via the decision log. "Continue independent work while pending" is argued out in ADR §4.1 deviation 4 (no definition of provably-independent work exists; parking is the v1 contract). |

## 4. Escalation and interruption

| Chapter says | Implementation status |
|---|---|
| Escalation ladder notify → ask → page → block, chosen by severity, each rung with a defined failure step (§4). | **Partial.** Ask/park/deny are fully built (park/deny semantics above). Notify exists as post-decision events and sink notification (`apply_decision` emits `request.approved/denied` + `notify_sink`). Block exists in policy form: the `plan` profile returns structured denials for every non-read tier, and `credential-files` hard-denies. The **page** rung (urgent high-priority channel with one-message decidability) does not exist and has no ADR disposition. Gap G7. |
| Fail-closed applies to the protected action; failover preserves the same evidence/role/policy requirements (§4). | **Implemented.** Timeout never proceeds; the operator-CLI fallback resolves the same decision record under the same evidence lattice; reload/mode-switch make stale grants fail closed at read time (grants keyed on the session's bound `policy_rev` — L-5/MS-2). |
| Interrupt safely: checkpoint at task boundaries, model "paused for human" as a state with owner/deadline/transitions, resume shows what changed (§4). | **Mostly implemented.** Parked turns are graph checkpoints; the parked state is explicit (`@parked` meta with since/signature/view/occurrence_id; view.status `:paused`); mode switches apply only at durable boundaries between turns (`drain_mode_switches` runs before queue advance, `worker.rb:121-128,832-860`), and a session's mode survives restarts by re-deriving the bound rev from the switch log (`Engine#bind_session` → `durable_override`). Not implemented: a "resume with a diff" summary surface for the human. |
| Context-switch tax: batch window, scheduled checkpoints, friction budget (§4, §6). | **Deliberately diverged.** No batching UI, no ask counter, no budget machinery. Dispositions: ADR §4.1 deviations 2 and 5 — session grants capture most of the fatigue win with zero new machinery, and the repeated-action guard terminates steered floods. Note the chapter's own invariant survives structurally: nothing can downgrade a mandatory gate because nothing but policy data sets defaults and deny rules always evaluate first. |

## 5. Human review of agent beliefs

| Chapter says | Implementation status |
|---|---|
| Belief-correction loop, provisional/confirmed statuses, evidence travels with belief, abstention valid, calibrated confidence for escalation (§5). | **Out of scope for this redesign.** The redesign isolates the *action-approval* policy layer (README scope: "does this action need approval, and under what evidence?"); belief/memory review is a different surface, which the chapter itself assigns to its Chapter 6 write policy. Nothing in `00`/`03` disposes of it, and nothing here should be counted for or against the bar. See gaps G5/G6. |

## 6. Delegation contract, friction budget, rubber-stamping

| Chapter says | Implementation status |
|---|---|
| The delegation contract is policy-as-code: versioned, reviewable, enforced by the permission layer, not a prompt (§6). | **Implemented, stronger than the chapter's example.** The contract is `base.yaml` + profile overlay, content-addressed (`policy_rev` = SHA-256 over the canonical document, recorded in every decision and grant), validated at load against schema, matcher set, scope bars, injected evidence symbols, and its own `simulations:` block (phases 2/4 rows; E-2/SIM-1 hard-zeros). Zero policy literals in Ruby (bar invariant 11). |
| Contract carries `policy_version`; thresholds; escalation roles + fallback role; friction budget; `expires_at` (§6 example). | **Versioning, threshold-free.** Version binding is per decision/grant (stronger than the example's single field). Thresholds diverged (§1 above). Roles/fallback roles diverged: tamoz is single-operator (ADR §4.2 Q7) and uses two evidence levels (`chat_bound`, `filesystem_operator`) where the chapter uses roles — adequate for one operator, not for team separation-of-duties (gap G8). Friction budget diverged (§4 above). Document-level `expires_at` does not exist — grants expire (`expires_at_ms` from the session deadline), policy documents do not (gap G9). |
| Rubber-stamp defenses: fewer asks, decision-ready evidence, measured fast decisions/approval concentration/override rates/sampled quality (§6, §8). | **Half implemented.** Fewer asks: yes (tier defaults, session grants). Evidence per ask: partial — tool, preview, reason naming the rule/tier, offered scopes, required evidence level (`cli_prompt_adapter.rb` `approve_tool`; descriptor fields). None of the measurement exists; the substrate does (every resolution records answer, scope, actor evidence, timestamps, `policy_rev` in `tamoz_approval_decisions`). Gap G10. |
| "The runtime never edits its own authority" (§6). | **Implemented exactly.** Authority changes enter only via operator-addressed `tamoz approve --reload PATH` (validated in the CLI process before the active-policy pointer is written) or `--mode NAME --thread ID` (durable control message, applied once, audited with actor/from-rev/to-rev, `cli_worker_commands.rb:346-417`, `worker.rb:854-896`, `Engine#rebind_session`). Grants cannot self-widen: off-offer scopes raise, opaque-argv tiers cannot hold `:session` at all (G-3/G-4, schema-enforced). |

## 7. Evaluating the oversight system

| Chapter says | Implementation status |
|---|---|
| Replay the policy and presentation layer without executing side effects, on labeled cases (§7). | **Implemented as load-time simulations + scorecard.** Every document's `simulations:` block runs against itself at load and rejects on failure (SIM-1 hard-zero; base/plan/auto profiles ship expectation blocks). The autonomy scorecard's approval cases were repointed onto the real profiles (`preauthorized→auto`, `strict asks→review`) and pass 17/17 (scorecard-fix row; commit 931a832 fixed the unrelated checkpoint-telemetry red). Per the owner directive, fixture suites prove plumbing/invariants; whether the shipped YAML is *well authored* rests on the simulations block and a real run — not claimed here. |
| Automate the state-machine cases: unauthorized/expired decision rejected; revised action can't reuse approval; concurrent approvals consume once; crash after claiming doesn't duplicate effect; changed resource forces re-proposal; timeout stops action; budget exhaustion never weakens gate; audit events join everything (§7). | **Nearly 1:1 with `06`.** RS-3 (unknown/expired id), T-2/T-3 (timeout stops, race settled), RS-1 (crash-after-claim replay dedups — hard-zero), MS-4 (switch applied exactly once across restart — hard-zero), G-2/C-3 + argv-content binding (changed question ⇒ new decision), O-1 (order-independent denies), LG-1/LG-2 + `mode_switch` records + graph journal (audit joins proposal/decision/execution/policy_rev). "Budget exhaustion" is vacuous — no budget exists to exhaust, and nothing can weaken deny-first defaults. |
| Production metrics/alerts by action class and policy version: unsafe-allow rate, unnecessary escalation, decision latency, override rate, approver concentration, drift (§7). | **Not built.** The decision log carries every field these metrics need (`tool`/`verb`/`tier`/`rule_id` cleartext, digests for arguments, verdicts, resolutions, `policy_rev`), but no metric, dashboard, or alert exists. Candidate future work (G10); nothing in `05`/`08` schedules it, so it must not be described as planned. |

## 8. Production failure modes (chapter §8, row by row)

| Chapter failure mode | Status here |
|---|---|
| Rubber-stamp approval | Mitigated upstream (fewer asks, structured reasons/scopes in every ask); measurement absent (G10). |
| Alert fatigue | Session grants cut repeat asks; batching/budget deliberately absent (ADR §4.1 dev 2/5). |
| Stale approval | Strong: expiry (ask timeout, grant `expires_at_ms`, stream receipt TTL), digest-exact binding, read-time `policy_rev` match — reload or tightening makes old grants stop matching with no grandfathering (L-5, MS-2). |
| Gate deadlock | Strong for tamoz's topology: attended parks stay resolvable via operator CLI forever (T-1); unattended denies durably (T-2). No multi-human fallback chain exists (single-operator, G8). |
| Approval gaming (splitting to dodge thresholds) | Diverged: no aggregate checks (ADR §4.1 dev 6); what exists is structural — opaque-argv and high-risk tiers can't hold session grants, so splitting buys a repeat ask, not standing authority. |
| Prompt-only gates | Fixed outright: the classification chain and prompt-borne policy are deleted; the engine refuses (phase 7+7B row, c1de9be sweep). |
| Context-switch tax | Diverged as above. |
| Uncalibrated escalation | N/A — escalation is classification-driven, not confidence-driven; the chapter's calibration program is absent (G6). |
| Scope drift | Strong: canonical request digest + step scope + interrupt-digest binding + argv-bearing edit questions (c1de9be). |
| Unauthorized approval | Strong (within the committed/uncommitted caveat): evidence lattice + activation-after-receipt + required level from the decision + recorded, validated actor evidence + one-resolution-per-decision. |
| Audit gap | Strong: append-only decision log (cleartext structure, digest arguments, idempotent appends), mode-switch audit records, unchanged graph journal — "why was this asked/denied/allowed" answerable from the database alone (LG-1). |
| Belief laundering | Out of scope (§5 above). |

## 9. Where the chapter is weaker than this implementation

1. **Crash/replay semantics.** The chapter's reference gate blocks synchronously in-process (`notifier.wait`) and mentions idempotency keys without a story for the decision record itself. Tamoz pins journaled-verdict reuse (`decide_or_reuse`), resolve idempotence with conflicting-resolution errors, fenced decision claims, and a durable clock for deadline enforcement across restarts (`enforce_ask_deadlines` scanning open occurrences) — properties RS-1/MS-4 make testable.
2. **Grants outlive their policy in the chapter's model.** The chapter's contract has one `policy_version` field but never binds grants to it; tamoz keys every grant on the session's bound `policy_rev`, so a reload or a mid-session tighten invalidates standing grants at read time with no sweep (L-5/MS-2).
3. **Delivery ≠ authority.** The chapter says "approval identity is separate from delivery identity" as guidance; tamoz enforces it mechanically — single-use prompts activate only after a durable send receipt, consumption is atomic, and the approve action is withheld unless the channel's verified evidence meets the decision's required level.
4. **Fallback classification.** The chapter's `AUTONOMY_ESCALATE` fallback is a convention; tamoz's is structural: unclassified → fallback tier ask with session grants schema-barred, enforced by load-time validation, and pinned by the document's own simulation block.
5. **Attended walk-away.** The chapter's timeout story is abort-or-fallback-approver; tamoz adds the recoverable middle case — the channel prompt lapses but the decision record stays resolvable by the operator CLI indefinitely (T-1), which avoids both bricking and fail-open.

## 10. Gap list

Out-of-scope per ADR/scope statement (no work implied):

- **G1 — Async continue-while-pending.** Argued out, ADR §4.1 deviation 4; parking is the v1 contract.
- **G2 — Friction budget / batch window / ask counter.** Argued out, ADR §4.1 deviations 2 and 5.
- **G3 — Aggregate-value thresholds and anti-split gaming.** Argued out, ADR §4.1 deviation 6 (budgets own spend; guard terminates floods).
- **G4 — Multi-role approvers, separation of duties, fallback-role chains.** Single-operator premise, ADR §4.2 Q7; two evidence levels stand in for roles.
- **G5 — Belief review loop and provisional/confirmed memory statuses.** Outside the redesign's stated scope (action-approval policy); belongs to the memory write policy surface the chapter itself defers to its Chapter 6.

Candidate future work the chapter surfaces, nothing built, nothing scheduled:

- **G6 — Confidence/calibration-driven escalation** (chapter §1, §5). No confidence signal exists on any request; would be new scope beyond the ADR.
- **G7 — Paging rung on the escalation ladder** (chapter §4). No urgent-channel design exists in comms or the ADR.
- **G8 — Approval-request enrichment**: cost, risk/worst-case, alternatives considered, why-now trigger (chapter §3 table). Today's ask carries tool, preview, reason, rule id, scopes, required evidence — decidable for tamoz's tool-shaped asks, short of the chapter's generic standard.
- **G9 — Policy-document lifetime** (chapter §6 contract `expires_at`). Grants expire; documents do not.
- **G10 — Oversight metrics and alerting from `tamoz_approval_decisions`** (chapter §7 production monitoring). Substrate complete, metrics absent.

Also noted honestly: `network` / `external_publish` / `destructive` tiers are declared in `base.yaml` but currently reached by no named tool — unlisted tools land in the once-only fallback ask, so behavior stays safe while the tier capacity waits for occupants.

## Provenance

Chapter: https://ghassan-alhamoud.com/handbook/chapter-07-human-in-the-loop.html (HDBK-007 v1.2, revised 2026-08-09), retrieved 2026-08-23 from the local copy `/tmp/tamoz-agents/handbook-ch07.html`, converted to text locally; no network fetch. Repo: branch `redesign-approval-policy`, commits `f21808d..931a832` reviewed (phases 1–7, 7B, 10, 11, scorecard-fix landed; phases 8–9 present only as uncommitted working-tree changes — comms evidence-from-decision and `ApprovalDeniedError` deletion are NOT committed at 931a832, and `08`'s evidence log has no rows for them). Code seams read: `gems/tamoz-approval/lib/tamoz/approval/{engine,evaluator,decision_log}.rb`, `gems/tamoz-approval/policy/base.yaml` + `profiles/*.yaml`, `gems/tamoz-agent/lib/tamoz/agent/{worker,session_steps,cli,cli_prompt_adapter,outbox_delivery_sink,cli_worker_commands}.rb`, `gems/tamoz-comms/lib/tamoz/comms/approval_prompt.rb`. Unexamined: `01`/`02`/`04`/`05`/`07` except where quoted by other documents; the sqlite store implementations and migration files (claims taken from the phase 5 evidence row); the README's status table ("implementation not started") is stale against `08` and the commit log.
