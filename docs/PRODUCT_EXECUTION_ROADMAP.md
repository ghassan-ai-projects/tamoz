# Tamoz product execution roadmap

Status: active
Current phase: P15 — release hardening (the completion audit)
Last completed product checkpoints: P10, D-8, DR-4, DR-5, P16, evals, P17, P11, P12, P13,
P14, P18 all closed; scorecard 22 cases / 19 successes / pass / 4/4 hard gates / safety 0
Canonical next action: finish P15 per docs/P15_RELEASE_PLAN.md. Release status is
machine-readable in docs/requirements-manifest.json and docs/REQUIREMENTS_AUDIT.md; the
open release-blocking gaps are INV-39 (cron/IANA civil time not implemented), INV-48
(channel backpressure declared but never enforced) and OBJ-7 (release evidence).

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
| P8 | Trusted project profiles | medium–high | medium | complete; DR-5 machinery closed (budget use waits for P13) | user-owned profile pins roots, named checks, model roles, budgets, and policy digest |
| P9 | Skills | medium–high | medium | complete `8b095ab` (P9-C/D2/E/B2 deferred, disclosed) | one evaluated content-addressed skill improves a task without granting authority |
| P10 | MCP client/host slice | high | high | complete (D2/H/E-conformance deferred) | one real server, pinned catalog, supervised transport, local policy, durable effects |
| DR-2 | Durable circuit | high | medium | egress scope complete via P17; supervisor/rule/schedule scopes pending (P12/P13) | one persistent record serves P10 server + P17/P12/P13 scopes across restart |
| DR-3 | Memory evaluation substrate | high | medium | complete `b6c379c` | isolated four-treatment CI substrate makes injection-correctness-only claims |
| DR-4 | Stale request framework | high | medium | complete `c627aec` | stale requests terminal-fail atomically; thread continues |
| DR-5 | Profile machinery | high | medium | complete `be84e8e` | roles/transitions/credential-ref replay are durable and critic-proven |
| P16 | Tools gem extraction | medium | medium | complete `38d2e94` | tamoz-tools loads/runs with core only and preserves behavior byte-for-byte |
| P17 | Governed websearch | high | high | closed (`78041fc`, critic fix `3fe4d43`) | one bounded attributed search path with enforced per-hop egress policy |
| P11 | Three-layer memory | high | high | closed (`0531bee`, critic fixes `5cdf17f`) | Experience → Knowledge → Wisdom treatment beats no-memory with deletion and provenance safety |
| P12 | Bounded self-healing and improvement | high | high | closed (Round 24) | one typed recovery and one candidate promotion pass holdout, circuit, rollback, and human gates; observation/shadow-only disclosed; DR-2 durable circuit on one record type |
| P13 | Durable scheduler | medium | high | closed (Round 25) | tamoz-scheduler gem (at/interval); atomic materialize_due; misfire/overlap/not_before; claim-time grant intersection; scorecard case 21; critic PASS-WITH-GAPS, all findings closed |
| P14 | Streaming physical-world input | strategic | very high | closed (Round 26) | tamoz-stream gem; atomic process_partition + injected clock; durable admission/dedup/quarantine; action boundary + interlock; replay credential isolation; scorecard case 22; critic PASS-WITH-GAPS, all findings closed; simulated source only (real-adapter gate deferred to owner approval) |
| P18 | Capability host + graph audit | high | high | closed (Round 27); session wiring landed in P15 `13ea8fd` | four closed built-in sources share one host; graph surface measured and documented |
| P15 | Release hardening | very high | high | implementing (`d37ba24`, `13ea8fd`, `d36d0c6`, `848c28f`) | public API/docs, migrations, restore, security, benchmarks, signed eval decision, release candidate |

P2–P10 plus P16/P17 are the current usable alpha path. P11–P14/P18 are promoted only after the preceding product
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

### P9–P18

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

- P0–P18 and their required DR implementations are complete, or a documented promotion
  gate explicitly defers a non-security extension;
- the CLI completes, repairs, resumes, and verifies real tasks without private RubyLLM APIs;
- evaluation hard safety gates are zero-tolerance and behavioral improvements beat pinned
  baselines;
- durable effects stop or reconcile ambiguity without guessing;
- memory, skills, MCP, scheduling, and streaming cannot widen authority;
- physical-world output remains supervisory, typed, current-state checked, simulated first,
  and externally interlocked;
- the public gems, reference agent, documentation, migration/backup path, and release evidence
  are ready for an independently reproducible release candidate.
