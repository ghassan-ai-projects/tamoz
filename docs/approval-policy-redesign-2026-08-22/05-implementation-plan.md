# 05 — Implementation plan: `tamoz-approval` extraction

**Status:** ready for execution — rev 2 (2026-08-22): incorporates a code-verification
pass (`07-evidence-index.md`); the `approval_required?` deletion inventory in step 7 is
now the complete nine-method chain, and two omitted deletion sites are added.
**Date:** 2026-08-22
**Design source:** `03-redesign-adr.md` rev 2 (final, post-review). Section references
("ADR §2.3") point at that file; "audit §6" points at `02-current-state-audit.md`.
**Acceptance:** every step is graded against `00-acceptance-bar.md` (§6 per-step
definition of done, §4 invariants, §5 hard-zeros) and must make its mapped
`06-acceptance-scenarios.md` scenarios pass. Anchors below are the fresher readings
from `07-evidence-index.md`.
**Planning process note:** per the task contract, this plan was written without
running anything. File/line references were verified statically against the tree in
`07-evidence-index.md`; the executor re-verifies each one when the step starts by
grepping the **symbol**, not the line — line numbers drift (drifts already found are
in `07` §4).

---

## 0. Global conventions (apply to every step)

- **The bar governs.** `00-acceptance-bar.md` is the contract: §4 global invariants
  (never regress), §5 hard-zero failures (fail a step outright), §6 per-step definition
  of done, §7 quality gates. Every step below ends "not done until" it satisfies §6,
  which includes appending a one-line evidence note (date, exact gate commands,
  changed files or no-change reason, plumbing-vs-real-run split).
- **Scenarios are the acceptance tests.** Each step names the
  `06-acceptance-scenarios.md` IDs it must make pass; a step regresses none that
  previously passed.

- **Gate after every step:** `bundle exec rake ci` green, `bundle exec rubocop` clean,
  `enola check` clean. A step is not done until all three pass. `ci_full` (both
  locales) only where a step touches durability/migrations (step 5) or packaging
  (steps 1, 12), per the gate policy in `docs/QUALITY_PROGRAM_STATE.md`.
- **Before step 1:** pin the architecture — `enola set_baseline`. After steps that
  change structure (1, 5, 6, 7, 9): `enola generate_snapshot` + `diff_snapshot`; an
  introduced cycle or unintended coupling is fixed before the step is presented.
- **One step = one commit.** Commit message names the ADR section it implements.
- **No backwards compatibility** (owner directive): old tables, old code paths, old
  profile keys are deleted in the step that replaces them — no shims, no legacy-row
  handling, no read-time tolerances. Migration ordinals advance monotonically; no
  existing migration or checksum is edited.
- **Targeted tests while working a step:** `bundle exec ruby -Itest test/<name>_test.rb`;
  the gate run is the full `rake ci`.
- **Public API pins:** `test/public_api_test.rb`, `docs/public-api.json`, and
  `documentation/reference/public-api.md` pin the public surface. Any step that adds
  or removes a pinned symbol updates all three **in the same commit** (called out per
  step below).

---

## 1. Steps

### Step 1 — Gem scaffold: values, errors, `Answer`

**Goal.** `gems/tamoz-approval` exists, packages, and carries the immutable interface
vocabulary (ADR §1.2, §1.4). No behavior changes anywhere; nothing depends on the gem
yet.

**Files created:**
- `gems/tamoz-approval/tamoz-approval.gemspec` — via `gems/gemspec_helper.rb`
  (`TamozGemspec.build`), dependency: `tamoz-core` only, `runtime_contracts:
  ["policy/**/*.yaml"]` so the policy documents ship in the package (ADR §2.1).
- `gems/tamoz-approval/lib/tamoz/approval.rb` — requires, namespace `Tamoz::Approval`.
- `gems/tamoz-approval/lib/tamoz/approval/version.rb`
- `gems/tamoz-approval/lib/tamoz/approval/errors.rb` — `Error < Tamoz::Core::Error`;
  `InvalidPolicyError`, `ConflictingResolutionError`, `UnknownDecisionError`,
  `InvalidScopeError` (ADR §1.3).
- `gems/tamoz-approval/lib/tamoz/approval/request.rb` — `Request = Data.define(...)`
  exactly as ADR §1.2 (`tool, verb, argv, targets, effect_class, session_id`).
- `gems/tamoz-approval/lib/tamoz/approval/decision.rb` — `Decision` and `GrantOffer`
  `Data.define`s, paste-accurate from ADR §1.2.
- `gems/tamoz-approval/lib/tamoz/approval/answer.rb` — `Answer.parse(string) ->
  :approve | :deny | nil`, full vocabulary (`y/yes/a/approve`, `n/no/d/deny`) — the
  one normalizer (ADR §1.4).
- `gems/tamoz-approval/README.md`, `LICENSE` (copy the license convention from
  `gems/tamoz-comms`).

**Files modified:**
- `test/public_api_test.rb`, `docs/public-api.json`,
  `documentation/reference/public-api.md` — `Tamoz::Approval::*` public symbols in.
- `Gemfile` / root dependency wiring only if the repo's convention requires listing a
  new gem (mirror how `tamoz-comms` is referenced).

**Files deleted:** none.

**Tests (new):** `test/approval_values_test.rb` (Data.define immutability, field
sets), `test/approval_answer_test.rb` (both dialects' tokens parse; garbage → nil).

**Verification:** `bundle exec ruby -Itest test/approval_values_test.rb
test/approval_answer_test.rb` green; `bundle exec rake ci` green; `bundle exec
rubocop` clean; `enola check` clean (expect exactly one new module, no new edges).

**Risk.** Low. `packaging_test.rb` may pin the gem/file inventory — if so it is
updated in this commit (that is the intent, not a breakage).

---

### Step 2 — Policy data + `PolicyDocument` loader/validator

**Goal.** All policy content exists as data (ADR §2.1, §2.2): the bundled document,
three profiles, and the loader that parses, validates, digests, and runs the
document's own `simulations:` block before activation. Still nothing depends on the
gem at runtime.

**Scenarios (must pass):** O-1, E-2, SIM-1, M-2, L-2 (`06`; the loader/validator half —
the delivery half of L-2 lands in step 6). **Hard-zeros:** O-1, E-2, SIM-1, L-2, M-2.

**Files created:**
- `gems/tamoz-approval/policy/base.yaml` — `version`, `tool_tiers`, `fallback_tier`,
  `tiers`, `grant_keys`, `rules` (deny-first noted), `ask` (timeout_s/on_timeout),
  `evidence`, `simulations:` — content exactly per ADR §2.1, capturing **current**
  behavior as data (ADR §5 step 1: today's tool→gate mapping; `child_task` →
  `local_execute` with `grant_scopes: [once]`; fallback once-only).
- `gems/tamoz-approval/policy/profiles/implement.yaml` (the default, ADR §1.5),
  `policy/profiles/review.yaml`, `policy/profiles/unattended.yaml` (`on_timeout:
  deny`) — overlay shape per ADR §2.1/§2.2.
- `gems/tamoz-approval/lib/tamoz/approval/policy_document.rb` — loader/validator:
  - SHA-256 digest over the canonical form → `policy_rev` (ADR §2.1);
  - profile overlay resolution by pure path lookup
    (`<document_dir>/profiles/<name>.yaml`; bundled base pairs with bundled
    `policy/profiles/`; unknown names fail at load — ADR §2.2);
  - validation (ADR §2.1): schema; every `tool_tiers` tier declared; rules use only
    the closed matcher list (`verb`, `tool`, `target_glob`, `argv_prefix`,
    `argv_flag`) with verdict ∈ {allow, ask, deny}; `grant_scopes` of
    network/external_publish/destructive tiers, the fallback tier, and `child_task`
    must not include `session`; `evidence:` symbols ⊆ the injected symbol set
    (injected by boot wiring, ADR §1.5); the document's `simulations:` block runs and
    any failure rejects the document;
  - old profile keys `tools.approval_required` / `unattended.*` in a profile file
    fail validation loudly (ADR §2.2);
  - any failure raises `Tamoz::Approval::InvalidPolicyError` (ADR §1.3).

**Files modified:** none outside the gem (validation needs the engine's `simulate` —
if the natural factoring puts simulation execution in the Engine, this step lands the
loader against a minimal evaluator supplied here and step 3 reuses it; keep the
dependency one-directional: loader → evaluator, never evaluator → loader).

**Files deleted:** none.

**Tests (new):** `test/approval_policy_document_test.rb` — loads bundled base + each
profile; digest stable per content and changes on edit (digest pinning); every
validation rule above has a rejecting case; old profile keys rejected loudly;
`simulations:` failure rejects; unknown profile name fails at load.

**Verification:** targeted test green; full gate green.

**Risk.** **Digest re-pinning:** any later edit to `policy/*.yaml` changes
`policy_rev`. Nothing outside the gem pins the digest value itself, but tests that
assert digest stability must compare digest-vs-content, never a hardcoded hex. The
`simulations:` block is the invariant pin (ADR §7 strength 7) — do not add a Ruby
side pin of policy content (B9: domain knowledge stays data).

---

### Step 3 — `Engine`, ports, in-memory stores

**Goal.** The whole decision interface works in-process (ADR §1.1–§1.3, §2.3, §2.5):
canonicalization, evaluation, grants, resolution, simulation, reload.

**Scenarios (must pass):** the semantic core — C-1..C-8, O-1, G-1..G-6, RS-1..RS-4,
L-3, L-4, L-5, LG-1, LG-2 (`06`), all against the in-memory stores. **Hard-zeros:**
C-3, C-7, G-2, G-3, RS-1, L-5.

**Files created:**
- `gems/tamoz-approval/lib/tamoz/approval/engine.rb` —
  `initialize(policy:, grant_store:, decision_log:, clock:)`;
  - `build_request(tool:, argv:, targets:, effect_class:, session_id:)` — the one
    request-construction seam: realpath-canonicalizes targets, fills `verb` from
    `tool_tiers` (absent → `:unknown` → fallback tier) (ADR §1.1, §1.2);
  - `decide(request)` — deny rules always first regardless of document order, then
    first-match ask/allow, then tier default; grant lookup on `(key, session_id,
    session-bound policy_rev)`; **never raises for policy reasons** — gaps fail
    closed to `:ask` (or rule-said `:deny`); evaluator enforces the structural rule
    `:read_only` descriptor ⇒ tier `read` (ADR §1.2, §7 strength 1); `Decision#id`
    derived from request digest + `policy_rev` (identical pending asks dedup);
    appends one idempotent-on-`decision_id` record to the decision log;
  - `resolve(decision_id:, answer:, scope:)` — idempotent under replay (ADR §1.3):
    same answer+scope → recorded grant; different → `ConflictingResolutionError`;
    unknown/expired id → `UnknownDecisionError`; unoffered scope →
    `InvalidScopeError`; resolves against the stored decision's `grant_offer`, never
    the live policy; mints grants with the §2.3 key grammar (policy-declared fields
    per tier; every declared field present and non-degenerate or degrade to `:once`;
    `expires_at_ms` from the session deadline where one exists);
  - `simulate(request)` — same evaluation, no log append, no grants;
  - `reload(document)` — validate first, raise `InvalidPolicyError` and keep the
    previous policy live on any failure; returns the new `policy_rev`; a superseded
    document is retained only while a live session references it, then dropped
    (ADR §1.5).
- `gems/tamoz-approval/lib/tamoz/approval/grant_store.rb` — port + in-memory
  implementation (tests and the one-shot runtime; ADR §2.3).
- `gems/tamoz-approval/lib/tamoz/approval/decision_log.rb` — port + in-memory
  implementation; record shape per ADR §2.5 (structural fields cleartext — `tool`,
  `verb`, `tier`, `rule_id`, verdict, scope, evidence, `policy_rev` — argv/targets as
  digests only; append idempotent on `decision_id`, ADR §8).

**Files modified:** `lib/tamoz/approval.rb` (requires). Public-api pins updated if
the new classes are public surface.

**Files deleted:** none.

**Tests (new):** `test/approval_engine_test.rb` (decide matrix: deny-first ordering,
tier defaults, fallback ask, grant hit/miss, `read_only ⇒ read` even against
contradicting data, fail-closed on unknown tool/effect class; decision-id dedup),
`test/approval_resolve_test.rb` (every §1.3 path: replay dedup, conflict, unknown,
invalid scope, resolves against stored grant_offer across a reload),
`test/approval_reload_test.rb` (broken document rejected, previous policy live;
rev returned; superseded-document retention; parked decision unaffected),
`test/approval_grant_key_test.rb` (key grammar: `key_argv`, degenerate → `:once`,
schema-barred tiers never `:session`).

**Verification:** targeted tests green; full gate green.

**Risk.** This is the semantic heart; keep it purely in-memory — no SQLite, no comms,
no file I/O beyond the loader. The reload/retention rule (superseded documents held
for live sessions) is the only lifecycle subtlety; pin it with the reload tests
rather than adding machinery.

---

### Step 4 — Comms prep: expose the evidence symbol set (additive)

**Goal.** Comms exposes its lattice members as a plain symbol set for the boot wiring
to inject into the policy loader (ADR §1.5, §10 S6/P4/A8). Additive only — nothing
changes behavior, so this lands before any consumer exists.

**Files modified:**
- `gems/tamoz-comms/lib/tamoz/comms/authority_evidence.rb` — expose the closed member
  set (e.g. `AuthorityEvidence.members`) as plain symbols. The lattice, binding
  checks, atomic consumption, drainer activation: untouched (ADR §5 step 5).
- `gems/tamoz-comms/tamoz-comms.gemspec` — **no** approval edge yet (comms still
  imports nothing from the gem; the edge lands in step 8 where the dependency becomes
  real — see step 8 risk note).

**Files created/deleted:** none.

**Tests:** extend `test/comms_authority_evidence_test.rb` — the exposed set matches
the lattice members exactly (this is the set the loader validates against; drift here
would reject the bundled document at boot).

**Verification:** targeted test green; full gate green.

**Risk.** Trivial. The only hazard is exposing a *different* set than the lattice
enforces; the test pins the equality.

---

### Step 5 — `tamoz-sqlite`: migration 17 + store implementations

**Goal.** Durable homes for grants, decisions, and active-policy rev (ADR §2.3, §2.5,
§1.5, §5 step 2); stream receipt records gain `expires_at` (ADR §2.4).

**Scenarios (must pass):** L-5, M-4, LG-1, LG-2 (`06`; the durable-store half).
**Hard-zeros:** L-5, M-4.

**Files modified:**
- `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb` — `MIGRATION_17` +
  `MIGRATION_17_CHECKSUM` per the migrator's existing convention, `CURRENT_VERSION`
  16 → 17, `MIGRATIONS[17]` entry. New tables: `tamoz_approval_grants` (`key`,
  `scope`, `session_id`, `policy_rev`, `created_at_ms`, `expires_at_ms`),
  `tamoz_approval_decisions` (record shape per ADR §2.5, cleartext structural fields,
  digest columns for argv/targets, unique `decision_id`), single-row
  `tamoz_approval_active_policy` (`policy_path`, `policy_rev`). `expires_at` column
  added to the stream approval receipt records. **No existing migration, checksum, or
  transport table is touched** (ordinals monotonic; prompt/decision transport tables
  in use — ADR §5 step 2).
- `gems/tamoz-sqlite/tamoz-sqlite.gemspec` — dependency edge on `tamoz-approval`
  (the same edge it carries for every gem whose store contract it implements, ADR
  header/§10 A5).
- `gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb` — bind methods for the two new
  stores, mirroring `bind_approval_receipt_store` (audit §6.2 `adapter.rb:58-60`).

**Files created:**
- `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_grant_store.rb` — SQLite impl of the
  grant-store port: lookup on `(key, session_id, policy_rev)` (read-time rev match,
  ADR §2.3), insert, delete-by-`session_id` (for session teardown, step 7).
- `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_decision_log.rb` — SQLite impl of the
  decision-log port; append idempotent on `decision_id` (`INSERT OR IGNORE`-style,
  ADR §8).
- `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_active_policy.rb` — read/write of the
  single-row active-policy record (or fold into the adapter if that matches existing
  single-row conventions — check a precedent first).

**Files deleted:** none.

**Tests (new/updated):** `test/sqlite_approval_stores_test.rb` — both ports against a
real database: rev-scoped lookup (stale rev never matches), teardown delete, log
idempotence, active-policy round-trip; migration test — 16→17 applies on a fresh
database and the checksum verifies (no old rows exist to migrate — owner directive).

**Verification:** targeted tests green; `bundle exec rake ci` green; rubocop + enola
clean. **This step touches durability → run `ci_full` (both locales)** per the gate
policy.

**Risk.** **Checksum/manifest pinning** (audit §6.6): ordinals are checksummed and
manifest-pinned; follow the repo's existing checksum-generation convention exactly
and never edit migrations 1–16. If a manifest/regeneration script exists, run it and
commit its output in this step. Edge hazard: sqlite's gemspec edge must not create a
cycle — `tamoz-approval` depends only on `tamoz-core`; `enola check` confirms.

---

### Step 6 — Boot wiring + reload delivery (worker builds the engine)

**Goal.** The worker runtime constructs one `Engine` at boot and the reload-delivery
loop exists end to end (ADR §1.5) — before any call site uses the engine, so this
step is behavior-neutral.

**Scenarios (must pass):** L-1, L-2 (`06`; the reload write→poll-pickup delivery path).
**Hard-zero:** L-2.

**Files modified:**
- `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` — build the **durable** engine
  at boot: policy path from run config (default: the gem's bundled `base.yaml`),
  profile name from run/schedule (default: `implement`), inject the **SQLite** grant
  store + decision log (step 5) and comms' evidence symbol set (step 4) into the
  loader; pass it into session effects (via `configuration`, reaching
  `SessionEffects.new(configuration:)` at `session_nodes.rb:136`) as a **constructor
  dependency** (no global, no registry).
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb` — reach the engine the same
  way it reaches capabilities today (`SessionEffects.new(configuration:)` at
  `session_nodes.rb:136` reads `@configuration.capabilities` — put the engine on
  `configuration` beside it, rather than adding a new `SessionEffects` constructor
  arg, to match the existing seam). Unused by call sites until step 7.
- `gems/tamoz-agent/lib/tamoz/agent/agent.rb` (`:102`, `Runtime.new(...)`) — the
  one-shot entry builds its **own** engine with the **in-memory** grant store (ADR
  §2.3: the one-shot runtime is ephemeral, so its grants die with the process; do
  **not** hand it the worker's SQLite engine). Same bundled policy + profile + comms
  symbol set; different stores. This is a **second engine**, not a shared one — the
  two entry points (worker, `tamoz run`) are distinct processes.
- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb` — accept the engine (constructor dep;
  unused until step 9).
- `gems/tamoz-agent/lib/tamoz/agent/worker.rb` — the existing parked-thread poll pass
  gains its first new job: compare the persisted active-policy rev against the
  engine's on each pass and at session start; on difference, load from the persisted
  path and call `engine.reload` (ADR §1.5). Session start binds `policy_rev` for the
  session's lifetime.
- `gems/tamoz-agent/lib/tamoz/agent/cli_worker_commands.rb` (or wherever operator
  commands live) — `tamoz approve --reload <path>`: load + validate the document **in
  the CLI process first**; only on success write `(policy_path, policy_rev)` to
  `tamoz_approval_active_policy`. A document that fails validation never reaches the
  table (the end-to-end `visudo` property).
- `gems/tamoz-agent/tamoz-agent.gemspec` — dependency edge on `tamoz-approval`.

> **Two engines, one gem.** The durable worker and the ephemeral one-shot runtime each
> construct their own `Engine` from the same policy data — the worker's backed by
> SQLite, the one-shot's by the in-memory stores (ADR §2.3). ADR §1.5's "passed into
> the session effects and the one-shot runtime" describes the injection *shape*, not a
> single shared instance; this plan pins the two construction sites so a coding agent
> does not wire the SQLite engine into `tamoz run`.

**Files created/deleted:** none.

**Tests (new/updated):** boot-wiring test (engine built from default path + profile;
custom path honored); reload-delivery test (valid document → row written, worker
picks up on next poll pass / at session start; invalid document → row untouched,
workers keep running the old rev — assert both halves).

**Verification:** targeted tests green; full gate green; `enola diff_snapshot` shows
exactly the agent→approval edge added, nothing else.

**Risk.** **Multi-process reload rollout:** CLI and worker are separate processes;
the only channel is the database row. The test must cover the real ordering (write →
poll pickup), not an in-process shortcut. Constructor-injection ripples through
worker/session test setup — update fixtures to build a default engine (in-memory
stores) rather than mocking policy.

---

### Step 7 — Pipeline A convergence + the classification-chain deletions

**Goal.** The durable session asks the engine, and nowhere else (ADR §2.4 Pipeline A,
§5 step 3). This is the big cut-over: convergence and the deletion of everything the
engine replaces land in one commit so the tree never carries two policy owners.

**Files modified:**
- `gems/tamoz-agent/lib/tamoz/agent/session_steps.rb` — `:69` stops calling
  `effects.approval_required?(tool)`; builds the `Request` via `engine.build_request`
  on the prepared step, calls `engine.decide`. `:allow` → straight to
  `step_execute`. `:ask` → the **existing** interrupt path, unchanged, with the
  descriptor now carrying the `Decision` (id, reason, grant_offer,
  required_evidence); verdict captured in the graph node's journaled state update
  (today's `approvals` slot, ~`:108-110` — `07` §4 corrects the ADR's `:128-140`) so a
  replayed node re-reads its journaled verdict (ADR §8). `:deny` → structured tool
  result ("denied: <reason>, rule
  <rule_id>") fed back to the model; the turn continues (ADR §2.4; fixes audit §5.6).
  The repeated-action guard (`session_plan_outcomes.rb:115-127`) stays.
- `gems/tamoz-agent/lib/tamoz/agent/worker.rb` — resume path (`:398-425`) calls
  `engine.resolve(decision_id:, answer:, scope:)` for channel answers; the poll pass
  gains its second new job: pending-ask deadline checks → apply `on_timeout`
  (`park`: prompt lapses, decision stays resolvable; `deny`: resolve to structured
  denial) (ADR §2.1 timeout semantics; the answer/timeout race is decided by
  `resolve` idempotence).
- `gems/tamoz-agent/lib/tamoz/agent/cli.rb` — interactive path (`:207,277`) calls
  `engine.resolve` **in-process before `session.resume`**, with the §1.4 scope
  follow-up ("remember for this session? [y/N]") when the approved decision's
  `grant_offer` includes `:session`. `answer_for`/`map_answer` (`:467-503`) route
  through `Answer.parse`. The operator command `tamoz approve <id>` resolves a parked
  ask against its decision record (which does not expire with the channel prompt,
  ADR §2.1).
- `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb` — the `approval_required?` guard
  (`:309`, `07` §4 corrects `:307-314`) digests steps by the `Decision`'s rule/tier
  instead of the old `approval_required:` flag.
- `gems/tamoz-agent/lib/tamoz/agent/capability_binding.rb` — the three
  `approval_required?` methods in this file are deleted: the host method (`:144`), the
  routing dispatcher (`:343`, child-vs-local), and the local wrapper (`:392`,
  → `source.approval_required?`). `:203,285` keep synthesizing descriptor metadata but
  no longer answer policy questions. (`07` §1 — these were **not** in rev-1's list.)
- `gems/tamoz-agent/lib/tamoz/agent/session.rb` — session teardown deletes the
  session's grant rows (`session_id` delete on the grant store, ADR §2.3).
- `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` — `unattended_approval_required`
  union (`:864`) deleted (replaced by the `unattended` policy profile) **and its
  consumer** `narrowed_approval_required` (`:1086`, called at `:1072`); toolbox wiring
  no longer passes approval sets. (`07` §4 — rev-1 named only the `:864` definition.)
- `gems/tamoz-agent/lib/tamoz/agent/profile.rb`,
  `profile/fields.rb`, `profile/authority_validator.rb` — `tools.approval_required`
  and `unattended.*` keys and their validators deleted; profile files still carrying
  them fail validation loudly at load. `tools.allowed` stays (capability config, not
  approval policy, ADR §2.2).
- `gems/tamoz-agent/lib/tamoz/agent/cli.rb` — `--all --i-understand-approve-all`
  deleted: **both** the audit/guard block (`:472`) **and the option registration**
  (`:678`) — rev-1 named only the former (`07` §4). The profile system is its
  replacement (ADR §3 weakness 5).

**Files deleted (the complete `approval_required?` chain — `07` §1, verified):**
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb:291` — the chain entry.
- `gems/tamoz-tools/lib/tamoz/tools/local_dispatcher.rb:51` —
  `approval_required?(descriptor)` (delegates to toolbox; **added in rev 2** — pure
  delegation, dead once `capability_binding`'s wrapper is gone).
- `gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:105` — `Toolbox#approval_required?`
  (and the `@approval_required` set it reads).
- `gems/tamoz-tools/lib/tamoz/tools/tool_catalog.rb:28` — `DEFAULT_APPROVAL_REQUIRED`
  (and its re-export `toolbox.rb:40`).
- `gems/tamoz-tools/lib/tamoz/tools/tool_policy_normalizer.rb:119-133` — the
  `approval_required ⊆ allowed` validation.
- `gems/tamoz-agent/lib/tamoz/agent/child_task_dispatcher.rb:117` — the hardcoded
  `approval_required? → true` (always-ask is preserved as data: `child_task` →
  `local_execute`, `grant_scopes: [once]`, ADR §10 S1).
- `gems/tamoz-agent/lib/tamoz/agent/governed_browser_source.rb:35` and
  `gems/tamoz-agent/lib/tamoz/agent/mcp_capability_source.rb:129` — the
  `approval_required?(name) = !read_only?(name)` methods (**added in rev 2**). **Keep
  `read_only?`** in both: it computes the descriptor's effect class, which the call
  site now passes into `engine.build_request` and which enforces the `read_only ⇒ read`
  invariant (`00` INV-2, ADR §1.2). After deleting the `approval_required?` methods,
  run a dead-code check on each `read_only?`; delete only if it has lost its last
  caller (do not assume it has).
- `test/agent_capability_binding_test.rb:44` — the test pinning the deleted dispatch
  (deleted with the seam, ADR §9 item 4).

> The `capability_binding.rb` methods (`:144`, `:343`, `:392`) are removed under
> **Files modified** above; listed together they are the nine-method chain of `07` §1.
> Rev 1 of this plan named only four of the nine — the round-2 code-verification pass
> (`07`) completed the inventory.

**Public-api pins:** update `test/public_api_test.rb`, `docs/public-api.json`,
`documentation/reference/public-api.md` for every deleted pinned symbol.

**Tests (rewritten/updated):** `test/agent_decision_flow_test.rb` and
`test/agent_unattended_policy_test.rb` rewritten against the engine (repoint, don't
soften — ADR §5 step 7); interrupt/ask-path tests assert the `Decision` rides the
existing descriptor; deny-path tests assert the structured tool result and turn
continuation; unattended behavior asserted via the `unattended` policy profile
(`on_timeout: deny`); CLI scope follow-up test; poll-pass timeout-enforcement test;
teardown grant-deletion test.

**Scenarios (must pass):** C-1..C-8, O-1, G-1..G-6, RS-1..RS-4, D-1, D-2, T-1..T-3,
V-2, LG-1, LG-2, L-3, L-4, M-1, M-2 (`06`). **Hard-zeros in this step:** C-3, C-7,
G-2, G-3, G-4, RS-1, D-1, M-1, M-2.

**Verification:** targeted tests green; full gate green; rubocop + enola clean;
`enola diff_snapshot` shows the tools→agent classification coupling removed. Append the
§6 evidence note.

**Risks.**
- **Incomplete-chain deletion:** the `approval_required?` surface is nine methods
  (`07` §1), not the four rev 1 listed. Delete the whole chain in this commit, or
  `capability_binding`/`local_dispatcher` are left calling methods that no longer
  answer — grep `def approval_required?` across `gems/` and confirm zero definitions
  remain before the step is done.
- **`read_only?` over-deletion:** delete the `approval_required?` methods on the
  browser/MCP sources, but `read_only?` feeds `build_request` — do **not** delete it
  reflexively; dead-code-check each and keep any with a live caller (`07` §1).
- **Test-breakage window:** this commit intentionally breaks every suite that pinned
  the old chain before the rewrites land — the step is not done until the rewrites
  are green in the same commit. If the diff grows unreviewable, the only legitimate
  split is (a) convergence with the old chain deleted, then (b) profile-key/`--all`
  deletion — never convergence while the old chain still fires (two policy owners).
- **Ordering hazard:** requires steps 1–6 landed; the engine must already be wired
  into session effects. Do not reorder.
- **Dead-key window:** profile keys must die in the same commit as the chain that
  consumed them — between commits they would be accepted-but-ignored config, which is
  the silence the ADR calls the bug (§2.2).

---

### Step 8 — Comms: evidence from the decision, constant deleted

**Goal.** The prompt pins `decision.required_evidence`; the hardcoded constant and
its file die (ADR §3 weakness 3, §5 step 5, §10 S6).

**Scenarios (must pass):** E-1, E-2 (`06`; E-2's load-time rejection is proven in
step 2, exercised end-to-end here). **Hard-zero:** E-2.

**Files modified:**
- `gems/tamoz-comms/lib/tamoz/comms/approval_prompt.rb` — `:85` pins the
  caller-supplied evidence symbol (from the `Decision`) instead of
  `ApprovalPolicy.required_evidence`; build maps the symbol onto the closed lattice,
  non-members raise there exactly as today (ADR §1.2).
- `gems/tamoz-comms/tamoz-comms.gemspec` — dependency edge on `tamoz-approval` (ADR
  header consequences; see risk note).
- `gems/tamoz-agent/lib/tamoz/agent/outbox_delivery_sink.rb` — `:171` reads evidence
  from the decision carried by the interrupt, not the constant.
- `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb` — evidence compare (`:258-261`,
  `07` §4 corrects `:259-262`) reads from the decision.

**Files deleted:**
- `gems/tamoz-comms/lib/tamoz/comms/approval_policy.rb` — the constant (audit §5.3;
  7 lines, three reference sites — all updated in this commit).

**Tests (updated):** `test/comms_evidence_gated_approval_test.rb` (15 tests, ADR-049
bar — repoint to data-driven evidence, unchanged transport semantics),
`test/comms_authority_evidence_test.rb` (stop pinning the constant body; keep the
lattice pins), `test/comms_deny_callback_test.rb`,
`test/sqlite_comms_store_test.rb`, `test/comms_values_test.rb` as needed.

**Verification:** targeted comms suites green; full gate green.

**Risk.** **Signature change spans two gems:** `ApprovalPrompt.build`'s callers live
in agent, so the comms change and the agent re-point must be one commit. The comms →
approval gemspec edge is what the ADR declares; if the implementation turns out to
pass only plain symbols across the boundary (no `Tamoz::Approval` constant referenced
from comms code), record that in the commit message and omit the edge rather than
adding a dependency nothing uses — then flag the deviation back to the ADR.
Cross-check: the evidence lattice, binding checks, atomic consumption, and drainer
activation must be untouched (ADR §5 step 5) — the suites above are the proof.

---

### Step 9 — Pipeline B convergence + `ApprovalDeniedError` deleted + tamoz-evals

**Goal.** The one-shot runtime shrinks to a call site with identical verdict
semantics (ADR §2.4 Pipeline B, §5 step 4); denial-as-result propagates to the eval
harness (ADR §5 step 7, §10 P7).

**Files modified:**
- `gems/tamoz-agent/lib/tamoz/agent/runtime.rb` — `:582-605` replaced by
  `engine.build_request` + `engine.decide` on the **in-memory-backed one-shot engine**
  constructed at `agent.rb:102` (step 6), not a fresh store built here; `:ask` prompts
  through `Answer.parse` (the one-shot path inherits the full vocabulary, ADR §1.4);
  `:deny` returns the same structured tool result as Pipeline A. The
  callback-plus-exception contract is deleted.
- `gems/tamoz-agent/lib/tamoz/agent/cli.rb` — `approve_one_shot` (`:853-858`)
  re-pointed at `Answer.parse`.
- `gems/tamoz-evals/.../harness/agent_smoke_corpus.rb` (`:1027-1043`) and
  `gems/tamoz-evals/suites/agent/smoke/07_denied_approval*.case.json` — updated for
  denial-as-result: the corpus pins the new behavior, the suite cases assert the
  structured denial result (repoint, don't soften).
- `gems/tamoz-evals/.../harness/agent_run_audit.rb` (`:43-45,97-105`) — `approval:`
  lambdas updated to the engine-shaped gate.

**Files deleted:**
- `gems/tamoz-agent/lib/tamoz/agent/errors.rb:46` — `ApprovalDeniedError` (ADR §1.3:
  denial is data, not control flow). Its **raise** (`runtime.rb:603`) and **all
  rescues** go in this commit: `cli.rb:185` and `agent_smoke_corpus.rb:2939` are the
  verified sites (`07` §2); the risk note's grep is the completeness check.

**Public-api pins:** `ApprovalDeniedError` out of `test/public_api_test.rb` (`:17`),
`docs/public-api.json`, `documentation/reference/public-api.md`.

**Tests (updated):** `test/agent_runtime_test.rb` (`:256`),
`test/agent_tool_error_recovery_test.rb` (`:286`) — assert the structured denial
result instead of the exception.

**Scenarios (must pass):** D-3, V-1 (`06`). **Hard-zero in this step:** D-3.

**Verification:** targeted tests green; eval smoke suite for `07_denied_approval`
green; full gate green. Append the §6 evidence note.

**Risk.** `ApprovalDeniedError` is rescued at `cli.rb:185` and
`agent_smoke_corpus.rb:2939` (verified, `07` §2), raised at `runtime.rb:603`, and
defined at `errors.rb:46` — but grep the whole repo (`ApprovalDeniedError`) before
deleting in case a rescue was added since this pass, and update every one in this commit.
The eval change is data + harness, not a Ruby-side policy literal — the denial
expectation lives in the `.case.json` suites (B9).

---

### Step 10 — Scheduler: informational hash deleted, profile name in

**Goal.** Schedules name an approval profile like any other run; the dead
informational hash dies (ADR §3 weakness 10, §5 step 6).

**Files modified:**
- `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb` — `approval_policy` hash
  field (`:35,305`) deleted.
- `gems/tamoz-agent/lib/tamoz/agent/cli_schedule_commands.rb` — the CLI hardcode
  (`:92`) deleted; schedule creation takes an optional profile name, plumbed through
  to the run config the boot wiring reads (step 6).

**Files deleted:** none (field/key removals only).

**Tests (updated):** scheduler schedule tests (field gone), CLI schedule-command
tests (profile name accepted and propagated; `paused_approvals` status readers —
`script/autonomy_scorecard`, `script/live_alms_telegram` — still report, they read
status not the deleted hash; verify).

**Verification:** targeted tests green; full gate green.

**Risk.** Low. Only hazard is a JSON/serialization consumer of the hash field — grep
for `approval_policy` across `gems/`, `script/`, `bin/` before removal.

---

### Step 11 — Stream: receipt TTL injected at subscriber boot

**Goal.** The §5.4 fix's stream half: receipts expire; the TTL is a plain integer
from run config; the relay's port shape is documented by the gem (ADR §2.4, §10
P6/A5).

**Files modified:**
- `gems/tamoz-stream/lib/tamoz/stream/approval_relay.rb` — enforce/document the
  receipt port's `expires_at` semantics; the port shape the relay injects is
  documented **in the gem**, replacing `bin/tamoz-stream-subscriber`'s dynamic
  require as the source of truth (the gem absorbs the port-injection pattern, not the
  file — ADR §2.4). The relay's guards (receipt state, relay≠approver, fail-closed
  expiry, single-use nonce) are untouched protocol invariants.
- `bin/tamoz-stream-subscriber` (`:42-64`) — TTL injected as a plain integer from run
  config at boot; `tamoz-stream` never loads policy documents.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/approval_receipt_store.rb` — honor the
  `expires_at` column added in step 5 (expired receipt = absent, fail closed).

**Files created/deleted:** none. **`test/stream_invariants_test.rb`'s glob (`:26`) is
untouched — no stream file moves** (ADR §5 step 7); this step verifies that rather
than changing it.

**Tests (updated):** `test/stream_approval_relay_test.rb` (14 tests) — expiry cases;
`test/stream_learning_loop_test.rb` as needed; sqlite receipt-store expiry test.

**Verification:** targeted stream suites green; `stream_invariants_test.rb` green
unchanged; full gate green.

**Risk.** Low. The one discipline: no policy-document loading in `tamoz-stream` and
no new comms dependency (audit §6.3) — the TTL is an integer, exactly like the
relay's other injected ports.

---

### Step 12 — Docs + final sweep

**Goal.** Documentation matches the new reality (ADR §5 step 8); the repo's own
conventions files name the new gem.

**Files modified:**
- `documentation/adr/adr-049-telegram-approval.md` — updated where it describes the
  constant policy (evidence now comes from the `Decision`, validated at load).
- `documentation/design/comms.md` — the six-site split is gone; comms section
  describes evidence-from-decision.
- `documentation/architecture/security-model.md` — policy-as-data, digest-pinned
  documents, grant ladder, fail-closed reload.
- `README.md` (component map) and `AGENTS.md` — `tamoz-approval` added to the gem
  list; the "approval policy is data in `gems/tamoz-approval/policy/*.yaml`" rule
  stated next to the existing domain-data rule.
- `docs/approval-policy-redesign-2026-08-22/03-redesign-adr.md` — status flipped to
  **implemented** with the final commit reference.

**Final consistency sweep (no earlier step may leave these behind):**
- Grep sweep: `approval_required`, `ApprovalDeniedError`, `ApprovalPolicy`,
  `--i-understand-approve-all`, `unattended_approval_required`, `tools.approval_required`
  — zero hits outside this `docs/` folder and `CHANGELOG.md`.
- `test/public_api_test.rb`, `docs/public-api.json`,
  `documentation/reference/public-api.md` consistent with the final surface.
- `test/packaging_test.rb` green with the new gem.
- `enola generate_snapshot` + `diff_snapshot` against the pre-step-1 baseline: the
  expected delta is one new gem, three new edges (agent, comms, sqlite → approval;
  comms edge per step 8's note), the tools→agent classification coupling gone, no new
  cycles.

**Scenarios (must pass):** M-3 (`06`; the zero-live-references sweep) and a final
re-run confirming every scenario in `06` still passes — this is the whole-program
definition of done (`00` §8).

**Verification:** full gate green, `ci_full` (packaging/evidence slice) green, sweep
clean.

**Risk.** Doc claims rot silently — every structural sentence edited must be checked
against the code it names (the audit's §6.5 rot list is the checklist).

---

## 2. Traceability — ADR → steps

| ADR element | Step(s) |
|---|---|
| Decision / header: new gem, one interface, policy as data, no shims | 1–3, 7–9 (deletions) |
| §1.1 Boundary rule (gem decides, callers describe; single canonicalization seam) | 3 (`build_request`), 7, 9 (call sites) |
| §1.2 `Request` / `Decision` / `GrantOffer` values | 1 |
| §1.2 `Engine` (`build_request/decide/resolve/simulate/reload`) | 3 |
| §1.3 Error taxonomy + `resolve` idempotence + `ApprovalDeniedError` deletion | 3 (errors, semantics), 9 (deletion) |
| §1.4 `Answer.parse` + interactive scope follow-up | 1 (parse), 7 (follow-up), 9 (one-shot) |
| §1.5 Wiring: engine at boot, constructor injection, evidence symbol set injection | 4 (symbol set), 6 (wiring) |
| §1.5 Reload via `tamoz_approval_active_policy` + worker pickup; in-flight rev binding; superseded-document retention | 5 (table), 6 (CLI + pickup), 3 (retention) |
| §2.1 Policy document format (YAML, digest, validation, timeout semantics, `simulations:`) | 2 (document + loader), 7 (timeout enforcement in poll pass) |
| §2.2 Profile mechanism (path lookup, overlays, old keys fail loudly, `tools.allowed` stays) | 2 (mechanism), 7 (old keys deleted) |
| §2.3 Grant store (port, key grammar, scopes, rev-bound lookup, teardown, memory impl) | 3 (port + memory + grammar), 5 (SQLite), 7 (teardown wiring) |
| §2.4 Pipeline A convergence | 7 |
| §2.4 Pipeline B convergence | 9 |
| §2.4 Pipeline C argued non-convergence; receipt `expires_at` + TTL injection; port shape documented in gem | 5 (column), 11 |
| §2.5 Decision log (port, cleartext structural fields, digest args, idempotent append) | 3 (port + memory), 5 (SQLite) |
| §3 weakness 1–7, 9, 10 fixes | 7 (1,2,5,6,7), 1+7+9 (9), 8 (3), 5+7+11 (4), 10 (10) |
| §3 weakness 8, 11 (argued, not fixed) | none — see §4 out of scope |
| §4.1 adopted recommendations (evaluator, tiers, profiles, grant ladder, log, validate-before-activate) | 2, 3 |
| §4.1 deviations 1–6 (taint, batching, sandbox, async, rate-limit, cost tier) | none — see §4 out of scope |
| §4.2 open questions 1–8 (grant keys, tier ownership, child tasks, profiles, simulation surface…) | 2, 3 (data + engine semantics); Q4 child-session grant non-transfer needs no code (grants match `session_id`) — asserted in step 7 teardown/grant tests |
| §5 migration step 1 (gem) | 1, 2, 3 |
| §5 migration step 2 (sqlite) | 5 |
| §5 migration step 3 (Pipeline A) | 7 (+ wiring split out as 6) |
| §5 migration step 4 (Pipeline B) | 9 |
| §5 migration step 5 (comms) | 4 + 8 |
| §5 migration step 6 (scheduler) | 10 |
| §5 migration step 7 (tests, incl. tamoz-evals, public-api pins, stream glob) | per-step test updates; evals in 9; public-api per-step + 12 sweep; glob verified in 11 |
| §5 migration step 8 (docs) | 12 |
| §6 simplicity budget / not-built list | §4 below |
| §7 strengths preserved (1–7) | 3 (1,2,7), 8 (3,4 — asserted by unchanged comms suites), 5+7 (5), 1 (6 — port-injected shape) |
| §8 repo invariants (journaled verdict, idempotent log append, fail-closed divergence, zero policy literals in Ruby) | 7 (journaling), 3+5 (idempotence), 2 (data-only) |
| §10 review items S1–S9, P1–P12, A1–A8 | mapped via the sections above; no item requires plan content beyond those sections |

**Every deletion → removing step:**

| Deleted thing (ADR §5, §8; anchors `07`) | Step |
|---|---|
| the **nine-method** `approval_required?` chain: `session_effects.rb:291`; `capability_binding.rb:144,343,392`; `local_dispatcher.rb:51`; `toolbox.rb:105`; `child_task_dispatcher.rb:117`; `governed_browser_source.rb:35`; `mcp_capability_source.rb:129` (keep `read_only?`) | 7 |
| `DEFAULT_APPROVAL_REQUIRED` (`tool_catalog.rb:28` + `toolbox.rb:40`) | 7 |
| `tool_policy_normalizer.rb:119-133` validation | 7 |
| `worker_runtime.rb:864` unattended union **+ consumer `:1072`/`:1086`** | 7 |
| Profile keys `tools.approval_required` / `unattended.*` + validators (`profile/fields.rb`, `authority_validator.rb:115-124`) | 7 |
| `--all --i-understand-approve-all` (`cli.rb:472` block **+ `:678` registration**) | 7 |
| `test/agent_capability_binding_test.rb:44` | 7 |
| `approval_policy.rb` (`Comms::ApprovalPolicy` constant) | 8 |
| `ApprovalDeniedError` (`errors.rb:46`) + callback-plus-exception contract | 9 |
| Scheduler informational `approval_policy` hash (`schedule.rb:35,305`) + CLI hardcode (`cli_schedule_commands.rb:92`) | 10 |

Nothing in the ADR is unplanned; no step builds anything the ADR does not specify.

---

## 3. Risks (cross-cutting)

- **Digest re-pinning (steps 2, 6, 7):** editing `policy/*.yaml` changes
  `policy_rev`; `Decision#id` derives from it. Mitigation: tests assert
  digest-vs-content stability, never hardcoded hex; the document's `simulations:`
  block is the invariant pin; session-bound rev means a mid-run edit only affects new
  sessions (fail-closed by construction, ADR §1.5/§2.3).
- **Test-breakage windows (step 7):** the cut-over commit turns whole suites red
  until its rewrites land. Mitigation: the step's verification is the full gate, not
  the targeted files; no partial commit.
- **Multi-process reload rollout (steps 5, 6):** CLI and worker share only the
  database row. Mitigation: reload-delivery test exercises the real
  write→poll-pickup path; validate-before-write keeps broken documents out of the
  table.
- **Migration manifest pinning (step 5):** ordinals are checksummed. Mitigation:
  follow the existing checksum convention, run any manifest regeneration script in
  the same commit, `ci_full` both locales.
- **Two-gem signature change (step 8):** prompt-build callers live in agent.
  Mitigation: one commit; unchanged-transport proof is the repointed comms suites.

---

## 4. Out of scope (not built — each mapped to the ADR)

- **Pipeline C convergence / moving the relay** — argued non-convergence (ADR §2.4);
  the relay, its guards, and the `io.agenticstream.approval.*` contract stay in
  `tamoz-stream`. Only `expires_at` + TTL injection change (step 11).
- **Taint flags** (ADR §4.1 deviation 1), **plan-level batching** (deviation 2),
  **sandbox floor** (deviation 3), **async continue-while-pending** (deviation 4),
  **ask rate-limiting / prompt counter** (deviation 5), **cost-bearing verb tier**
  (deviation 6) — each explicitly deferred by the ADR; the plan builds none.
- **Push wakeup for resume** (ADR §3 weakness 8 — argued, accepted), **prompt
  activation decoupling** (weakness 11 — kept in comms, narrowed only: step 8 moves
  the policy output, not the plumbing).
- **OPA/Cedar, capability/attenuation tokens, managed profiles, grant revalidation
  sweeps, a new descriptor field** (ADR §6 not-built list; §4.2 Q4/Q7) — unbuilt;
  read-time `policy_rev` match replaces revalidation; `tool_tiers` data replaces a
  descriptor field, so **tamoz-core's descriptor is untouched** (no step modifies
  `gems/tamoz-core`).
- **Prompt/decision transport tables, evidence lattice, interrupt machinery,
  graph-state journaling** (ADR §5 step 2, §7) — stayed, deliberately; no step
  modifies them.
- **A user-facing "what could this profile do" command** (ADR §4.2 Q8) — `simulate`
  is engine-public and used by load validation and tests only.

---

## 5. Revision log

One self-critique pass, performed after the full draft above was written: each bar
item 1–5 was re-read against the draft, and every gap found was fixed in the body
before this log was written.

**What the critique found and what changed:**

1. **Bar 1 (green tree) — boot wiring was fused into the Pipeline A step.** The
   draft's single "convergence" mega-step both built the engine wiring and switched
   call sites; that is two reviewable changes and the wiring half is
   behavior-neutral, so it can land green on its own. Split into step 6 (wiring +
   reload delivery) and step 7 (convergence + deletions).
2. **Bar 1 — comms prompt-build signature change crosses gems mid-sequence.** The
   draft had comms evidence-from-decision as a late standalone step, but
   `ApprovalPrompt.build`'s callers are in agent — a green tree requires the comms
   change and the agent re-point in one commit. Fixed: step 8 states this
   explicitly, and step 4 lands the additive symbol-set exposure ahead of any
   consumer.
3. **Bar 2 (coverage) — three ADR elements had no home.** The draft missed:
   `docs/public-api.json` / `documentation/reference/public-api.md` updates per
   symbol-changing step (only `public_api_test.rb` was named); the operator command
   `tamoz approve <id>` that makes `park` recoverable (ADR §2.1); and grant-row
   deletion at session teardown (ADR §2.3). Added to the global conventions, step 7,
   and step 7 respectively; teardown asserted by a test.
4. **Bar 2 — `stream_invariants_test.rb` was listed as "untouched" with no step
   owning the verification.** Fixed: step 11 explicitly verifies the glob passes
   unchanged (the audit's point is that *not* moving the file is what keeps it green).
5. **Bar 3 (traceability) — the comms → approval gemspec edge.** The ADR declares
   the edge, but the implementation may pass only plain symbols across the boundary,
   making the edge unjustified by actual imports. Fixed: step 8 adds the edge per the
   ADR and names the honest escape hatch (omit + flag the deviation) rather than
   adding a dependency nothing uses.
6. **Bar 4 (risks) — two hazards were unnamed.** Dead-key window between chain
   deletion and profile-key deletion (must be one commit — ADR §2.2's "silence would
   be the bug"); `ApprovalDeniedError` rescues outside the audited sites (grep before
   delete). Both added: step 7 risk note, step 9 risk note.
7. **Bar 5 (out of scope) — the draft listed deviations but not the "stayed" set.**
   Added: transport tables, evidence lattice, interrupt machinery, journaling, the
   core descriptor, and the simulate-only surface — each with its ADR reference, so
   "not planned" is distinguishable from "forgotten".
8. **Bars re-checked without change:** step ordering dependencies (each step consumes
   only what earlier steps landed: 7 needs 1–6, 8 needs 7, 9 needs 3+6, 11 needs 5),
   one-commit sizing, and per-step gate verification.

**Rev 2 (2026-08-22) — code-verification pass (`07-evidence-index.md`).** The anchors
were grepped against the tree. Changes:

1. **The `approval_required?` deletion inventory was incomplete.** Rev 1 (and the ADR)
   listed four of the nine methods in the delegation chain. Step 7 now deletes all
   nine (`07` §1), keeps the `read_only?` predicates the browser/MCP sources derived
   from (they feed `build_request`), and adds a dead-code check and a
   "zero `def approval_required?` remain" completeness grep to the step's risks.
2. **Two deletion sites were omitted.** The `--all` **option registration**
   (`cli.rb:678`, beyond the audit block at `:472`) and the unattended-union
   **consumer** (`worker_runtime.rb:1072`/`:1086`, beyond the definition at `:864`)
   are now in step 7.
3. **A third `ApprovalDeniedError` rescue** (`cli.rb:185`, beyond the one-shot site and
   the evals corpus) is now named in step 9.
4. **Line drifts corrected** from the fresher reading: `session_steps` approvals slot
   `:128-140`→~`:108-110`; deliberation `:307-314`→`:309`; gateway `:259-262`→`:258-261`
   (`07` §4). The `EFFECT_CLASSES` untouched-claim was re-confirmed (`descriptor.rb:52`).
5. **Acceptance scenarios wired in.** Every step now names the `06-acceptance-scenarios.md`
   IDs it must make pass and the hard-zeros among them; the bar's per-step evidence
   note (`00` §6) is required at each step's close.
