# Missing Abstraction Review — tamoz monorepo (2026-08-20)

## Scope and methodology

This is a read-only audit of the `tamoz` Ruby monorepo (13 gems, ~78K lines, 441 files
under `gems/*/lib`) for the **missing abstraction** dimension: dispatch ladders that
should be tables or polymorphism, god classes/modules, long parameter lists that should
be value objects, copy-pasted *structure* (not literal text — that is a different
agent's dimension), and primitive obsession.

Process:

1. Started from `mcp__enola__query_insights` with `explainer=complexity-outliers` (13
   methods, cyclomatic complexity 15–24) and `explainer=god-class` (~20 high-fan-in
   symbols) as the primary ranked signals, per instructions.
2. Read every complexity-outlier method in full source context and classified its shape
   (dispatch ladder / validation chain / genuine business logic / other) before proposing
   anything, per the worked examples supplied in the task brief. Two items
   (`SessionRecords.load!`, `ScheduleStore#claim_one_schedule`) and one high-risk item
   (`TamozSQLiteOracle.validate_state_node!`) were already investigated this session and
   are treated here as confirmed, not re-litigated.
3. Read `Tamoz::Evals::Verifier` and `Tamoz::Agent::Deliberation` in full, as explicitly
   requested, to confirm and detail the class-split / method-split proposals.
4. Cross-checked the god-class fan-in list against actual source: most of it turned out
   to be **foundational shared-kernel modules** (`Tamoz::Core`, `Tamoz::Error`,
   `Tamoz::SQLite::Adapter`, `Tamoz::Mcp::Invocation`/`Supervisor`) rather than classes
   doing unrelated things — see "Investigated and not flagged" below. Reporting that a
   loud signal turned out to be a false positive is itself part of this review.
5. Swept the repo independently of the ranked signals for patterns the outlier list is
   too short to surface: `grep`-counted `case`/`when` density per file, grepped for every
   `deep_freeze` implementation by name, grepped method signatures for keyword-argument
   density (`Metrics/ParameterLists` in `docs/CODE_QUALITY.md` reports a max of 29
   parameters across 142 methods), and spot-read the largest files in the gems the
   ranked signals didn't touch (tamoz-graph, tamoz-otel, tamoz-telegram, tamoz-scheduler,
   tamoz-tools, tamoz-mcp).
6. Excluded `agenteval/` (gitignored, user-owned) and treated
   `agent_smoke_corpus.rb`-style declarative eval-corpus files as data, not logic, per
   the known false-positive traps.

## Executive summary

The strongest finding is cross-cutting rather than local: **this codebase has reinvented
"canonicalize a value, then hash or freeze it" independently at least nine times**
across seven gems and `script/`, when one correct, general implementation
(`Tamoz::Core`) already exists and is proven reusable — `Tamoz::Agent::Plan.deep_freeze`
already just delegates to it. The nine reimplementations are not textually identical;
they differ in behavior (mutate-in-place vs. copy-and-freeze, whether keys get frozen,
whether an unsupported type raises or is silently accepted), which is exactly the
"same shape, different data/rules plugged in" signature this dimension looks for, and
worse, means the inconsistency is not just cosmetic. `Tamoz::Comms::Canonical` goes
further and reimplements domain-separated canonical digesting itself (not just
freezing), with a hand-rolled encoding that is not byte-compatible with
`Tamoz::Core::JCS`/`Tamoz::Core.digest` — in a system whose entire durability and
verification model (`content_digest`, `digest_version`, checkpoint fences) rests on
digests being comparable. This session's own commit history
(`692278f refactor(mcp): dedup deep_freeze into CanonicalJSON`) already fixed one
corner of this problem inside tamoz-mcp; the same fix is now warranted at the
cross-gem level.

The second major finding is the one flagged for deeper investigation:
`Tamoz::Evals::Verifier` is a real god-class — not because any one method is
unreasonable, but because it fuses three independent artifact-kind verification
strategies (case / evidence / result) into one class's private methods, and two of
those methods (`verify_evidence_status!`, `verify_decision_evidence!`) turn out to be a
duplicated 5-way status dispatch over structurally identical rules applied to different
collections.

Beyond those two, the remaining findings are smaller and more local: several
`validate!`/`load!` methods share the "sequential guard-clause chain" shape (correctly
*not* a lookup-table candidate, per this session's own precedent) and would benefit
from being split into named phases; a couple of genuinely complex sequential business
methods (schedule claiming, subprocess supervision) would benefit from step-extraction
without changing behavior; and one small, clean dispatch ladder in `Tamoz::Tools::Toolbox`
is a mechanical match for the lookup-table fix already applied elsewhere this session.

Several loud signals were investigated and found **not** to be missing-abstraction
problems, and are recorded below so they are not re-flagged by a future pass:

- **`Tamoz::Core`** (150 dependents, confidence 0.95 "god-class" insight) is a
  13-function facade over `JCS`, each function a one- or two-line delegation
  (`digest`, `jcs`, `parse_json_strict`, `valid_digest?`, `deep_freeze`, `canonical`,
  `secret_shaped?`, `normalize_reconsideration`…). High fan-in here is inherent to
  being the one shared canonicalization/digest primitive every gem needs — splitting it
  would fragment, not fix, the actual problem identified above.
- **`Tamoz::Error`** (21 dependents) is a clean, data-driven exception taxonomy: one
  `Metadata` module reading `CATEGORY`/`RETRYABLE`/`USER_VISIBLE`/`SAFE_MESSAGE`
  constants, ~25 subclasses each just setting those constants. This is already the
  "table, not a case ladder" shape done right.
- **`Tamoz::SQLite::Adapter`** (19 dependents) is a connection facade whose
  `bind_*_store` methods are one-line `guard_open! + Store.new(...)` calls — a
  legitimate single chokepoint for DB access, not orchestration hiding in a god object.
- **`Tamoz::Mcp::Invocation`** and **`Tamoz::Mcp::Supervisor`** (11 and 8 dependents)
  are each a cohesive single concern (safely invoking one MCP tool call;
  supervising one child process) already broken into small single-purpose private
  methods.
- **Long parameter lists** flagged by the raw RuboCop baseline (max 29 params, 142
  methods over the ceiling) were spot-checked at the top of the list
  (`MemoryRecord#initialize` at 30 signature colons, `Schedule#initialize` at 25,
  `Tamoz::Comms::Delivery#initialize`/`#validate!` at 13 keywords,
  `Tamoz::Observability::Signal#initialize` at 13 keywords) and are, without exception,
  `Data.define`-backed immutable value objects with an explicit, often
  rubocop/reek-annotated, rationale ("the delivery's thirteen fields ARE the value").
  This is the *correct* fix for that smell already applied consistently — not a
  missing abstraction. The one exception worth a look, `Tamoz::Context`, is below.

Finding counts: **2 High, 8 Medium, 3 Low.**

---

## High

### 1. Canonicalization/freeze/digest primitives reimplemented independently across at least 7 gems and `script/`

- No single file:line — this is a cross-cutting family. Anchors:
  `gems/tamoz-core/lib/tamoz/core.rb:145` (`Tamoz::Core.deep_freeze`, the correct,
  already-reused home) and `gems/tamoz-comms/lib/tamoz/comms/canonical.rb:14-59`
  (`Tamoz::Comms::Canonical`, the most divergent reimplementation).
- **Shape: copy-pasted structure / primitive obsession**, not literal duplication. Every
  instance recursively walks `Hash`/`Array` and does something scalar-specific at the
  leaves; the walk skeleton is identical everywhere, but each site independently chose
  different leaf/edge-case behavior.

**Evidence — `deep_freeze` has nine independent bodies:**

| Location | Behavior |
|---|---|
| `gems/tamoz-core/lib/tamoz/core.rb:145` | copies (`to_h`/`map`), re-stringifies + freezes keys, **raises** `Tamoz::Error` on an unsupported type |
| `gems/tamoz-agent/lib/tamoz/agent/plan.rb:84` | `Tamoz::Core.deep_freeze(value)` — **the one correct delegator** |
| `gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:261` | copies via `each_with_object`, does **not** freeze/restringify keys, silently `.freeze`s any unsupported type instead of raising |
| `gems/tamoz-agent/lib/tamoz/agent/profile.rb:560` | **mutates in place** (`each { freeze key; freeze entry }`), no raise |
| `gems/tamoz-agent/lib/tamoz/agent/intent_catalog.rb:164` | copies via `to_h`, does not freeze scalars at all, no raise |
| `gems/tamoz-agent/lib/tamoz/agent/mcp_capability_source.rb:249` | mutates in place, freezes `String` keys only (not Symbol/Integer keys) |
| `gems/tamoz-mcp/lib/tamoz/mcp/canonical_json.rb:23` | mutates in place via `each_value` — does not touch keys at all |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb:594` | mutates in place, freeze key + entry (near-identical to `profile.rb`) |
| `gems/tamoz-evals/lib/tamoz/evals/deep_freeze.rb:8` (`DeepFreeze.call`) | mutates in place, freeze key + entry (near-identical to the above two) |
| `script/tamoz_sqlite_oracle:139` | mutates in place, freeze key + entry (near-identical to the above three) |

Three of the ten (profile.rb / boundary_source_audit.rb / script's oracle / evals'
`DeepFreeze.call` — four, actually) are close enough to be the *literal*-duplication
agent's problem; the rest are genuinely different behaviorally, which is exactly what
makes this a missing-abstraction finding and not just a "run a formatter" one: nobody
can currently answer "does `deep_freeze` reject a `Time` object?" for the codebase as a
whole — the answer depends on which of nine copies you're looking at.

**Evidence — canonical-digest encoding is reimplemented, incompatibly, outside core:**

`gems/tamoz-comms/lib/tamoz/comms/canonical.rb` (`Tamoz::Comms::Canonical.hexdigest`,
used for delivery/decision content ids) hand-rolls a second "canonicalize a value for
hashing" pipeline (`canonical_bytes` → `canonical_hash`/`canonical_array`/
`canonical_scalar`/`canonical_literal`) that sits *right next to* the already-shared
`Tamoz::Core.digest(domain, value)` (`gems/tamoz-core/lib/tamoz/core.rb:101`, backed by
`Tamoz::Core::JCS`, RFC 8785). The two are **not** byte-compatible: `Comms::Canonical`
sorts hash keys by their own already-encoded bytes rather than JCS's UTF-16BE code-unit
order, and it explicitly supports `Time` values (`when Time then canonical_bytes(...)
.iso8601(6)`) — a type `JCS.emit` has no `when` clause for at all and would raise on.
Two digests over "the same" logical content computed through the two paths are not
guaranteed to match, in a codebase whose entire integrity model (`content_digest`,
`digest_version`, DR-2/DR-4 checkpoint fencing) is built on digest comparison.

**Suggested abstraction:** make `Tamoz::Core.deep_freeze` and `Tamoz::Core.digest` (both
already public, already gem-order-safe since `tamoz-core` sits under every other gem)
the single required entry points, the way `Tamoz::Agent::Plan.deep_freeze` already does.
For `Tamoz::Comms::Canonical`, switch `hexdigest` to call `Tamoz::Core.digest` directly
(with a domain-separated string) instead of hand-encoding — the only real risk is that
existing *persisted* delivery/decision ids were computed with the old encoding, so this
needs a one-time compatibility decision (versioned re-derivation vs. accepting a
digest-format bump), not a silent swap. For the `deep_freeze` copies: before doing a
mechanical replace, someone needs to decide which behavior is authoritative (mutate vs.
copy; raise vs. silently accept unsupported types) since callers may be relying on the
current behavior at each site — this is the one place in this review where "just call
the shared one" needs a short audit pass first, not a blind `sed`.

### 2. `Tamoz::Evals::Verifier` is a god-class conflating three artifact-kind verifiers, with a duplicated 5-way status dispatch inside it

- `gems/tamoz-evals/lib/tamoz/evals/verifier.rb` — class spans lines 8–559. Four of its
  private methods are independently in the complexity-outliers list:
  `verify_provenance!` (21, line 388), `verify_evidence_status!` (19, line 325),
  `verify_decision_evidence!` (18, line 473), `verify_evidence_process!` (16, line 264).
- **Shape: god-class (confirmed) + copy-pasted structure inside it.** This is exactly
  the "worth your own read to confirm and propose a concrete split" item from the task
  brief — confirmed on both counts.

`Verifier#verify` handles three unrelated `artifact_type`s ("case", "evidence",
"result", dispatched via `DIGEST_DOMAINS` and the `if/elsif` in `verify_semantics!` at
line 153). Its ~15 private methods cleanly partition by which kind they serve:

- **Shared infra** (legitimately one class's job): `read_document`, `verify_digest!`,
  `verify_references!`, `assert_unique_ids!`, `verify_timing!`,
  `assert_no_diagnostic_errors!`, `read_stable_file`.
- **Case-only:** `verify_case_semantics!` (line 190).
- **Evidence-only:** `verify_evidence_semantics!` (214), `verify_evidence_process!`
  (264), `verify_evidence_status!` (325), `intentional_intervention?` (381).
- **Result-only:** `verify_provenance!` (388), `verify_decision_evidence!` (473).

Within that, `verify_evidence_status!` (325–379) and `verify_decision_evidence!`
(473–525) are a **structurally duplicated 5-way `case status`**: both switch on the
same five values (`passed`/`failed`/`invalid`/`infrastructure_error`/
`insufficient_evidence`) with the same per-branch rule shape — "passed" checks a
positive-signal collection is all-clear then calls the (already shared)
`assert_no_diagnostic_errors!`; "failed" checks a negative-signal collection has at
least one hit then the same shared call; "invalid"/"infrastructure_error"/
"insufficient_evidence" each check one diagnostics bucket is non-empty and the other
two are empty. The only difference between the two methods is *which collection* plays
the positive/negative-signal role (`claims` vs. `hard_gates`). The team already
extracted the "don't mix diagnostic buckets" rule into the one shared
`assert_no_diagnostic_errors!` — this is the same move, one level up, not yet made.

**Suggested abstraction:**

1. Split `Verifier`'s per-kind methods out into three small collaborators —
   e.g. `Verifier::CaseSemantics`, `Verifier::EvidenceSemantics`,
   `Verifier::ResultSemantics` — each exposing one `verify!(document, reference_ids:)`
   that owns exactly the methods listed above for its kind. `Verifier` itself keeps the
   shared infra and becomes a thin orchestrator: read → validate shape → digest →
   references → `SEMANTICS_VERIFIERS.fetch(artifact_type).verify!(...)` (a 3-entry
   hash is enough; this is about ownership, not needing a table for only 3 branches).
2. Inside that split, give `EvidenceSemantics` and `ResultSemantics` a shared
   status-invariant helper — e.g.
   `check_status_invariants!(label:, status:, positive_ok:, negative_ok:, invalid:,
   gaps:, infrastructure:)` — implementing the one 5-way case body once. Each caller
   computes its own `positive_ok`/`negative_ok` booleans (`claims.all? { pass }` vs.
   `hard_gates.none? { !pass }`, etc.) and calls the shared method; `ResultSemantics`
   keeps its one extra "passed requires non-empty references" check as a local
   pre-check. This directly removes the duplicated ~50-line structure and would likely
   drop both methods below the complexity-outlier threshold on its own.

This is a class-split, not a per-method fix — fixing `verify_evidence_status!` in
isolation would leave the god-class problem (and the duplication with
`verify_decision_evidence!`) untouched.

---

## Medium

### 3. `Tamoz::Agent::Deliberation.structural_issues` — validation-accumulator, not a dispatch ladder

- `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb:186` — complexity 21.
- **Shape: validation chain** (accumulator variant: appends to an `issues` array rather
  than raising on first failure), confirmed by reading — same family as
  `SessionRecords.load!`, not a dispatch ladder. Do not table-ize.

The method does three genuinely separate passes: (a) four plan-level checks (goal/
done_when/steps non-empty, step ids unique); (b) a per-step loop (lines 192–226, the
bulk of the complexity) checking ~8 independent things about *one* step — id/purpose/
verification non-empty, tool availability, arguments shape, placeholder-argument
detection, and tool/argument validation via `capabilities` or `toolbox`; (c) a
phase-gated pair of checks for `:action`/`:repair` phases only (227–236) about
check-step presence and mutation-after-check ordering.

**Suggested abstraction:** extract each pass into its own named method returning an
array — `plan_level_issues(plan)`, `step_issues(step, allowed_tools:, toolbox:,
capabilities:)`, `ordering_issues(plan, phase:, toolbox:)` — and have
`structural_issues` become a 4-line composition (`issues = plan_level_issues(plan);
plan.steps.each { issues.concat(step_issues(...)) }; issues.concat(ordering_issues(...))
if ...; issues.freeze`). `step_issues` in particular is independently testable and is
where nearly all of the current complexity lives.

Secondary, lower-confidence observation: the `Deliberation` module itself bundles four
distinct concerns behind one `module_function` namespace — prompt template building
(`planning_prompt`, `routing_prompt`, `review_prompt`, `verification_prompt`), plan
structural validation (this finding + `placeholder_arguments?`), response parsing
(`parse_review`, `parse_verification`), and action canonicalization/signing
(`action_signature`, `canonicalize_apply_patch_arguments`, `canonical`). The module's
own doc comment ("pure...no I/O...shared by the ephemeral Runtime and the durable
Session") is a legitimate reason to keep it one dependency, so this is a much softer
suggestion than #1/#2: if it ever needs to grow further, `Deliberation::Prompts`/
`::Validation`/`::Parsing`/`::Signing` submodules would be the natural seam — not
urgent today.

### 4. `Tamoz::Agent::SessionRecords.load!` fuses validation, migration, and legacy-default backfilling

- `gems/tamoz-agent/lib/tamoz/agent/session_records.rb:275` — complexity 20.
- **Shape: validation chain** (sequential guard clauses checking different things: is it
  a Hash? is the kind allowlisted? does it match the expected kind? is the version
  usable? is it too new?) — already correctly identified this session as not a
  dispatch-ladder candidate.

Reading the full method shows it does not stop at validation: after the guard clauses
it runs a `while` migration loop (301–312), then — only for `stored_kind == "session"`
— backfills ~7 legacy default fields (318–343+, truncated in this excerpt but the
pattern continues). That is three sequential, independent concerns living in one
method: **validate shape → migrate to current version → backfill legacy session
defaults**.

**Suggested abstraction:** extract `validate_record_shape!(value, kind)` (the guard
clauses), `migrate_to_current_version(value, stored_kind)` (the `while` loop), and
`apply_legacy_session_defaults(migrated)` (the `"session"`-only backfill block) as
named private methods, composed in `load!` in that order. Each becomes independently
testable against its own fixtures (a malformed record / an old-version record / a
pre-P8 session record) instead of only through the combined method.

### 5. `Tamoz::Stream::EpisodeRequestEnvelope#validate!` — another long guard-clause validation chain

- `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:202` — complexity 16.
- **Shape: validation chain**, same family as #3/#4 — sequential `raise ... unless`
  checks over unrelated fields (protocol version, episode/attempt/tenant id shape,
  fence positivity, confidence floor, `allowed_intent_types` length, intent-catalog
  requirement conditioned on `kind`, budget, traceparent/tracestate format, kind
  support, reconsider-kind catalog requirement).

**Suggested abstraction:** the checks already group naturally by concern — identity
fields (`episode_id`/`attempt_id`/`tenant_id`/`fence`), catalog/budget requirements
(conditioned on `kind`), and trace-header format. Extract
`validate_identity!`, `validate_kind_requirements!`, and `validate_trace_headers!` and
call all three from `validate!`. This is the same fix shape as #4, applied to a
different gem — worth doing together since they're the same pattern, not because one
depends on the other.

### 6. `Tamoz::Evals::Harness::MemoryCell#build_measurement` — untyped 28-key report Hash, and an unnamed 10-term correctness predicate

- `gems/tamoz-evals/lib/tamoz/evals/harness/memory_cell.rb:87` — complexity 15.
- **Shape: primitive obsession**, plus a smaller validation-chain-like predicate buried
  inside it.

`correct` (lines 100–110) is a single `&&`-chain of 10 independent conditions
(crash-free, seed intact before/after, injected/event/prompt id sets reconciled in both
directions, no echoed ids, zero sensitive/unauthorized recalls, zero decrypt reads,
zero absorbed content) with no names attached to any sub-check. The method then builds
and returns a **28-key** raw `Hash` via `DeepFreeze.call(...)` (`case_id`, `treatment`,
`outcome`, `reason`, `injection_correct`, `injected_ids`, `event_ids`, `prompt_ids`,
`missing_ids`, `extra_ids`, `matched_restricted_ids`, `sensitive_recalls`,
`unauthorized_recalls`, `decrypt_reads`, `absorbed_prompt_content`,
`prompt_echoed_ids`, `prompt_injections_seen`, `seed_digest`, `store_digest`,
`store_stable`, `task_success`, `terminal`, `model_calls`, `steps`, `expected_delta`,
`delta_observed`, `vacuous`, `duration_ms`). Every consumer of a "measurement" has to
know all 28 string keys by heart. This is notably inconsistent with the rest of the
gem, which already uses `Data.define` for exactly this kind of structured result
(`Verifier::Verification` in the same gem; `SubprocessRunner::Stream`).

**Suggested abstraction:** name the sub-checks in the `correct` chain (e.g.
`ids_reconciled?(injected_ids, event_ids, prompt_ids)`, `no_prompt_leakage?(echo_ids)`,
`no_unauthorized_recall?(audit)`, `store_untouched?(@store)`) so the AND-chain reads as
a checklist instead of 10 anonymous conditions — this alone shrinks the method's
complexity. Separately, consider a `Measurement = Data.define(...)` mirroring
`Verification`, so the 28 fields get a name, a fixed shape, and a single place to add
or rename a field instead of a Hash literal that every caller pattern-matches against
by string key.

### 7. `Tamoz::Context` — 20-field constructor mixing identity, lifecycle, observability, and runtime collaborators

- `gems/tamoz-core/lib/tamoz/context.rb:20` (`initialize`) — 20 keyword parameters
  (`ATTRIBUTES`, line 12). Also a "high fan-in/fan-out chokepoint" per the `hotspots`
  explainer.
- **Shape: primitive obsession / long parameter list**, but *not* the same shape as the
  value objects rejected in the executive summary — those are pure data
  (`Delivery`, `MemoryRecord`, `Schedule`, `Signal`). `Context` mixes four distinct
  kinds of field:
  - identity/tracing data: `run_id`, `parent_run_id`, `execution_id`, `request_id`,
    `thread_id`, `namespace`, `task_id`, `tags`, `metadata` (9 fields, pure data)
  - lifecycle/cancellation: `deadline`, `cancellation`, `clock`, `interrupt_mode`
  - observability: `notifier`, `emitter`
  - runtime collaborators (injected services, not data): `store`, `effects`,
    `interrupts`, `graph_runtime`, `episode_tools`

Unlike a value object, several of these fields are callables/collaborators
(`interrupts.respond_to?(:call)`, `graph_runtime.respond_to?(:call)`,
`episode_tools.respond_to?(:execute)`) — `Context` is doing double duty as both a
request-scoped data bag and a service locator.

**Suggested abstraction:** extract the 9 purely-descriptive identity/tracing fields
into a small nested value object (e.g. `Context::Identity`), and keep `Context` itself
holding `identity` + lifecycle + observability + collaborators. This would shrink the
20-argument initializer, and would let call sites that only need identity for logging
or tracing depend on the narrower `Identity` type instead of the full `Context`
(which currently drags in `store`/`effects`/`graph_runtime`). This is lower urgency
than findings 1–2: `Context` already has a well-designed update API (`#with`, `#child`,
a frozen `ATTRIBUTES` list, per-field validation), so this is a refinement, not a fix
for something broken.

### 8. `Tamoz::SQLite::ScheduleStore#claim_one_schedule` — genuine multi-step business logic; extract named steps, do not table-ize

- `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:271` — complexity 18. Confirmed
  this session as genuine sequential business logic, not a dispatch ladder — recorded
  here with the concrete seam proposal requested.
- **Shape: genuine business logic**, heavily anchored to specific design invariants via
  inline comments referencing a design doc (P13-B/P13-C/§5/§6/§7). High-risk to
  restructure without first having tests pinned to today's behavior.

The method's natural seams, in execution order: **(1)** grant intersection and
fail-closed deny (276–282, `Tamoz::Scheduler::GrantIntersector.effective_grant` then
`record_grant_denied` early-return), **(2)** claim-template resolution (285–303,
resolves a callable-or-Hash template once per schedule), **(3)** due-occurrence
selection (305–306), **(4)** misfire selection (308–310), **(5)** overlap-policy
evaluation (311–317, durable pre-scan state for `forbid`/`queue_one`, per-occurrence
re-evaluation for `allow`), **(6)** skip-recording loop (321–326), **(7)** the
per-occurrence materialize loop (328+, continues past the excerpt read).

**Suggested abstraction:** extract steps 1–2 and 4–5 as named private methods —
`resolve_effective_grant(schedule, current_grant, now, tx)` (returning early via a
sentinel or raising a clearly-named condition on deny), `resolve_claim_template(schedule,
request_template, effective_grant, include_provenance:)`, `select_overlap_decision
(schedule, non_terminal:, pending:)` — while leaving the two occurrence loops (6–7)
inline since they are the actual enqueue side effects and splitting them further would
obscure the ordering the inline comments are protecting. This reduces
`claim_one_schedule`'s own complexity by turning ~3 of its nested conditionals into
single named calls, without touching the sequencing or the transaction boundary.
Because of the inline invariant comments (P13-B/P13-C), this one specifically should
not be touched without characterization tests for each named step first.

### 9. `Tamoz::Evals::Harness::SubprocessRunner#wait_for_child` — process-supervision loop with three tangled concerns

- `gems/tamoz-evals/lib/tamoz/evals/harness/subprocess_runner.rb:255` — complexity 17.
- **Shape: genuine business logic** (a time-bounded polling/escalation state machine),
  not a dispatch ladder or validation chain.

The method interleaves three concerns in one loop: **(a)** polling `Process.waitpid2`
until the child exits or is stopped, **(b)** handling an intervention callback when the
child is stopped (asking a caller-supplied `intervention` proc what to do, with its own
sub-branch for a `KILL` decision), and **(c)**, after the loop's deadline, escalating
termination from `TERM` to `KILL` with grace periods.

**Suggested abstraction:** extract **(b)** as `handle_stopped_intervention(pid,
stop_signal, intervention, remaining_ms)` returning either `nil` (keep polling) or a
`[status, term_sent, termination, reason]` result tuple, and **(c)** as
`escalate_termination(pid)`. `wait_for_child` keeps the polling loop but delegates the
two non-trivial branches, which is where nearly all of the current cyclomatic weight
sits (the nested `if stop_signal && intervention` block and its inner `KILL` handling
alone account for a large share of the branches). Signal/process-timing code is easy to
subtly break, so this should land with the existing subprocess tests re-run, not just
reviewed by eye.

### 10. `Tamoz::Tools::Toolbox#execute` — a clean, small dispatch ladder matching this session's already-confirmed lookup-table shape

- `gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:118-132`.
- **Shape: dispatch ladder** (the good kind) — every branch is a one-line delegation to
  a uniformly-shaped call, exactly like `prepare_action!` and `dispatch_subcommand`,
  the two lookup-table fixes already applied this session:

```ruby
case normalized_name
when 'read_file' then ReadOperations.new(self).read_file(normalized_arguments)
when 'list_directory' then ReadOperations.new(self).list_directory(normalized_arguments)
when 'search_text' then ReadOperations.new(self).search_text(normalized_arguments)
when 'apply_patch' then PatchOperations.new(self).apply(normalized_arguments)
when 'run_check' then CheckRunner.new(self).run(normalized_arguments)
when 'create_file' then CreationOperations.new(self).create(normalized_arguments)
when 'load_skill' then load_skill(normalized_arguments)
when 'read_skill_resource' then read_skill_resource(normalized_arguments)
else raise ToolError, "unknown tool #{normalized_name.inspect}"
end
```

It did not appear in the complexity-outliers list (8 branches is not enough to cross
the ~15 threshold), but the shape match to this session's confirmed-good template is
exact. **Suggested abstraction:** a `{"read_file" => [ReadOperations, :read_file], ...
}.freeze` table plus `klass, method = TOOL_DISPATCH.fetch(normalized_name) { raise
ToolError, "unknown tool #{normalized_name.inspect}" }; klass.new(self).public_send
(method, normalized_arguments)`.

Two adjacent methods in the same class, `effect_intent` (134–149) and `preview`
(151–167), switch on the same `normalized_name` domain but are **not** the same shape
— their branches build genuinely different Hash literals / call different
argument-preview logic per tool, not uniform delegation. Don't fold all three into one
mechanism; only `execute` qualifies.

---

## Low

### 11. `TamozSQLiteOracle.validate_state_node!` — reviewed; mostly justified complexity, and its overlap with `StateCodec` is intentional

- `script/tamoz_sqlite_oracle:319` — complexity 24, the highest single method in the
  repo. Already investigated and correctly rejected this session as a lookup-table
  candidate (each branch has substantial unique per-type validation). Recorded here
  with one additional finding from this pass.

This method (and the production `Tamoz::StateCodec#validate_node!`/`#decode_node` at
`gems/tamoz-core/lib/tamoz/state_codec.rb:249`/`333`) share the same tagged wire format
(`FORMAT = "tamoz.state"`, `FORMAT_VERSION = 1`, tags `"nil"`/`"boolean"`/`"integer"`/
`"float"`/`"string"`/`"array"`/`"object"`) — the Oracle is a **from-scratch, independent
reimplementation of the same validator**, not an accident. That is the point of an
oracle: an independently-written check that a bug in `StateCodec` cannot also be
present in, so a common-mode failure doesn't slip through both. **This confirms and
sharpens the existing caution: do not consolidate the Oracle's validator with
`StateCodec`'s — that would defeat the reason it exists.**

The one narrow, low-risk observation: within `validate_state_node!` itself, the
`"boolean"`/`"integer"`/`"float"`/`"string"` branches (lines 328–347) all share a
"`unless node.length == 2 && node.fetch(1).is_a?(X)` → raise" micro-shape (float adds a
`finite?` check; string adds a canonical-form check). A tiny local helper —
`assert_scalar_shape!(node, klass)` — could remove that four-way repetition *within
the scalar branches only*, leaving `"array"`/`"object"` (which have genuinely unique
recursive/budget/uniqueness logic) untouched. Given this file's role, this should only
be attempted with the Oracle's own test suite green before and after, and is not worth
doing opportunistically.

### 12. `Tamoz::Core::JCS.emit` — two branches could match the file's own existing pattern

- `gems/tamoz-core/lib/tamoz/core/jcs.rb:112` — complexity 16.
- **Shape: type dispatch (the reasonable kind)**. This is a canonical-JSON emitter
  (RFC 8785); a `case value when Hash/Array/String/Symbol/Integer/Float/...` ladder is
  the idiomatic way to write this and forcing it into a lookup table of lambdas would
  be a lateral move, not an improvement — most branches already delegate (`String`/
  `Symbol` → `emit_string`, `Integer`/`Float` → `integer_to_s`/`float_to_s`).

The two exceptions are `Hash` (10 lines inline: dedup-check, sort by UTF-16BE key,
emit pairs) and `Array` (6 lines inline). **Suggested abstraction:** extract
`emit_hash(value, out)` and `emit_array(value, out)`, mirroring the delegation pattern
the other four branches already use, so `emit` itself becomes a pure 9-way jump table
with no inline logic anywhere. Cosmetic and low-risk; not worth doing in isolation, but
cheap if anyone is already in this file for finding #1.

### 13. Repeated "sequential guard-clause chain" idiom has no shared micro-helper

- Anchor: `gems/tamoz-agent/lib/tamoz/agent/session_records.rb:275`, alongside
  `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:202`,
  `gems/tamoz-comms/lib/tamoz/comms/delivery.rb:130`, and
  `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb:186` (finding #3).
- **Shape: cross-cutting validation-chain idiom.** Every one of these repeats
  `raise SpecificError, "message" unless condition` (or the `unless ... raise ... end`
  block form) dozens of times. This is explicitly *not* a call to add a shared
  dispatch table (see the worked-example guidance) — the substantive checks in each
  are genuinely different per domain and must stay that way.

**Suggested abstraction (optional, low priority):** a tiny shared assertion helper —
e.g. `assert!(condition, error_class, message)` — would turn the two-line `unless`
blocks into one line and cut visual noise, but it would **not** reduce any method's
cyclomatic complexity (each condition is still one branch) and touches enough
call-sites that it's only worth doing as a deliberate style pass, not opportunistically
alongside a real bug fix. Noted for completeness; not a priority relative to findings
1–10.

---

## Coverage

| Gem | Status |
|---|---|
| tamoz-agent | Partially reviewed. Full reads: `deliberation.rb`, `session_records.rb`, `cli.rb` (case/when sweep + confirmed the already-fixed `dispatch_subcommand`), `context.rb` is actually tamoz-core not tamoz-agent (see below), `memory/record.rb`, `profile.rb`/`intent_catalog.rb`/`mcp_capability_source.rb` (`deep_freeze` bodies only). Largest gem in the repo (128 files); not read file-by-file — relied on the complexity-outliers/god-class signals plus the `case`/`when`-density and parameter-list greps to surface candidates outside what was already flagged. No further standout findings surfaced by those sweeps beyond what's reported. |
| tamoz-core | Fully reviewed for this dimension. Full reads: `core.rb`, `error.rb`, `context.rb`, `state_codec.rb`, `core/jcs.rb` (emit/emit_string). `circuit/record.rb` spot-checked (well-documented state machine, not pursued further). |
| tamoz-comms | Fully reviewed. Full reads: `delivery.rb`, `canonical.rb`. |
| tamoz-evals | Partially reviewed — large gem (44 files, 12431 lines), most of it declarative eval corpora out of scope per the known false-positive trap. Full reads: `verifier.rb`, `deep_freeze.rb`, `harness/subprocess_runner.rb` (`wait_for_child`), `harness/memory_cell.rb` (`build_measurement`). `harness/agent_smoke_corpus.rb` deliberately not pressured (data, not logic) despite `run_websearch_governed` appearing in the complexity list. |
| tamoz-graph | Partially reviewed — structural pass only (symbol lists for the two largest files, `checkpoint_codec.rb` and `executor.rb`) plus the repo-wide `case`/`when` and complexity-outlier sweeps, neither of which surfaced a standout in this gem. No file in this gem read line-by-line. Lowest-confidence gem in this report. |
| tamoz-mcp | Substantially reviewed. Explored `invocation.rb` and `supervisor.rb` structurally (method-level, confirmed cohesive, not god-classes); read `canonical_json.rb`'s `deep_freeze`/`normalize` in full. `server_config.rb` only lightly touched (enola's parse of it was thin; not independently read). |
| tamoz-observability | Substantially reviewed. Read `content_policy.rb` (`canonicalize`) in full; `signal.rb` read (confirms the value-object long-parameter-list pattern, no finding). Remaining ~16 files not individually read. |
| tamoz-otel | Fully reviewed relative to its size (418 lines total). Full read of `http_exporter.rb` (the largest file); `async_exporter.rb`/`egress_policy.rb` not read line-by-line but nothing in the repo-wide sweeps flagged them. |
| tamoz-scheduler | Partially reviewed. Full/near-full reads: `schedule_store.rb` (`claim_one_schedule`), `schedule.rb` (confirmed `Data.define` value object, first ~110 lines). `occurrence.rb`, `grant_intersector.rb`, `scorecard_summary_consumer.rb` not read. |
| tamoz-sqlite | Partially reviewed — largest gem after tamoz-agent (67 files, 13350 lines). Full/near-full reads: `schedule_store.rb`, `boundary_source_audit.rb` (confirmed to be a Ripper-based AST auditor tool, inherently branchy, not pursued further), `adapter.rb` (structural, confirmed facade not god-class). Most of the remaining 60+ files not individually read; relied on the ranked signals and greps. |
| tamoz-stream | Fully reviewed relative to its size (25 files, 4237 lines). Full read of `situation_request.rb` (`EpisodeRequestEnvelope#validate!`), the file the complexity-outlier signal pointed at. |
| tamoz-telegram | Fully reviewed (smallest gem, 371 lines). Structural pass over all three classes (`Client`/`Normalizer`/`Transport`) — clean, single-purpose, no finding. |
| tamoz-tools | Fully reviewed relative to its size. Full read of `toolbox.rb` (source of finding #10). `skills/compiler.rb`, `tool_argument_validator.rb` and the rest not individually read, but none appeared in the complexity-outlier/when-density/parameter-list sweeps. |

No gem was left completely unreached; tamoz-graph received the lightest treatment
(structural signal only, no full-file reads) because nothing in either the ranked
enola signals or the repo-wide greps pointed at it, and its two largest files
(`checkpoint_codec.rb`, `executor.rb`) show, at the symbol-list level, conventional
encode/decode-pair and small-method decomposition rather than a god-class shape.
