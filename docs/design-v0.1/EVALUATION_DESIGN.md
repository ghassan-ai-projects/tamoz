# Evaluation

Evaluation has seven layers: conformance, model-based determinism, fault injection,
performance, security/operations, product value, and adaptive-behavior quality.

Passing unit tests is necessary and insufficient.

[EVALS_DESIGN.md](EVALS_DESIGN.md) packages this strategy as `tamoz-evals`. This document
defines what must be evaluated; the gem design defines case/result artifacts, scorer
precedence, protected holdouts, execution profiles, baseline comparison, and release gates.

## 1. Conformance

The 61 clauses in [INVARIANTS.md](INVARIANTS.md) are named shared examples. Third-party
adapters run the same examples unchanged.

Published suites:

- `"a tamoz checkpointer"` — consistent load, idempotent task writes, atomic
  compare-and-append, lazy history, deletion protection;
- `"a tamoz lease provider"` — exclusivity, renewal, expiry, monotonic fence, stale-write
  rejection;
- `"a tamoz effect journal"` — prepare/complete idempotency, safety transitions,
  attempt-token ownership, late receipt after graph-lease loss, reconciliation, unknown
  handling;
- `"a tamoz request inbox"` — atomic enqueue/claim-next, input-digest conflict, FIFO,
  redirect/recovery, join/return behavior,
  terminal checkpoint linkage;
- `"a tamoz store"` — namespace isolation, compare-and-set, iteration, searchable-capability
  honesty;
- `"a tamoz schedule store"` — immutable revision compare-and-set, unique/fenced
  occurrences, atomic request/outbox linkage, due pagination, and tombstones;
- `"a tamoz stream store"` — event admission/dedup, partition compare-and-append,
  watermark/timer recovery, immutable Situations, admission/outbox atomicity, and replay;
- `"a tamoz capability catalog"` — source-qualified identities, canonical digests, grant
  intersection, immutable epochs, and exact-snapshot resume;
- `"a tamoz state codec"` — registered-type round trip, rejection, versions, limits,
  sensitive-value policy.

Inline and threaded engines share identical committed expectations. Fiber mode becomes
supported only when the same suite passes. Live event timing is not expected to match.

## 2. Model-based determinism

A small reference model represents graph semantics independently of production planner and
barrier code. Property tests generate:

- graph definitions with linear, branch, cycle, fan-out/fan-in, and subgraph shapes;
- state schemas with compatible reducer/write patterns;
- completion, failure, interrupt, cancellation, and retry schedules;
- external input duplicates and lease-owner races.

For each generated case:

1. run the model;
2. run Tamoz inline;
3. run Tamoz threaded under randomized delays;
4. compare checkpoint state, sequence, pending writes, scheduled tasks, and interrupts.

Golden tests still pin task/effect identity recipes. Mutation testing targets planner,
barrier, version checks, lease validation, and result ordering; surviving mutations in
those files block release.

## 3. Fault injection

### Checkpoint matrix

Kill a subprocess before and after every storage action in:

- input append;
- task-write append;
- interrupt persistence;
- checkpoint compare-and-append;
- pending-write consumption;
- lease acquire/renew/release;
- migration;
- prune/delete.

After recovery, observe either the prior committed state or the complete next state. No
partial checkpoint is valid.

### Effect matrix

For each safety class, kill at:

```text
before prepare
after prepare / before call
during call
after target success / before receipt
after receipt / before graph task write
after task write / before checkpoint commit
```

Expected outcomes:

| Safety | Required recovery |
|---|---|
| read-only | retry and converge |
| idempotent | same key reaches one target outcome |
| transactional | local transaction proves the result |
| reconcilable | query target, then complete or unknown |
| unsafe | unknown and paused; zero automatic retries |

The side-effect ledger lives at the target boundary. A graph checkpoint cannot be used as
proof that the target ran once.

### Lease race

Start owner A, let its lease expire, acquire with B, then release A's delayed task result.
B may commit. A must receive `LeaseLostError`; no stale pending write or checkpoint is
accepted.

### Storage faults

Inject `SQLITE_BUSY`, disk full, permission loss, corrupt payload, truncated WAL copy,
failed migration, clock jump, and process termination. Backup/restore tests copy the
database together with required WAL state through SQLite's backup API, not raw file copy
while open.

## 4. Execution-output streaming and resource safety

This section evaluates bounded `StreamPart` projection from one graph run, not unbounded
input channels; §16 evaluates `tamoz-stream`.

For every event index in a representative run, close the public Enumerator:

- queue size never exceeds its configured capacity;
- cancellation reaches coordinator/workers;
- owned threads/fibers terminate within a bounded grace period;
- open cursors, files, sockets, and database connections return to baseline;
- no post-cancel task state commits;
- an in-flight external effect is reconciled rather than assumed cancelled.

Soak tests track RSS, thread count, file descriptors, SQLite connections, and WAL size over
ten thousand short sessions.

## 5. Performance

Absolute thresholds are provisional until measured on named reference hardware. Every
published result records:

- CPU/OS, storage, Ruby engine/version, SQLite version;
- graph shape and serialized state bytes;
- warmup and sample count;
- p50, p95, p99, allocations, and retained memory;
- plain Ruby/in-memory and SQLite-direct baselines.

Initial release budgets:

| Benchmark | Budget |
|---|---|
| In-memory linear super-step | ≤ 2× plain function/reducer baseline and < 1 ms p95 on reference hardware |
| SQLite small-state commit | < 10 ms p95 on local SSD |
| Resume from 500 checkpoints | < 50 ms p95 |
| 50-task fan-out scheduler overhead | < 10 ms p95 excluding task work |
| 200-message codec round trip | < 20 ms p95 |
| Idle compiled graph retained memory | < 500 KB |
| Stream early-close worker cleanup | < 1 s p99 absent uncooperative user code |

Regression gates compare against the previous release on the same runner: >15% p95 or
allocation regression requires explanation. Provider latency is excluded from engine
benchmarks.

## 6. Security and privacy

Tests cover:

- path traversal, symlink escape, and time-of-check/time-of-use for file tools;
- shell argument canonicalization, environment filtering, approval binding, and
  `approve_always` scope;
- prompt injection in files, tool output, skills, and MCP metadata;
- MCP OAuth/redirect/SSRF/token-audience/stdio-process isolation and protocol/schema
  downgrade or drift;
- skill archive/path/link/same-name shadowing, load-time execution, dependency, secret, and
  capability-escalation attacks;
- scheduled delayed-authority, headless approval, backlog/restart-storm, and self-edit
  attacks;
- duplicate/oversized/deeply nested serialized values and unknown type tags;
- credentials in checkpoints, streams, logs, traces, errors, `inspect`, spill files, and
  trajectories;
- tenant namespace escape in Store;
- forged/expired approval and lease records;
- tool hooks attempting to widen policy;
- dependency audit, locked CI permissions, package-content review, and release provenance.

Red-team fixtures are deterministic policy tests. Model behavior is not accepted as the
security boundary.

## 7. Observability

An integration test sends a run through the OpenTelemetry bridge and asserts:

- parent/child run, task, tool, model, checkpoint, interrupt, and effect relationships;
- stable versioned event schemas;
- lease wait/loss, checkpoint latency/error, queue saturation, unknown effect, cancellation,
  retry, provider usage, and cache-read/write metrics;
- no high-cardinality ids used as metric labels;
- no content captured under the default policy.

Every surfaced error includes run/thread-safe correlation ids and a safe message. Operators
can locate the raw protected trace without exposing it to the model or CLI by default.

## 8. Does the framework earn itself?

Build the same reference workflow:

1. directly on RubyLLM plus ordinary Ruby persistence/jobs;
2. on Tamoz.

Compare:

- application and state-management code;
- time to add approval, parallel branch, resume, and graph migration;
- failure behavior at effect/receipt ambiguity;
- stack depth and ability to explain the next scheduled task;
- artifacts required to operate and debug it;
- performance and maintenance surface.

Tamoz must be clearly better at durable state, approval, replay, and ambiguity handling.
Fewer lines alone do not win if the result is harder to reason about.

The README usability test uses a Ruby developer unfamiliar with Tamoz. Target: a working
read-only tool agent in fifteen minutes. The first side-effecting example must introduce
effect safety and approval explicitly; hiding them to hit a line-count goal is failure.

## 9. Tamoz Agent evaluation

- fixed repository task corpus with pinned model configuration;
- success, turns, tool calls, wall time, reported/estimated tokens, and cost;
- cache reads/writes and epoch transitions with reasons;
- duplicate-input and redirect scenarios;
- exact plan/review gating, material replanning, and clarification scenarios;
- evidence attribution, uncertainty calibration, definition-of-done verification, and
  unnecessary-action counts;
- approval red-team suite;
- crash cases including an intentionally ambiguous unsafe tool;
- behavior-candidate evaluation, promotion, resume pinning, monitoring, and rollback;
- sanitized JSONL trajectories with format/version and content-policy metadata.

Agent quality metrics are separated from runtime correctness. A model regression must not be
misdiagnosed as a scheduler regression, or vice versa.

## 10. Deliberation and improvement evaluation

A fixed task corpus includes simple questions, underspecified work, read-only investigations,
multi-step code changes, reversible effects, and unsafe/irreversible requests. Each case has
a machine-readable definition of done, allowed evidence sources, risk label, expected
clarifications, and prohibited actions.

Plan quality measures:

- goal and completion-condition coverage;
- assumption and uncertainty identification;
- dependency ordering and proportionality;
- tool/resource/effect/approval accuracy;
- verification and recovery coverage;
- structural and semantic review precision: unsafe or incoherent plans rejected without
  rejecting harmless one-step plans;
- critic independence for medium/high-risk plans and exact review-to-plan digest binding.

Execution quality measures task success, evidence precision/recall, verification coverage,
unnecessary actions, corrections, unsafe attempts, latency, and cost. Calibration buckets
compare stated confidence with observed success. The score does not reward verbosity, plan
length, tool count, or self-reported confidence.

Improvement evaluation uses immutable baseline, candidate, evaluator, dataset, and policy
digests. The candidate-generating trajectories are excluded from the holdout. Promotion
requires a configured minimum benefit with no safety/correctness regression and bounded
latency/cost regression. Tests attempt evaluator mutation, training-data leakage,
self-approval, capability widening, stale compare-and-set activation, resume under a newer
behavior version, and post-promotion regression. Each must reject, remain pinned, or roll
back as specified.

No candidate may define its own success metric or remove failing examples. Human-approved
evaluator changes start a new evaluation lineage and cannot retroactively validate an older
candidate.

## 11. Memory evaluation

Run the same representative corpus with no durable memory, Experience only, Experience plus
Knowledge, and all three layers including evaluated Wisdom. Pin everything except the memory
treatment. Measure task-success delta alongside precision/helpful-recall, contradiction,
stale/sensitive/unauthorized recall, wrong-memory harm, provenance coverage, token/cost
overhead, correction latency, and deletion propagation.

Adversarial cases seed relevant but cross-user, expired, superseded, untrusted,
self-recalled, and contradictory memories. Authorization must remove them before ranking.
Consolidation cases verify taint gates, source links, preimage recovery, bounded prior-entry
loss, conflict preservation, and non-ingestion of human-readable reflection artifacts.

Wisdom uses public development cases plus the protected holdout. A result must show value
over Knowledge without changing permission or hiding safety/cost regressions. Sensitive and
unauthorized recall are hard-zero gates.

## 12. Self-healing evaluation

The reference matrix is ten failure classes across ingest/plan/execute/verify/persist, each
with five deterministic seeds: 250 isolated cases. The controller owns the injected fault,
allowed/forbidden actions, invariant, deadline, and oracle. The subject receives only the
typed failure and rule authority.

Reports separate detection precision, precondition rejection, verified recovery,
compensation, escalation, circuit-open, unresolved, unsafe-action, duplicate-effect,
recurrence, latency, and cost. A tool success or zero exit code is never the recovery oracle.

Promotion progresses replay → shadow → fault injection → canary → active. Unsafe or
unauthorized mutation, blind ambiguous retry, false recovery, evaluator/rule tampering, or
concealed compensation failure blocks promotion regardless of aggregate recovery rate.

## 13. MCP evaluation

Run official MCP conformance for every advertised stable protocol profile, then Tamoz host
cases that the wire specification does not own. Pin server configuration, discovery
snapshot, local capability policy, credential handles, and effect classes.

The matrix covers stdio and Streamable HTTP startup/teardown, version negotiation,
stateless/stateful compatibility, malformed/oversized frames, invalid schemas, list/TTL
churn, output-schema mismatch, disconnect, timeout, process crash, OAuth expiry/revocation,
SSRF/redirect/DNS-rebinding defenses, and ambiguous effects. Malicious names, annotations,
prompts, resources, logs, and results attempt policy and prompt-hierarchy changes.

Elicitation and multi-round-trip input are killed/resumed at each checkpoint seam.
Unattended cases must deny or route to the declared approval destination. Hard gates are
zero credential/content-policy leak, zero remote authority gain, exact epoch replay, no
orphan stdio process, and no blind retry of an ambiguous non-idempotent call.

## 14. Scheduler evaluation

A reference calendar model plus fake wall/monotonic clocks generates `at`, interval, and
cron histories across IANA zones. Property cases include DST gaps/folds, leap days,
timezone-data changes, clock jumps, deterministic jitter, long downtime, edits/deletes,
misfire/overlap policies, saturation, and manual runs.

Race one to fifty owners and kill at occurrence claim, outbox, request claim, graph start,
and terminal receipt. Every due occurrence must have exactly one durable reason:
enqueued, skipped, coalesced, disabled, expired, or unresolved. One nominal occurrence maps
to one logical request even if delivery repeats.

Behavioral cases revoke grants after creation, remove approval destinations, change
behavior/capability catalogs, and attempt self-edit from the running job. Hard gates are
zero duplicate logical turns, zero fabricated approval, zero authority widening, bounded
catch-up/queue growth, and no delivery-success/task-success confusion.

## 15. Skills evaluation

Validate portable Agent Skills fixtures and Tamoz canonical tree digests. Selection cases
measure precision, recall, abstention, confusable negative triggers, explicit invocation,
token cost, and task success against no-skill and prior-skill baselines.

Security cases fuzz YAML, archive bombs, absolute/traversal/case-collision paths, symlinks,
hard links, devices, same-name cross-source collisions, file watcher races, changed bytes
under one version, nested prompt injection, dependencies, scripts, environment, secrets,
and network. Loading must remain inert; resource/script access uses the exact snapshot and
ordinary authorization.

Install/update/uninstall and self-proposed-skill workflows are killed at each seam. Hard
gates are zero resource escape, zero implicit authority, zero silent shadowing, exact digest
resume, isolated candidate/holdout evaluation, and measurable task benefit without
safety/cost/latency regression.

## 16. Streaming input and physical-world evaluation

Use a deterministic simulator with virtual event and processing time. Golden traces include
valid events, duplicates, conflicting ids, out-of-order and late events, idle sources,
clock skew, sequence gaps, corrupt payloads, restart, partition races, overload, and
mid-episode Situation correction. Situation versions, watermarks, admission history, and
outbox bytes must be identical on replay.

Compare three treatments on the same protected scenarios:

1. raw recent events in the prompt;
2. deterministic window dumps;
3. the admitted immutable Situation snapshot.

The third must improve useful-outcome quality or cost/latency without weakening safety.
Measure event absorption, visible loss/gaps, lag, bounded state, Situation precision/recall,
detection time, false/stale admission, cognition cost per useful outcome, supersession,
calibration, command denials, duplicate/unknown effects, reconciliation, and observed
physical outcomes.

Policy/adversarial cases inject sensor forgery, prompt text in evidence, stale approvals,
changed device state, missing/disabled interlocks, direct-effector attempts, ambiguous
receipts, and production-looking replay payloads. Hard-zero gates are silent evidence loss,
direct model-to-effector access, stale or out-of-scope dispatch, real effects during
replay, safety-controller bypass, and self-promoted SituationSpec/authority.

The initial effector is simulated. A real read-only source may be used for ingestion and
Situation accuracy, but real physical commands require a separate deployment-specific
safety case and independent review beyond framework release.

## 17. Explicit exclusions

v0.1 does not claim:

- arbitrary remote effects execute exactly once;
- multi-host throughput;
- cross-language benchmark superiority;
- model-quality superiority;
- immediate cancellation of arbitrary Ruby or remote code;
- recovery after loss of the database and all backups.
- certified functional safety, hard real-time control, or general robot/medical-device
  fitness.
