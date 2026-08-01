# Tamoz implementation handover plan

Status: active handover tracker
Implementation baseline: `c72f2b3` (`P3` complete)
Current phase: `P8` — trusted project profiles
Next action: implement P8 per `docs/P8_TRUSTED_PROFILES_PLAN.md`; P7 is closed

This is the execution document for another agent continuing Tamoz from the current state.
It expands the product roadmap into trackable work packages. The authoritative semantics
remain in `docs/design-v0.1/`; this file controls implementation order and proof.

## 1. Current state to preserve

At the implementation baseline:

- branch: `main`;
- remote: `origin git@github.com:ghassan-ai-projects/tamoz.git`;
- P0–P3 are complete;
- Tamoz Agent supports reviewed read-only work, one exact existing-file replacement,
  configured checks, and two bounded reviewed repairs;
- `tamoz-eval scorecard agent-smoke` runs 12 deterministic cases;
- scorecard baseline: 7/12 task successes, zero unsafe/bypassed actions, zero false-positive
  completions, one unnecessary mutation, and one repeated-action stop;
- last full gate: design validation plus 393 tests / 27,456 assertions / zero failures;
- every gem packaged successfully;
- the implementation branch was 28 commits ahead of `origin/main` and had not been pushed.

The handover-plan commit will be newer than `c72f2b3`; use `git log` for its hash. Do not
push, publish gems, create releases, rewrite history, or merge external changes unless the
owner explicitly requests it.

## 2. Source-of-truth order

When documents appear to disagree, use this order:

1. `docs/design-v0.1/INVARIANTS.md` — compatibility and safety contract;
2. the capability design named in the phase card below;
3. `docs/design-v0.1/DECISIONS.md` and accepted review corrections;
4. this handover plan — sequencing and proof;
5. `docs/PRODUCT_EXECUTION_ROADMAP.md` — summary status;
6. historical milestone plans and reviews.

Do not silently resolve a semantic conflict in code. Record the conflict in the active
phase plan, perform a five-whys analysis, amend the design/review if needed, and commit the
correction before implementation.

## 3. Status ledger

Allowed status values: `pending`, `designing`, `implementing`, `reviewing`, `complete`,
`deferred`, `blocked`. Only one phase may be active.

| Phase | Status | Product proof | Design commit | Implementation commit(s) |
|---|---|---|---|---|
| P0 | complete | reviewed read-only agent | historical | `9919639` |
| P1 | complete | reviewed exact patch + check | historical | `d25e66e` |
| P2 | complete | bounded reviewed repair | roadmap | `00bcaa4` |
| P3 | complete | deterministic agent scorecard | `68224b3`, `8de7ac1` | `c72f2b3` |
| P4 | complete | compound one-file edit | `a941f25` | `def7908`, `67f72d7` |
| P5 | complete | reviewed file creation | `73017b0` | `d8ae1c0`, `6504398` |
| P6 | complete | durable session/effect recovery | `8c977dc` | `2d94908`, `b69701c` |
| P7 | complete | interactive/resumable CLI | `cab974f` | `1f2c56a`, `9500acb`, `1e404d8`, `7469fa2` |
| P8 | **implementing** — design accepted | trusted project profiles | `cab974f` | — |
| P9 | pending | evaluated skills | — | — |
| P10 | pending | governed MCP client/host | — | — |
| P11 | pending | three-layer memory | — | — |
| P12 | pending | bounded healing and improvement | — | — |
| P13 | pending | durable scheduling | — | — |
| P14 | pending | Situation streaming and simulated physical action | — | — |
| P15 | pending | release hardening and independent completion audit | — | — |

Update this table and `docs/PRODUCT_EXECUTION_ROADMAP.md` in the final commit of each phase.
Never mark a phase complete based only on unit tests or an implementation claim.

## 4. Mandatory phase protocol

Every phase and every large subphase follows this sequence:

1. **Inspect:** clean worktree, current tracker, applicable design, invariants, last two
   product commits, relevant production code/tests.
2. **Plan:** create `docs/PX_<TOPIC>_PLAN.md` with exact API, failure model, migration,
   non-goals, evaluations, and stop/redesign criteria.
3. **Review plan:** create `docs/reviews/PX_<TOPIC>_PLAN_REVIEW.md`; correct critical/high
   findings before code.
4. **Commit design:** one documentation-only checkpoint.
5. **Implement one work package:** keep public behavior usable; preserve unrelated changes.
6. **Focused proof:** deterministic unit, integration, adversarial, recovery, and behavior
   tests appropriate to the boundary.
7. **Deep code review:** record correctness, security, reliability, observability,
   compatibility, maintenance cost, and residual risk; correct findings.
8. **Complete gate:** `rbenv exec bundle exec rake ci`. Run outside an enclosing macOS
   sandbox when nested sandbox tests otherwise fail.
9. **Commit implementation:** one reviewed checkpoint per work package. Large phases may
   use several such commits; none may skip the full gate.
10. **Close phase:** rerun its behavioral scorecard, update this ledger/roadmap/docs, verify
    a clean worktree, then move the active marker.

No next phase begins before the current phase closes. Do not use “refactoring,” generic
abstractions, dashboards, additional UIs, or performance tuning as a substitute for the
phase's product proof.

## 5. Dependency path

```text
P4 compound edit → P5 file creation → P6 durable recovery → P7 interactive CLI
                                                   │
                                                   ▼
                                      P8 trusted project profile
                                                   │
                         ┌─────────────────────────┴─────────────────────────┐
                         ▼                                                   ▼
                    P9 skills                                           P10 MCP
                         └─────────────────────────┬─────────────────────────┘
                                                   ▼
                                              P11 memory
                                                   ▼
                                      P12 healing + improvement
                                                   ▼
                                            P13 scheduler
                                                   ▼
                                  P14 streams + physical simulator
                                                   ▼
                                         P15 release hardening
```

P6, P8, P10, and P12 are hard prerequisites for any physical action path. P14 follows P13
for execution order even though civil scheduling is not part of stream semantics. A phase
may be deferred only through a committed promotion decision proving why the final objective
remains satisfied without it.

The existing gem version is alpha. “P8 usable foundation” is not permission to publish a
stable v0.1. Stable release claims wait for P15 and its requirement-by-requirement audit.

## 6. Remaining phases

### P4 — compound existing-file edits

Authoritative inputs: `AGENT_DESIGN.md` §§3–5, invariants 17, 21, 25–27, and P3 case
`agent.multi-location-edit`.

Outcome: one accepted plan and one approval atomically apply several exact,
non-overlapping replacements to one existing UTF-8 file under one before digest.

Work packages:

- [x] **P4-D** Specify backward-compatible tool arguments, canonical replacement ordering,
  overlap/ambiguity rules, unified diff rules, receipt, and failure taxonomy.
- [x] **P4-A** Add immutable replacement values and structural validation: bounded count and
  bytes, exact original-source matching, no overlap, no partial applicability.
- [x] **P4-B** Preflight all replacements against one digest, render one exact preview,
  request one approval, and perform one existing atomic replace.
- [x] **P4-C** Integrate action signatures, repair evidence, output budgets, CLI rendering,
  public API/docs, and packaging.
- [x] **P4-E** Turn `agent.multi-location-edit` into success without changing its case
  identity or weakening any P3 hard gate.

Required proof:

- success with two ordered replacements and a real configured check;
- stale digest, zero match, ambiguous match, overlap, partial applicability, excessive
  count/result size, symlink, binary, and root escape all leave bytes unchanged;
- one diff, approval, atomic rename, and receipt bind the complete replacement set;
- replacement order cannot change the result or signature accidentally;
- read-only and single-replacement behavior remain compatible;
- scorecard rises from 6/12 to at least 7/12 with safety gates still zero.

Stop/redesign if a failure can apply only part of the set or approval preview can differ
from execution. Do not add multi-file transactions, create/delete/rename, or generic diff
application.

### P5 — reviewed file creation

Authoritative inputs: `AGENT_DESIGN.md` §§3–5, persistence effect rules, invariants 17, 21,
24–27, and P3 case `agent.new-file-need`.

Outcome: create one missing bounded regular file beneath an approved existing parent, with
exact bytes/mode/digest, overwrite false, one preview, and one approval.

Work packages:

- [x] **P5-D** Specify portable atomic no-clobber publication. Do not assume `File.rename`
  is safe because it overwrites existing targets.
- [x] **P5-A** Add path/parent/root/symlink, UTF-8/binary policy, byte, mode, and digest
  validation with immutable arguments.
- [x] **P5-B** Implement private temporary write, flush/fsync, no-clobber publication,
  directory fsync, cleanup, and truthful receipt.
- [x] **P5-C** Integrate planning, approval, repair signatures, CLI/docs/API, and evaluation.
- [x] **P5-E** Turn `agent.new-file-need` into success while preserving every prior case.

Required proof includes concurrent creators, target appearing between preview and commit,
missing/changed parent, symlink parent, path collision/case behavior, mode preservation,
process failure at each write/publication seam, and no orphaned public partial file.

Stop/redesign if the supported platforms cannot provide atomic no-clobber semantics under
the declared contract. Do not add overwrite, directory creation, delete, or rename.

### P6 — durable session and effect recovery

Authoritative inputs: `PERSISTENCE_DESIGN.md`, `GRAPH_DESIGN.md`, `AGENT_DESIGN.md` §§1–8,
invariants 9, 18–27, 52–55, and the existing SQLite/graph durability APIs.

Outcome: the working agent lifecycle persists exact plan/review versions, observations,
approvals, tool/effect states, behavior/catalog identity, and terminal verification; a killed
process resumes or stops on ambiguity without guessing.

This is the highest-risk remaining phase. Split it into separately reviewed commits:

- [x] **P6-D** Map the current runtime onto existing `DurableRunner`, checkpoint, request
  inbox, lease/fence, effect-journal, and codec seams. Prefer adapting the lifecycle over
  creating a second workflow engine.
- [x] **P6-A — durable session state:** versioned allowlisted records, session/thread/request
  identity, exact plan/review digests, event projection, sensitive-data rejection, migration.
- [x] **P6-B — durable turns:** graph nodes/barriers for plan, review, discovery, action,
  verification, repair, approval interrupts, and stable activation/attempt identities.
- [x] **P6-C — filesystem effect recovery:** journal prepare/dispatch/receipt; reconcile a
  patch/create effect using before/after digests. Execute only from proven-before state,
  complete from proven-after state, otherwise mark unknown.
- [x] **P6-D2 — check/model ambiguity:** persist request/call identity and receipts. Never
  automatically repeat a check or provider call whose dispatch outcome is unknown unless
  its declared safety contract proves retry or reconciliation.
- [x] **P6-E — kill matrix:** subprocess kill before/after plan acceptance, checkpoint,
  approval, effect prepare, filesystem publication, check completion, receipt, verification,
  lease loss, and terminal commit.
- [~] **P6-F — operational durability:** backup/restore, corruption, retention, deletion,
  stale fence, late receipt, concurrent owners, and FD leak are proved. Disk-full, lock
  saturation, the unresolved-effect deletion guard through a session, thread-leak
  measurement, and a soak remain **not done**; see
  `docs/reviews/P6_IMPLEMENTATION_REVIEW.md` §10.

Required product proof: a real repository repair survives `kill -9` at every declared seam,
resumes the same accepted exact plan, never applies a filesystem effect twice, and pauses a
truly unknown check/effect for reconciliation. Read-only and ephemeral construction remain
available where documented.

Stop/redesign if agent durability needs private RubyLLM APIs, bypasses graph barriers,
creates a second checkpoint/effect model, or retries unknown work.

### P7 — interactive and resumable CLI

Authoritative inputs: `TAMOZ_AGENT_DESIGN.md` §§3–5, request inbox design, `AGENT_DESIGN.md`
§§5 and 8, invariants 23, 25–27, 52–55.

Outcome: one stable session supports clarification, approval, follow-up, redirect,
cancellation, continuation, and `--resume` over P6.

Work packages:

- [x] **P7-D** Specify commands, session/request identifiers, EOF/signals, output/event
  schema, redirect semantics, and non-interactive behavior.
- [x] **P7-A** Add session create/open/list/resume and durable request enqueue/join.
- [x] **P7-B** Render durable clarification/approval interrupts and validate positional
  answers without embedding agent policy in the UI.
- [x] **P7-C** Add follow-up, queue, redirect, cancellation, terminal summary, and bounded
  transcript/compaction projection.
- [x] **P7-E** Test duplicate delivery, two CLI processes, redirected in-flight effects,
  EOF, SIGINT/SIGTERM, crash/restart, stale graph/behavior/catalog, and sensitive output.

Product proof: start a coding task, interrupt/approve, kill the process, resume by stable
session, redirect once, and finish with one ordered request history and verified result.

Do not add a TUI, gateway, daemon, or chat-channel abstraction.

### P8 — trusted project profiles

Authoritative inputs: `AGENT_DESIGN.md` §§5–7, invariants 16, 24–27, 35, and security rules
across skills/MCP/scheduler designs.

Outcome: an operator-owned profile outside an untrusted repository pins canonical project
root identity, named argv checks, symbolic model roles, budgets, capability/policy versions,
approval defaults, and adoption rules by digest.

Work packages:

- [ ] **P8-D** Define schema/version, storage/search order, ownership/permission rules,
  canonical digest, secret references, and migration.
- [ ] **P8-A** Implement strict load/validate/normalize with no code, interpolation, shell,
  aliases, implicit host timezone, or embedded credentials.
- [ ] **P8-B** Bind profiles to session/checkpoint/cache epochs; changes create candidate
  transitions and never mutate in-flight authority.
- [ ] **P8-C** Add `--profile`, exact preview/import of repository suggestions, and
  operator-confirmed activation. Suggestions never become authority automatically.
- [ ] **P8-E** Fuzz permissions, symlinks, duplicate keys, unknown fields, root swaps,
  command injection, environment leakage, revoked grants, and resume under changed profiles.

Product proof: the same repository task runs reproducibly from one trusted profile; a
malicious repository profile can neither change checks nor gain tools/network/credentials.

P8 closes the usable foundation path, not the stable release.

### P9 — evaluated skills

Authoritative input: `SKILLS_DESIGN.md`, `AGENT_DESIGN.md` §10, invariants 35 and 41–43.

Outcome: one Agent Skills-compatible, source-qualified, content-addressed skill improves a
fixed task through progressive disclosure without granting authority.

Work packages:

- [ ] **P9-D** Specify `SkillSource`, `SkillRecord`, `SkillSnapshot`, tree digest, catalog
  epoch, collision/binding policy, and prompt budget.
- [ ] **P9-A — inert compiler:** safe YAML, canonical tree walk, path/link/type/size/depth/
  case-collision checks, immutable resource index, no load-time execution.
- [ ] **P9-B — progressive use:** stable catalog/search, explicit/user/model selection,
  `load_skill`, digest-checked `read_skill_resource`, exact snapshot resume.
- [ ] **P9-C — scripts:** only through ordinary reviewed tools with exact digest, sandbox,
  environment/egress/budget/effect policy; loading never installs dependencies.
- [ ] **P9-D2 — lifecycle:** quarantine, provenance/signature/digest verification, capability
  diff, evaluation, approval, atomic install/update/uninstall, catalog transition.
- [ ] **P9-E — treatment evaluation:** no-skill vs current-skill, positive/confusable
  negatives, selection precision/recall/abstention, token cost, task success, containment.

Hard gates: zero authority gained from content, zero tree escape, zero silent shadowing,
exact digest replay, and measurable task benefit without safety/cost regression.

Do not create a plugin API, marketplace, hidden skill call stack, or auto-executing installer.

### P10 — governed MCP client/host

Authoritative input: `MCP_DESIGN.md`, `AGENT_DESIGN.md` §11, invariants 35–37. Re-check the
official MCP specification and Ruby SDK at implementation time; protocol details are
time-sensitive, but amend Tamoz's pinned profile only through review.

Outcome: optional `tamoz-mcp` uses the official SDK to connect to one real test server,
compile a locally governed immutable catalog, execute one capability through Tamoz policy/
effects, survive transport failure, and preserve elicitation/ambiguity.

Work packages:

- [ ] **P10-D** Pin SDK/version/protocol profiles and dependency boundary; define server
  config, credential references, source-qualified descriptors, local effect classification.
- [ ] **P10-A — admission/discovery:** stdio first, exact command/env/root preview, schema
  validation, bounded metadata, immutable catalog digest/epoch, reconnect/list-change rules.
- [ ] **P10-B — execution:** accepted plan binds capability and definition digests;
  validate arguments/results, bound/redact/attribute output, journal effect identity, stop
  unknown non-idempotent outcomes.
- [ ] **P10-C — supervision/elicitation:** deadlines, concurrency, process-tree teardown,
  backoff/circuit, durable originating-call interrupt, headless deny/escalate.
- [ ] **P10-D2 — HTTP/security:** only after stdio proof; SSRF, redirect, OAuth audience,
  PKCE/state, token isolation/rotation/revocation, no credentials in state/content/logs.
- [ ] **P10-H — host/server profile:** expose only an explicit authenticated export
  manifest; no raw agent, checkpoints, approvals, credentials, private memory, or registry.
- [ ] **P10-E** Official conformance plus malicious metadata/schema/content, churn, hang,
  crash, disconnect, ambiguous effect, teardown, and behavioral value tests.

Do not reimplement JSON-RPC, use remote annotations as policy, silently adopt new schemas,
or claim native support before failure paths are durable.

### P11 — three-layer memory

Authoritative input: `MEMORY_DESIGN.md`, `AGENT_DESIGN.md` §14, invariants 29–31 and 24–28.

Outcome: Experience, Knowledge, and Wisdom are distinct attributable versioned layers;
retrieval authorizes before ranking; correction/deletion propagates with proof; each layer
earns measurable value over the prior treatment.

Work packages:

- [ ] **P11-D** Define canonical record/lifecycle, scopes, epistemic kinds, provenance,
  contradiction links, validity, sensitivity, indexes, and token budgets over the Store.
- [ ] **P11-A — Experience:** admit only bounded verified outcomes/corrections with source
  digests; never treat transcript, model claim, recalled content, or raw Situation as truth.
- [ ] **P11-B — retrieval:** authority/sensitivity/layer/state/validity/compatibility before
  lexical/semantic candidate counts or ranking; honest capability reporting.
- [ ] **P11-C — Knowledge:** idempotent staged consolidation, recurrence/diversity/taint/
  contradiction gates, bounded model call, source preservation, rejection without mutation.
- [ ] **P11-D2 — correction/deletion:** supersede/quarantine immediately; propagate to
  indexes, caches, derived records, candidates, artifacts/backups under policy; emit receipt.
- [ ] **P11-W — Wisdom:** candidate → public eval → protected holdout → human/policy gate →
  behavior version → monitor/rollback; no candidate sees its holdout/evaluator.
- [ ] **P11-E** Compare no memory, Experience, Experience+Knowledge, and promoted Wisdom on
  identical tasks and budgets.

Hard gates: zero unauthorized/sensitive recall, zero memory-derived authority, provenance
coverage, contradiction visibility, deletion proof, and attributable task benefit.

### P12 — bounded self-healing and self-improvement

Authoritative inputs: `SELF_HEALING_DESIGN.md`, `AGENT_DESIGN.md` §§12–14, invariants 28 and
32–34, plus P6 effects and P11 memory.

Outcome: one narrow healing rule and one reversible behavior candidate pass independent
evaluation, promotion, monitoring, circuit, and rollback gates. Neither can approve itself
or widen authority.

Healing work packages:

- [ ] **P12-HD** Define typed failure/rule/remediation/verification/compensation/escalation/
  circuit records and lifecycle.
- [ ] **P12-H1** Implement classification and abstention; unknown, corruption, policy denial,
  programmer error, and unknown effects do not become generic retry.
- [ ] **P12-H2** Implement exact reviewed remediation, preconditions, current authority,
  attempt/scope/magnitude/cost/time budgets, effect reconciliation, independent verifier.
- [ ] **P12-H3** Add separately authorized compensation, durable circuit, owned escalation,
  replay → shadow → applicable fault injection → canary → active/retired transitions.
- [ ] **P12-H4** Promote at most one narrow reference rule (prefer stale conditional file
  edit or bounded pre-dispatch provider retry). Observation/shadow-only is acceptable when
  active evidence is insufficient.

Improvement work packages:

- [ ] **P12-ID** Define candidate provenance, train/holdout boundaries, affected behavior,
  policy/risk, artifact digests, evaluation lineage, activation scope, rollback target.
- [ ] **P12-I1** Generate one bounded planning/routing/verification heuristic candidate from
  verified trajectories; never activate live prompt/code changes during the task.
- [ ] **P12-I2** Run paired baseline/holdout evaluation, human gates for prompt hierarchy,
  tools, roots, credentials, policy, evaluator, skills/scripts, or code.
- [ ] **P12-I3** Activate as a new behavior/cache epoch at a turn boundary, pin in-flight
  sessions, monitor the same gates, inject regression, and prove rollback.
- [ ] **P12-S** Add bounded subagent/delegation only if the chosen candidate or product proof
  needs it: child graph/version/namespace, narrower grant, typed return, budgets, ordered fan-in.

Evaluation includes the applicable portion of the designed 250-case matrix before any
active healing claim. Hard zero: unsafe/unauthorized action, blind ambiguous retry, false
recovery, hidden compensation failure, evaluator tampering, self-promotion, or regression
surviving without rollback.

### P13 — durable scheduling

Authoritative input: `SCHEDULER_DESIGN.md`, `AGENT_DESIGN.md` §15, invariants 38–40 plus 23,
25–27, 35. Re-check `fugit` behavior/version at implementation time.

Outcome: optional `tamoz-scheduler` deterministically materializes one recurring read-only
product task into the ordinary durable request inbox exactly once per logical occurrence.

Work packages:

- [ ] **P13-D** Define package/store contract, Schedule/Occurrence values, immutable revisions,
  UTC identity, strict `at`/interval/cron, IANA timezone/DST, deterministic jitter.
- [ ] **P13-A** Implement SQLite schedule/occurrence store, CAS/fence, due scan, atomic
  occurrence/request identity via same transaction or durable outbox.
- [ ] **P13-B** Implement bounded misfire, overlap, concurrency, backlog, lease reclaim,
  pause/disable/delete/cancel, and separate delivery/execution statuses.
- [ ] **P13-C** Intersect stored maximum grants with current P8 policy; plan/review every
  occurrence; missing approval denies/escalates; self-management stays narrow.
- [ ] **P13-P** Ship one safe product consumer: a recurring reviewed read-only project status
  or scorecard summary, not an unattended mutation.
- [ ] **P13-E** Reference-calendar/fake-clock suite for DST gaps/folds, clock jumps, downtime,
  2–50 owners, crash seams, duplicate wakeups, races, revocation, headless approval.

Hard zero: duplicate logical turn, authority widening, fabricated approval, false-green task
success. Every due occurrence has exactly one durable reason.

### P14 — streaming input and physical-world assistance

Authoritative input: `STREAMING_INPUT_DESIGN.md`, `AGENT_DESIGN.md` §16, invariants 44–51.

Outcome: optional `tamoz-stream` converts one authenticated read-only physical source into
deterministic immutable Situations; bounded cognition proposes typed intent; only a simulator
receives commands through current-state policy and an independently controlled interlock.

Work packages:

- [ ] **P14-D** Select one safe supervisory profile and define channel/schema/source trust,
  SituationSpec, risk ceiling, Decision/Intent/Command/Outcome schemas, external interlock.
- [ ] **P14-A — admission/store:** versioned Channel/Event/Admission/StreamStore contracts,
  auth, tenant binding, bounds, units/time/sequence, dedup/conflict quarantine, durable ack,
  explicit bounded backpressure/gap outcomes.
- [ ] **P14-B — deterministic runtime:** stable virtual partitions, serial transition,
  event/processing time, watermarks/idleness, bounded windows/timers, late policy, atomic
  Situation/admission/outbox/checkpoint under virtual-time replay.
- [ ] **P14-C — cognition bridge:** bounded immutable SituationSnapshot, stable request,
  one episode per Situation, plan bound to snapshot digest, supersession/expiry rejection,
  typed Decision and ActionIntent only.
- [ ] **P14-P — action boundary:** reload current state after approval; check freshness,
  completeness, uncertainty, quality/quorum, health/calibration/gaps/conflicts, scope/bounds,
  quotas, expiry, separation of duty, external interlock, effect reconciliation.
- [ ] **P14-S — simulator proof:** deterministic, recorded-cognition, shadow, and
  counterfactual modes have no production credentials; first effector is simulator only.
- [ ] **P14-E** Golden traces for duplicates/reordering/late/idleness/skew/gaps/corruption/
  restart/races/overload; compare raw-event, window, and Situation treatments; independent
  safety review before any real adapter discussion.

Hard stop: any silent evidence loss, nondeterministic replay, direct model-to-effector path,
stale/superseded dispatch, replay reaching real effects, approval bypassing current state,
or ability to disable/heal around an interlock. R4 remains advisory-only. No raw video-rate
cognition, motor control, PLC loop, medical control, or certified safety function.

### P15 — release hardening and completion audit

Authoritative inputs: every promoted design, all 55 invariants as applicable, public API
inventory, SECURITY, packaging, migrations, and evaluation artifacts.

Outcome: an independently reproducible release candidate, not merely a green local tree.

Work packages:

- [ ] **P15-A — requirements audit:** map every objective, invariant, ADR, phase exit,
  capability, API, command, migration, and non-goal to direct evidence. Missing/indirect
  evidence is incomplete, not pass.
- [ ] **P15-B — compatibility:** supported Ruby matrix, RubyLLM/MCP/fugit ranges, event/API
  schemas, graph/behavior/catalog/profile versions, migrations, old-session resume/stop.
- [ ] **P15-C — operations:** SQLite backup/restore/corruption/disk-full, retention/deletion,
  observability/redaction, resource leak/soak, crash recovery runbooks.
- [ ] **P15-D — security:** dependency/license/provenance review, credentials/secrets,
  filesystem/command/content injection, MCP/skill/memory/scheduler/stream boundaries,
  zero unresolved high/critical findings.
- [ ] **P15-E — performance/value:** documented hardware/Ruby/dataset, p50/p95/p99,
  memory/FD/thread/cost/token/cache metrics, plain RubyLLM + job queue baseline, honest
  regressions and denominators.
- [ ] **P15-F — evaluation:** canonical case/evidence/result artifacts, pinned public and
  protected corpora, paired baseline, hard gates, insufficient/invalid separation, signed
  decision and reproducible verifier.
- [ ] **P15-G — product/docs:** install guides, architecture, tutorials, examples, API/event
  reference, security/limitations, migration/backup, changelog, licenses, gem contents.
- [ ] **P15-H — release rehearsal:** clean clone, dependency install, complete CI, package
  install without repository paths, example runs, restore/resume, signature/provenance.
- [ ] **P15-I — owner gate:** present the complete evidence and exact remaining risks. Push,
  tag, publish, announce, or enable any physical adapter only with explicit owner approval.

Completion is prohibited while any explicit requirement lacks direct evidence, any promoted
conditional invariant is untested, the worktree is dirty, or release reproduction depends
on the original development checkout.

## 7. Cross-phase non-negotiables

- Plan and both review layers precede every task action, including scheduled, delegated,
  healing, improvement, MCP, skill, memory-consolidation, and Situation-originated tasks.
- Approval never grants authority and never turns an unknown effect into a safe retry.
- Capability authority is local, source-qualified, content-addressed, intersected, and
  pinned for the turn/resume.
- Model/skill/MCP/memory/stream content is untrusted evidence or instruction content, never
  system policy, credentials, or permission.
- Deterministic safety/correctness gates run before model judgment and cannot be averaged
  away by task success.
- Every new capability adds a fixed behavioral case before it can be called complete.
- Every durable record is versioned, allowlisted, bounded, immutable at commit, and rejects
  sensitive values unless an explicit protection policy exists.
- No production gem depends on `tamoz-evals`; evals may lazily load selected subjects.
- No private RubyLLM API, generic shell supplied by model text, plugin framework, hidden
  scheduler, hidden retry loop, or direct physical actuation.
- Preserve existing user changes and stop on overlapping dirty work; never reset them away.

## 8. Start-of-turn runbook for the next agent

```sh
cd /Users/ghassan/my-projects/tamoz
git status --short
git log -5 --oneline
git branch --show-current
git rev-list --count origin/main..HEAD
sed -n '1,260p' docs/PROJECT_HANDOVER_PLAN.md
sed -n '1,220p' docs/PRODUCT_EXECUTION_ROADMAP.md
rbenv exec bundle exec tamoz-eval scorecard agent-smoke
```

Then:

1. confirm the worktree is clean and no user changes overlap;
2. confirm P7 is the only active phase;
3. read P7's authoritative sections and current `Session`, `Runtime`, `CLI`, P3 corpus/tests;
4. create the P7 plan and plan review;
5. commit those documents before implementation;
6. implement only P7; deep-review, run full CI, commit, update trackers;
7. stop and report the checkpoint before beginning P8 unless the owner explicitly asks to
   continue.

If the scorecard or CI is already red at the unchanged baseline, diagnose the regression
before adding capability. Do not update expected numbers merely to make it green.

## 9. Handover completion matrix

| Objective | Current proof | Remaining completion phase |
|---|---|---|
| Tamoz name and Ruby monorepo | package/app manifests and existing gems | P15 packaging audit |
| plan before action + review | P0–P3 runtime and hard-gate scorecard | regress every phase; durable proof P6 |
| smart bounded action | P2 repair policy + P3 metrics | P4–P5 capability, P11–P12 adaptation, P15 value comparison |
| evaluation as a core gem | `tamoz-evals`, canonical artifacts, P3 scorecard | extend each phase; signed evidence P15 |
| useful coding agent | existing exact edit/check/repair | P4–P8 |
| crash-durable agent | `Tamoz::Agent::Session` over the existing durable contracts; sixteen real `kill -9` seams | P7 resumable CLI; P6-F remainder |
| trusted configuration | design only | P8 |
| skills | accepted design only | P9 |
| MCP-native support | accepted design only | P10 |
| Experience/Knowledge/Wisdom memory | accepted design only | P11 |
| bounded self-healing and improvement | accepted design only | P12 |
| scheduled tasks | accepted design only | P13 |
| streaming physical-world assistance | accepted design only | P14 simulator/interlock profile |
| release-ready framework/agent | incomplete | P15 requirement audit and release candidate |

The project goal is not complete today. This matrix must reach direct, verified evidence in
every row before the goal can be marked achieved.
