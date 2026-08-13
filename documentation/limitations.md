# What Tamoz v0.1 does not do

This page is the honest counterpart to the README. Every entry is something a
reader could reasonably assume works, and does not. It is bound to the release
audit by `test/documentation_surface_test.rb`: the release-blocking gaps listed
here must be exactly the gaps
[`../docs/requirements-audit.json`](../docs/requirements-audit.json) measures,
so this page cannot quietly fall behind the product.

Current version: `0.1.0.alpha.1` (pre-release).

Read it before deciding whether Tamoz fits your problem.

## Release-blocking gaps

These are the gaps the measured release audit currently reports. Each one has a
heading below; when a gap closes, this page is corrected at the same time.

### Durable barrier timing remains partial (ADR-015)

Tamoz commits durable graph barriers synchronously, but the release evidence does
not yet establish the post-v0.1 timing and crash-boundary guarantees described by
ADR-015 across every storage and deployment configuration. Treat the checkpoint
as durable only after the store reports its commit; do not infer external effect
visibility from a committed checkpoint.

### Single-writer recovery evidence remains partial (invariant 20)

The checkpoint store is designed around one fenced writer per thread namespace,
but the current release audit still reports a failing takeover test. Treat a
failed single-writer evidence gate as a release blocker until the expired-owner
and concurrent-owner cases are green together.

### Cron and civil-time scheduling (invariant 39)

`tamoz-scheduler` ships `at` (one-shot at a UTC instant) and `interval` (every
N seconds). **Cron expressions and IANA timezones are not implemented.** There
is no DST handling, no `America/New_York`, no `0 9 * * MON`. The misfire,
overlap, backlog, jitter and catch-up policies the invariant also requires ARE
implemented and tested; the civil-time half is absent, so the clause cannot be
claimed as a whole.

If you need "every weekday at 09:00 local time", Tamoz cannot express it.

### Skill installation and update (invariant 43)

Skills are compiled from operator-configured directories into immutable,
content-addressed snapshots, and their content grants no authority. **There is
no install, update, or self-improvement pipeline**: no quarantine staging, no
provenance checks on a downloaded artifact, no atomic activation of a new
digest. You place skill trees on disk yourself, out of band.

### Channel communications (invariants 56–58, ADR-041–043)

The channel contract gem (`tamoz-comms`), Telegram adapter (`tamoz-telegram`),
durable admission/outbox, gateway process, pairing, and worker turn projection
are shipped and covered by focused tests and autonomy cases. Telegram is
therefore a real, configured operator surface; it is not accurate to describe
it as absent.

The latency investigation's deterministic channel work is implemented: the CLI
uses an independent outbound drainer, retry deadlines and pacing are durable,
accepted acknowledgements and typed `/help`, `/status`, and `/cancel` controls are
covered, and ambiguous sends remain durable `unknown` and are never blindly retried.
The remaining release evidence is a real-provider end-to-end qualification, broader
surface-revision/coalescing proof, and aggregate subprocess/locale gate stability.
See [`../docs/COMMS_TELEGRAM_PLAN.md`](../docs/COMMS_TELEGRAM_PLAN.md) and
[`../docs/ux-latency-investigation/IMPLEMENTATION_EVIDENCE.md`](../docs/ux-latency-investigation/IMPLEMENTATION_EVIDENCE.md)
(repository-internal archive) for the current boundary.

### Observability remains partial (invariants 59–61, ADR-044–047)

The closed signal catalog, deterministic correlation, bounded local journal,
content policy, derived local metrics, model cost basis, worker producers,
`observe` commands, and hardened optional OTLP/HTTP adapter are implemented.

The full observability contract is not yet release-complete. The authoritative
SQLite read-only telemetry adapter and durable model-usage persistence are not
implemented, so `tamoz trace` currently reconstructs only journal documents and
cannot claim the complete checkpoint/effect tree. The four-way crash/non-
interference proof, full all-surface secret property test, export sampling,
divergence accounting, and benchmark remain outstanding. The local journal is
observer-only and every bounded bulk drop is counted; it is not a second source
of truth. Alerting and automated response are intentionally outside this phase
and require separate authorization under phase 5 / ADR-048.

### Evaluation hard gates are not currently release-green (objective 3)

The evaluation contract keeps unauthorized effects, duplicate effects, unknown
effect retries, and headless approvals at zero. The current committed evaluation
evidence does not satisfy every release gate, so a passing feature test is not a
release claim.

### Coding behavior scorecard remains incomplete (phase P3)

The deterministic coding-agent scorecard still reports incomplete behavior
coverage. It must be regenerated from the owning test and reviewed with its
hard-safety counters before the P3 exit criterion can be claimed.

## Operator visibility is partial

`tamoz status --json` reports pending work, paused approvals, blocked (`:unknown`)
effects, budget exhaustions, capability sources, the dispatchable capability
catalog, memory configuration, and evidence-derived safety counters. Schedule
occurrences are on `tamoz schedule occurrences`.

**Not reported:** recent completions, and circuit state. Neither has a
cross-cutting query today — the circuit store is per scope and scope id with no
enumeration, and terminal requests leave the pending view by design. Both need a
new read-only storage query and a boundary-registry entry.

## Retired and absent capability areas

### The P14 streaming-input engine is retired

The supervised episode worker does not consume a continuous input stream —
that was the retired P14 engine's job. Tamoz now runs one sealed, digest-
verified Situation snapshot per episode; the stream (the agentic-stream
runtime) owns the continuous plane (event time, watermarks, windows,
channels, replay) and hands Tamoz the snapshot. **Tamoz computes no watermark,
no event time, no lateness, and no window membership** — the deterministic
plane is the stream's. The old engine's channel vocabulary, backpressure
declarations, connector contract, and replay runtime were deleted with it by
forward migration (MIGRATION_13); nothing reads the old `queue_capacity` /
`spool_capacity_bytes` / `overflow` vocabulary because the vocabulary is gone.

### Real physical actuation

The supervised worker proposes typed Decisions (intents); it holds no effector
at all. Actuation belongs to the stream: the stream executes the accepted
intent against its own effector surface (in the joint system, the simulator),
and Tamoz's only bridge to it is the approval relay (R2 answers) and the
reconsideration judgment (compensations). **No actuator adapter exists on the
Tamoz side**, and none can be reached from the episode path — the containment
host is read-only and the artifact/verification stores hold no effectful
reference.

## Deliberate non-goals

These are not gaps to be filled later; they are decisions.

- **No plugin API and no marketplace** (ADR-014). The capability registry is a
  closed set of four built-in sources — local tools, skills, MCP servers,
  websearch — sealed at session construction. A caller-supplied source is
  refused at construction, not at dispatch.
- **No arbitrary shell.** `run_check` runs one operator-configured argv by
  name. The model chooses *which* configured check to run and can never alter
  its arguments, its program, or its environment.
- **No second UI.** One CLI (`tamoz`), one reference application.
- **Content never grants authority.** A skill body, an MCP tool description, a
  catalog annotation, a memory record or model output can request capabilities;
  none can grant one, and none can lower a risk classification.

## Boundaries you should plan around

- **Effects are at-least-once unless proven otherwise** (ADR-016). A
  reconcilable effect (a patch, a file creation) converges from its proven
  before/after state. An unsafe effect whose outcome is unknown STOPS as
  `:unknown` and waits for a human `tamoz resolve` — it is never retried
  blindly.
- **Crash equivalence is defined at committed barriers.** Work after the last
  barrier may be re-executed; invariant 21 governs whether that replay is safe.
- **A workspace crash can leave a private `.tamoz-*.tmp` staging file.** The
  next action-capable session sweeps files older than 60 seconds; the delay
  exists so a concurrently publishing session is never disturbed.
- **Tamoz does not survive loss of the SQLite file without a backup.** Byzantine
  storage adapters and remote effects that are both non-idempotent and
  impossible to reconcile are outside the fault model.
- **Only two budgets are enforced.** `model_calls` and `wall_clock_seconds` are
  enforced by the worker from durable evidence — the effect journal counts every
  `model.generate.*` dispatch, and the occurrence record carries its own start
  time — and exhaustion is a typed, durable, terminal stop the agent cannot
  reach or widen. `cost_usd`, `input_tokens`, `output_tokens` and `steps` are
  still RECORDED AND PINNED ONLY. There is no spend cap in currency or tokens,
  because nothing in the model path reports usage back to the runtime yet.

## Release readiness

**Tamoz v0.1 is not released.** The release audit
([`../docs/REQUIREMENTS_AUDIT.md`](../docs/REQUIREMENTS_AUDIT.md)) measures every requirement by
running its named test, and it still reports release-blocking gaps — the two
unimplemented clauses above, and the release-evidence objective itself, which
needs the remaining documentation and an owner decision.

A passing clean-clone rehearsal ([`../docs/RELEASE_REHEARSAL.md`](../docs/RELEASE_REHEARSAL.md))
proves the candidate is independently reproducible. It does not make it
released, and no stable-release claim should be read into it.

## Evidence status

Some parts of the system carry weaker evidence than others, and the difference
is recorded rather than smoothed over:

- P6 (durable session/effect recovery), P7 (interactive CLI) and D-7 (tool-error
  recovery) have never had an independent adversarial review. They rest on the
  deterministic gate and the builder's own self-review.
- The most recent defect rounds (28 and 29) found and fixed their own defects
  with no independent exam.
- Three classes of defect in this project's history were found by running the
  product against a real model, never by the test corpus: a tool-error surfacing
  gap, an action-mode failure, and a forged corruption error on any non-ASCII
  model reply. Green tests here are necessary and have repeatedly proven
  insufficient.

[`../docs/GAUNTLET_PROGRESS.md`](../docs/GAUNTLET_PROGRESS.md) (repository-internal archive) §5 carries the full open-gap list.

## Next reads

- [`../docs/requirements-audit.json`](../docs/requirements-audit.json) — the measured audit this page is bound to.
- [`guides/evaluation.md`](guides/evaluation.md) — how the gates work.
- [`getting-started/install.md`](getting-started/install.md) — what does work.
