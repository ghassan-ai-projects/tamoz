# What Tamoz v0.1 does not do

This page is the honest counterpart to the README. Every entry is something a
reader could reasonably assume works, and does not. It is bound to the release
audit by `test/documentation_surface_test.rb`: the release-blocking gaps listed
here must be exactly the gaps
[`docs/requirements-audit.json`](requirements-audit.json) measures, so this page
cannot quietly fall behind the product.

Read it before deciding whether Tamoz fits your problem.

## Not implemented

### Operator visibility is partial

`tamoz status --json` reports pending work, paused approvals, blocked (`:unknown`)
effects, budget exhaustions, capability sources, the dispatchable capability
catalog, memory configuration, and evidence-derived safety counters. Schedule
occurrences are on `tamoz schedule occurrences`.

**Not reported:** recent completions, and circuit state. Neither has a
cross-cutting query today — the circuit store is per scope and scope id with no
enumeration, and terminal requests leave the pending view by design. Both need a
new read-only storage query and a boundary-registry entry.

### Streaming input is not reachable from the worker, and its bounds are not enforced

All four capability sources — skills, memory, MCP and websearch — are now
operator-configurable and reach the worker. **Streams are not.** No
operator-facing configuration constructs a channel, so an autonomous run cannot
consume a continuous input at all, and the backpressure declaration below is
still unenforced.

### Cron and civil-time scheduling (invariant 39)

`tamoz-scheduler` ships `at` (one-shot at a UTC instant) and `interval` (every
N seconds). **Cron expressions and IANA timezones are not implemented.** There
is no DST handling, no `America/New_York`, no `0 9 * * MON`. The misfire,
overlap, backlog, jitter and catch-up policies the invariant also requires ARE
implemented and tested; the civil-time half is absent, so the clause cannot be
claimed as a whole.

If you need "every weekday at 09:00 local time", Tamoz cannot express it.

### Channel backpressure enforcement (invariant 48)

`Tamoz::Stream::ChannelDescriptor` accepts, validates and digests
`queue_capacity`, `spool_capacity_bytes` and `overflow`
(`block`/`retry`/`spill_then_reject`/`sample`/`coalesce`/`reject`). **Nothing
reads them.** The declaration is recorded in the channel's content-addressed
identity and never enforced at runtime.

What IS implemented and tested: durable admission, idempotent dedup, quarantine
on identity reuse with a differing payload hash, typed rejection records, and
acknowledgement only after durable admission. What is not: any bound on queue
or spool growth, and any of the six overflow behaviours. `OVERFLOW_POLICIES` is
deliberately excluded from the documented public API for this reason — an
unenforced policy vocabulary is not an API.

If you feed a faster producer than your storage can absorb, Tamoz will not
apply the policy you declared.

### Skill installation and update (invariant 43)

Skills are compiled from operator-configured directories into immutable,
content-addressed snapshots, and their content grants no authority. **There is
no install, update, or self-improvement pipeline**: no quarantine staging, no
provenance checks on a downloaded artifact, no atomic activation of a new
digest. You place skill trees on disk yourself, out of band.

### Real physical actuation (invariants 50, 51)

The only effector is the simulator. Typed intent, current-state policy,
approval, interlock checks, TOCTOU closure and command journalling are all
implemented and exercised against it, and replay/shadow scopes provably hold no
effector credentials. **No real actuator adapter exists**, and connecting one
requires an explicit owner decision and a separate safety review.

### Channel communications (invariants 56–58, ADR-041–043)

The channel contract gem (`tamoz-comms`) exists with the exact decision
machinery the worker consumes and the channel values and seams — the surface
descriptor, normalized inbound envelopes, deliveries, bindings, approval
prompts, the closed command table, and the `Transport`/`DeliverySink`/`CommsStore`
contracts. **The Telegram channel itself does not exist yet**: there is no
surface admission, no durable outbox, no transport adapter, and no gateway
process. The channel clauses 56–58 and ADR-041–043 are accepted as owner
policy and recorded as pending-owner-residual gaps; the slices of
[`COMMS_TELEGRAM_PLAN.md`](COMMS_TELEGRAM_PLAN.md) convert each to direct
evidence in order.

Until then: the only surface is the operator CLI, and there is no way for a
message from Telegram (or any other channel) to reach a runtime, and no way for
agent output to reach a human outside the terminal.

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
([`REQUIREMENTS_AUDIT.md`](REQUIREMENTS_AUDIT.md)) measures every requirement by
running its named test, and it still reports release-blocking gaps — the two
unimplemented clauses above, and the release-evidence objective itself, which
needs the remaining documentation and an owner decision.

A passing clean-clone rehearsal ([`RELEASE_REHEARSAL.md`](RELEASE_REHEARSAL.md))
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

`docs/GAUNTLET_PROGRESS.md` §5 carries the full open-gap list.
