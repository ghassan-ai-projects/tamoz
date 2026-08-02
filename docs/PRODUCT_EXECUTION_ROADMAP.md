# Tamoz product execution roadmap

Status: active
Current phase: P17 — governed websearch capability
Last completed product checkpoints: P10 (closed), D-8 (real-model action proven), DR-4
(stale-request), DR-5 (profile machinery), P16 (tools gem — scorecard byte-identical),
evals substrate (DR-3 + assertion variance); scorecard 17 cases / 14 successes / pass /
4/4 hard gates / safety 0
Canonical next action: implement P17 per docs/P17_WEBSEARCH_PLAN.md, then P11, P12, P13,
P14, P18, P15 (single-active-phase order)

Detailed continuation tracker: [`PROJECT_HANDOVER_PLAN.md`](PROJECT_HANDOVER_PLAN.md).

This file is the durable execution plan for turning the accepted v0.1 design into a useful,
released Tamoz product. It complements the risk-first framework milestones in
`design-v0.1/IMPLEMENTATION_PLAN.md`; when they compete, this roadmap chooses the smallest
vertical product slice that produces user value without weakening a design invariant.

## 1. Operating rules

Every phase follows one non-negotiable sequence:

```text
plan/correct scope → implement → focused tests/evaluation → deep review/corrections
→ complete `rake ci` → one phase commit → update this roadmap
```

- Read-only inspection may precede a phase. No next phase implementation begins before the
  current phase commit.
- Every task action remains behind exact plan review. Every external effect remains behind
  current authorization, approval where required, and a bounded receipt.
- Add one behavioral evaluation with each product capability. Do not postpone behavioral
  proof to release hardening.
- Prefer extending the working CLI path over building parallel infrastructure.
- Do not add a generic shell, plugin system, second UI, or optimization matrix merely to
  demonstrate architecture.
- A phase may be split when review finds a new failure boundary. Record the correction here.
- The worktree must be clean at every committed checkpoint. Never mix release-evidence
  machinery into a product behavior commit.

## 2. Value-first build order

| Phase | Capability | Value | Effort | Status | Exit criterion |
|---|---|---:|---:|---|---|
| P0 | Reviewed read-only agent | high | low | complete `9919639` | real model → reviewed plan → confined reads → verified answer |
| P1 | Reviewed coding change loop | very high | medium | complete `d25e66e` | discovery → reviewed digest-bound patch → configured check → verification |
| P2 | Bounded repair loop | very high | low–medium | complete (working slice 3) | failed check becomes evidence; reviewed retry succeeds or stops safely |
| P3 | Coding behavior scorecard | very high | low | complete | fixed deterministic corpus reports success, safety, attempts, approvals, and cost proxies |
| P4 | Compound existing-file edits | high | medium | complete `67f72d7` | one digest binds several ordered exact replacements in one atomic file update |
| P5 | Reviewed file creation | high | medium | complete `6504398` | create one new bounded file with parent/root policy, exact preview, approval, atomic commit |
| P6 | Durable session/effect recovery | very high | medium–high | complete `b69701c` (P6-F partial) | SQLite resumes plan/approval/tool/check state and reconciles kill points without guessing |
| P7 | Interactive multi-turn CLI | high | medium | complete `7469fa2` | clarify, redirect, continue, and resume one durable session |
| P8 | Trusted project profiles | medium–high | medium | complete `0ed3944` (§5.3/§5.4 machinery deferred, disclosed) | user-owned profile pins roots, named checks, model roles, budgets, and policy digest |
| P9 | Skills | medium–high | medium | complete `8b095ab` (P9-C/D2/E/B2 deferred, disclosed) | one evaluated content-addressed skill improves a task without granting authority |
| P10 | MCP client/host slice | high | high | complete (D2/H/E-conformance deferred) | one real server, pinned catalog, supervised transport, local policy, durable effects |
| P11 | Three-layer memory | high | high | pending | Experience → Knowledge → Wisdom treatment beats no-memory with deletion and provenance safety |
| P12 | Bounded self-healing and improvement | high | high | pending | one typed recovery and one candidate promotion pass holdout, circuit, rollback, and human gates |
| P13 | Durable scheduler | medium | high | pending | one recurring task enters the ordinary request/review/effect path exactly once |
| P14 | Streaming physical-world input | strategic | very high | pending | deterministic Situation replay, bounded admission, simulated effector, external interlocks |
| P15 | Release hardening | very high | high | pending | public API/docs, migrations, restore, security, benchmarks, signed eval decision, release candidate |

P2–P8 are the usable v0.1 product path. P9–P14 are promoted only after the preceding product
path is reliable and their design promotion evidence exists. P15 closes the release; it does
not replace each phase's tests and review.

## 3. Completed phase P2 — bounded repair loop

### Outcome

When an approved `run_check` returns `exit_N`, `signal_N`, or `timed_out`, Tamoz treats that
receipt as new evidence. It may produce a new immutable action-plan version, review it, ask
for fresh approvals, and retry. It never edits the prior plan or silently repeats an effect.

### Scope

1. Classify `run_check` receipts structurally rather than asking the model whether the check
   passed.
2. After a failed check, stop the current action plan at its next safe barrier.
3. Add the complete failed-check observation to repair evidence.
4. Draft and review a replacement action plan; include prior action plan, receipts, and
   previous reviewer feedback.
5. Require fresh approval for every new patch and check.
6. Bound repair attempts to two after the initial action plan.
7. Stop before action when the replacement action signature repeats a prior accepted action
   signature or the normalized failure signature repeats without new evidence.
8. Preserve all plan/review/approval/tool events with `repair_attempt` and phase metadata.
9. Final verification runs only after a passing check or a terminal stop. It must report
   unsatisfied when no configured check passed.

### Non-scope

- no automatic rollback;
- no arbitrary shell;
- no retry of an ambiguous/unknown effect;
- no durable crash resume yet;
- no self-modifying prompt, policy, evaluator, or capability;
- no attempt to repair configuration, dependency installation, or network access.

### Required evaluations

- initial patch fails; second reviewed patch passes;
- identical replacement action is rejected before approval/execution;
- identical failure evidence stops the loop;
- revised patch and repeated check each require new approval;
- timeout is terminal evidence for the attempt and remains bounded;
- approval denial stops with no additional mutation;
- maximum attempts produce a verified unsatisfied result, not an exception disguised as
  success;
- read-only mode remains byte-for-byte behavior compatible.

### P2 definition of done

- all required evaluations pass deterministically without network access;
- no action path bypasses structural review, semantic review, or approval;
- deep review covers loops, budgets, duplicate actions, evidence growth, timeout, and partial
  mutation;
- design validation, syntax, packaging, and all repository tests pass;
- one commit updates this status to complete and advances `Current phase` to P3.

## 4. Later phase contracts

### P3 — coding behavior scorecard

Accepted implementation plan: [`P3_AGENT_SCORECARD_PLAN.md`](P3_AGENT_SCORECARD_PLAN.md).

Build a small deterministic corpus, not release sharding infrastructure. Start with 12
repositories/tasks covering read-only explanation, one-pass repair, two-pass repair,
multi-location edit need, new-file need, stale digest, denied approval, failed check, timeout,
malformed plan, unnecessary action, and root escape. Report:

- task success and verified completion;
- unsafe/bypassed action count (hard zero gate);
- plan and repair attempts;
- approvals and denials;
- tool/model call counts and bounded byte/cost proxies;
- unnecessary mutation and repeated-action rate.

### P4 — compound existing-file edits

Replace one file using an ordered array of exact non-overlapping replacements under one
before digest and one atomic rename. Render one exact unified diff and request one approval.
Reject overlap, ambiguity, changed digest, excessive result size, or partial applicability.

### P5 — reviewed file creation

Create only a missing regular file below an existing approved parent. Bind path, bytes,
mode, digest, and overwrite=false in the plan/approval. Use private temporary content,
fsync, atomic no-clobber publication, and a receipt. No delete or rename yet.

### P6 — durable session/effect recovery

Move the working lifecycle onto the existing SQLite request, checkpoint, lease, and effect
contracts. Persist exact plan/review versions and approval decisions. Kill at prepare,
dispatch, rename/check completion, receipt, and checkpoint seams. Reconcile a patch through
before/after digests; never automatically repeat an unknown check.

### P7 — interactive multi-turn CLI

Add stable session identity, follow-up input, clarification, redirect, and `--resume` over
P6. The UI remains a stream consumer and approval responder; no agent logic enters the CLI.

### P8 — trusted project profiles

Store project authority outside the untrusted repository by default. A profile binds the
canonical root digest/identity, named argv checks, model roles, budgets, and policy version.
Repository files may suggest configuration but never become executable authority without an
explicit import and preview.

### P9–P15

Use the accepted designs in `docs/design-v0.1/` and their promotion gates. Each phase must
have one real consumer and a treatment evaluation. Do not begin physical action before P6,
P10, P12, and independent interlock/simulator evidence are complete.

## 5. Context restart protocol

When work resumes after context compaction or in a new task:

1. Read this file completely.
2. Read the active phase's latest plan/review and the last two product commits.
3. Run `git status --short`; preserve unrelated user changes.
4. Confirm the active phase status and its exact next unchecked exit criterion.
5. Continue from that criterion. Do not restart completed phases or return to paused
   evidence optimization unless P15 requires it.
6. After a phase commit, update `Current phase`, the phase table status/commit, and
   `Canonical next action` in the same commit.

## 6. Project completion definition

“Finalize Tamoz” means:

- P0–P15 are complete or a documented promotion gate explicitly defers an extension;
- the CLI completes, repairs, resumes, and verifies real tasks without private RubyLLM APIs;
- evaluation hard safety gates are zero-tolerance and behavioral improvements beat pinned
  baselines;
- durable effects stop or reconcile ambiguity without guessing;
- memory, skills, MCP, scheduling, and streaming cannot widen authority;
- physical-world output remains supervisory, typed, current-state checked, simulated first,
  and externally interlocked;
- the public gems, reference agent, documentation, migration/backup path, and release evidence
  are ready for an independently reproducible release candidate.
