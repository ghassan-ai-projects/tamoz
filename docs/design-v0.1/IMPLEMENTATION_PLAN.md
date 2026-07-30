# Implementation plan

Risk-first milestones with independently usable release increments. Estimates are planning
ranges, not delivery commitments.

The critical path proves the failure model before adding agent features. `tamoz-chain`,
Rails/ActiveRecord, streaming input, MCP, durable scheduling, TUI, and gateway work are not
on the v0.1 foundation path. Their contracts are fixed now so later promotion cannot weaken
core semantics. Memory/skills and healing/improvement are staged releases rather than one
correlated milestone. `tamoz-stream` is the first physical-world product milestone after the
durable agent releases.

## Build order

| M | Milestone | Range | Exit criterion |
|---|---|---:|---|
| 0 | Decisions, skeleton, and eval contract | 5–8 days | names/product shape decided; four runtime gem skeletons plus `tamoz-evals`; canonical case/result schemas, CLI verifier, baseline fixture, twelve golden cases; CI on Ruby 3.3/3.4/4.0 |
| 1 | Core contracts | 5–8 days | Context, immutable value boundary, StreamPart/sink, errors, notifier, ordered inline/thread pools |
| 2 | Deterministic in-memory graph | 10–15 days | clauses 1–15 and 52 pass; property tests cover activation/attempt ids, reducers, routing, threaded interrupt capture, and bounded stream shutdown |
| 3 | SQLite durability foundation | 10–15 days | clauses 18–24 and 53–54 pass; atomic commit, durable request inbox, leases/fences, tombstones, effect journal, crash matrix, corruption/FD tests |
| 4 | RubyLLM vertical slice | 5–8 days | one public RubyLLM generation seam; durable model and one read-only/idempotent tool; no upstream internals |
| 5a | v0.1 deliberative Tamoz Agent | 10–14 days | discovery/action plan review, replan/verify gates, tool policy/effects, budgets, compaction, CLI, and one real repository task; clauses 25–27 and 55 pass |
| 5b | v0.2 memory and skills | 12–18 days | Experience/Knowledge/Wisdom treatment evidence; Agent Skills-compatible content-addressed catalog/load/resources; clauses 29–31 and 41–43 pass |
| 6 | v0.3 healing and improvement proof | 18–27 days | one rule through replay/shadow/250-case fault/canary; one behavior promotion/rollback; subagents and candidate learning; clauses 28 and 32–34 pass |
| 7 | Program hardening | 14–22 days | every applicable clause; protected holdout and signed comparisons; security review; migration/backup restore; benchmarks; public docs and API review |

M2 proves deterministic execution. M3 proves durability. Neither may claim “no duplicate
effects” until the M3 effect-seam tests pass.

## Dependency path

```text
M0 → M1 → M2 → M3 → M4 → M5a → M5b → M6 → M7
```

Each milestone produces a usable artifact:

- M1: small runtime primitives;
- M2: deterministic ephemeral graph engine;
- M3: durable Ruby workflow runtime;
- M4: minimal durable RubyLLM graph;
- M5a: usable v0.1 Tamoz Agent foundation;
- M5b: evaluated memory/skill v0.2;
- M6: bounded healing/improvement v0.3.

## Test strategy by milestone

### M0

- Markdown link and invariant-count lint;
- clean-process dependency checks;
- public API inventory checked against docs.
- canonical eval case/result schemas and digest fixtures;
- `tamoz-eval verify` plus pass/fail/invalid/insufficient-evidence exit-code tests;
- twelve golden cases spanning conformance, planning, memory authorization, remediation
  boundaries, safety, and evidence;
- dependency test proving production gems and Tamoz Agent do not load `tamoz-evals`.

### M1

- contract/unit tests;
- state codec round trips and rejection tests;
- pool equivalence under randomized completion timing;
- bounded-stream early-close and resource cleanup.

### M2

- model-based scheduler tests;
- reducer property tests;
- interrupt fuzzing under inline and threads;
- mutation testing on planner/barrier/task-id code;
- replay/fork corpus.

### M3

- subprocess kill injection before/after each durable write;
- effect kill points: prepared, executing, succeeded, receipt commit;
- two-owner lease/fence races;
- SQLite busy/full/corrupt/restart/backup/restore;
- connection and file-descriptor leak soak.

### M4–M7

- recorded provider tests with network disabled in CI by default;
- RubyLLM compatibility matrix on the supported minor range;
- tool-policy red team;
- cache-prefix canonicalization tests;
- plan/review digest and replan-bypass tests;
- bounded discovery-plan containment and action-plan separation tests;
- evidence/verification and calibrated-uncertainty fixtures;
- three-layer memory admission/retrieval/consolidation/conflict/forgetting/deletion treatments;
- typed remediation, precondition, effect ambiguity, verification, compensation, circuit,
  and 250-case fault-injection suites;
- candidate provenance, holdout isolation, promotion, resume-pinning, and rollback tests;
- Agent Skills format, source collision, tree digest, progressive disclosure, path/script
  containment, install/update crash, selection, and no-skill/current-skill comparisons;
- end-to-end Tamoz Agent sessions and golden sanitized trajectories.

## Scope gates

An extension may enter the roadmap only when all are true:

| Extension | Promotion evidence |
|---|---|
| `tamoz-chain` | two shipped consumers repeat the same pipeline/stream plumbing |
| Rails/ActiveRecord | owner chooses Rails-first or one production consumer exists |
| `tamoz-mcp` | one real server; official plus Tamoz host conformance; pinned catalog; OAuth/stdio security; durable elicitation/effects |
| `tamoz-scheduler` | one recurring product task; reference calendar model; occurrence/request crash/race suite; delayed-authority policy |
| `tamoz-stream` | one real read-only physical source plus simulated effector; deterministic event-time/Situation replay; bounded overload; protected treatment comparison; independent safety review |
| TUI | CLI workflow is stable and namespace stream routing has a concrete UI need |
| Gateway | one channel's delivery dedup, approval, and identity rules are specified |

The second adapter is not built merely to “prove abstraction.” A fake/reference adapter plus
SQLite conformance proves the contract until a real second consumer appears.

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Side-effect guarantee overclaim | high | severe | ADR-016, effect safety classes, `:unknown`, kill injection at effect/receipt seam |
| Same thread advanced concurrently | medium | severe | durable leases, fences, compare-and-append, race tests |
| Graph changes break in-flight runs | high | high | graph identity/digest, node versions, explicit migrations |
| RubyLLM one-generation semantics drift across supported minors | medium | high | M4 contract tests pin public `generate`/`step` behavior and stop before any internal reach-around |
| SQLite writer contention | medium | medium | short transactions, bounded busy retry, metrics, stress tests |
| Streaming leaks threads/memory | medium | high | bounded sink, cooperative cancellation, `ensure` cleanup, early-close fuzzing |
| Sensitive content leaks into artifacts | high | severe | explicit classification/redaction, no content capture by default, security tests |
| Prompt-cache drift | medium | high | canonical epoch digest, recorded transition reasons, provider cache metrics |
| Planning becomes performative overhead | medium | high | persisted digest-bound plans, action gate, proportional one-step plans, plan-quality metrics |
| Planning begins without enough evidence | high | high | separately reviewed bounded read-only discovery, cited evidence, and a new action-plan review |
| Self-improvement rewards its own mistakes | high | severe | holdout isolation, immutable evaluator versions, human gate for evaluator/capability changes, rollback |
| “Smart” behavior becomes an untestable prompt claim | high | high | evidence, uncertainty, verification, and unnecessary-action metrics on a fixed task corpus |
| Scope creep | high | high | four runtime gems, one tightly scoped eval gem, and evidence-based promotion gates |
| Benchmark gaming or moving thresholds | high | severe | protected holdout, immutable evaluator lineage, paired baseline, hard safety gates |
| Memory makes behavior confidently worse | high | severe | Experience/Knowledge/Wisdom separation, authorize-before-rank, treatment eval, provenance/conflict/deletion gates |
| Self-healing expands damage | high | severe | typed rules, exact reviewed plan, original authority, bounded scope, effect reconciliation, independent verifier, circuit |
| MCP server changes or attacks host policy | high | severe | official SDK, pinned source-qualified catalog, local risk policy, OAuth/SSRF/stdio isolation, effect ambiguity |
| Scheduler duplicates or wakes with stale authority | medium | severe | durable occurrence identity, fencing/request dedup, explicit misfire/overlap, current-policy intersection |
| Skill supply chain or instructions escalate capability | high | severe | tree digests, explicit source binding, inert loading, path/script boundary, staged comparative evaluation |
| Sensor forgery, gaps, or time skew create a false Situation | high | severe | authenticated typed admission, hashes/sequences, explicit quality/watermarks/gaps, redundant-source and adversarial simulation |
| Stream overload turns into agent storms or silent loss | high | severe | bounded channels/state, declared backpressure, durable admission outcomes, coalescing/supersession, cognition as expendable plane |
| Stale inference causes physical harm | high | severe | immutable snapshot, current-state revalidation, typed intent, command expiry/bounds, external interlocks, simulated first effector, R4 advisory-only |
| Single-maintainer load | high | high | independently valuable milestones; adapters/extensions deferred |

## Kill and redesign criteria

- **M2:** if inline/threaded committed checkpoints cannot be made identical, stop. Do not
  build durability on a nondeterministic engine.
- **M3:** if SQLite cannot provide atomic compare-and-append plus reliable fenced ownership,
  replace its persistence design before integrating an LLM.
- **M3:** if unsafe ambiguous effects cannot reliably stop without re-execution, remove
  automatic resume for effect-bearing nodes.
- **M4:** if Tamoz must patch or call RubyLLM internals, establish an upstream public seam or
  abandon the adapter.
- **M6:** if Tamoz Agent needs repeated internal reach-arounds, move the seam before release.
- **M6:** if plan review can be bypassed by tool, subagent, resume, or replan paths, stop and
  fix the execution gate before expanding agent capability.
- **M6:** if a promoted candidate can change its evaluator, widen capability, or survive a
  measured regression without human action, disable automatic promotion.
- **M6:** if unauthorized, sensitive, expired, superseded, or contradictory memory can enter
  ranking/context, disable durable recall and promotion until the boundary is structural.
- **M6:** if a remediation can claim recovery without the rule's independent oracle, retry
  an unknown effect, broaden scope, or reset its circuit, ship observation/shadow only.
- **M7:** if skill loading can execute code, grant a tool, escape its tree, silently shadow
  a source, or resume changed bytes under an old identity, disable third-party skills.
- **M6:** if Tamoz is not materially clearer and safer than hand-written RubyLLM plus a job
  queue for the reference task, ship Tamoz Agent directly and archive the framework.
- **Stream promotion:** if virtual-time replay is nondeterministic, overload loses evidence
  silently, an episode can act after supersession, or replay can reach a real effector,
  stop before any physical adapter.
- **Physical action:** if a deployment cannot keep functional-safety control external and
  prove current-state/interlock checks independently of the model, ship observe/advisory
  mode only.

## Release definitions of done

### v0.1 — durable deliberative foundation

- clauses 1–27 and 52–55 pass under inline and threaded modes;
- SQLite passes the full persistence, lease, effect, migration, backup, corruption, and
  resource-leak suites;
- Tamoz Agent completes and resumes a real task without internal APIs;
- every task action is authorized by an accepted exact action-plan version; insufficient
  evidence uses a bounded reviewed discovery plan; material completion has recorded
  verification evidence;
- supported effects are replay-safe and unsupported ambiguity is surfaced safely;
- public API and event schemas are documented with runnable examples;
- zero high/critical security findings in a focused review;
- benchmark results include hardware, Ruby version, dataset, p50/p95/p99, and a plain-Ruby
  baseline;
- `tamoz-evals` verifies every result digest and produces a signed release decision from a
  pinned baseline and protected holdout without entering the production dependency graph;
- gems require MFA publishing, signed provenance where available, locked CI permissions,
  dependency review, and reproducible package contents.

### v0.2 — evaluated memory and skills

- Experience/Knowledge/Wisdom each demonstrate attributable value over the prior treatment;
- unauthorized/sensitive recall is zero and correction/deletion reaches every recall path;
- one portable skill beats the no-skill/current baseline by exact tree digest and passes
  collision, containment, script, update, and capability-intersection gates;
- clauses 29–31 and 41–43 pass.

### v0.3 — bounded healing and improvement

- one bounded improvement beats its pinned holdout baseline, activates as a new behavior
  version, remains pinned across resume, and rolls back under injected regression;
- one narrow self-healing rule passes replay, shadow, the applicable 250-case matrix, and
  canary with zero unsafe action, duplicate effect, false recovery, or self-promotion;
- clauses 28 and 32–34 pass.

## Post-v0.1

Only after the applicable Tamoz Agent release is stable:

1. promote `tamoz-stream` with one real read-only physical source, a simulated effector,
   and clauses 44–51;
2. promote `tamoz-mcp` with one real server and clauses 35–37;
3. promote `tamoz-scheduler` with one recurring product task and clauses 38–40;
4. choose Rails/ActiveRecord only from actual demand;
5. build the second surface;
6. reconsider `tamoz-chain`;
7. evaluate a Postgres adapter when multiple hosts need to advance threads.
