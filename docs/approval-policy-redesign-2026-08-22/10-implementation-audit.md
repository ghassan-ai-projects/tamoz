# Implementation audit — approval-policy redesign

Reviewer: code audit (branch `redesign-approval-policy`, base `main` @ `3957cb9`)
Date: 2026-08-23
Scope: the code that implements this folder's design — the `tamoz-approval` gem,
its SQLite adapters, and the agent/comms/CLI wiring that consumes it. Tests were
read for intent but **not executed** (per request); every claim below is anchored
to source `file:line`.

## Method

- Read the full `tamoz-approval` gem (1,262 LOC), the three SQLite stores + the
  MIGRATION_17–19 schema, and every consumer seam (`runtime.rb`, `session_effects.rb`,
  `worker.rb`, `worker_runtime.rb`, `comms_gateway.rb`, `cli*.rb`).
- Traced the two decide pipelines end to end (one-shot/interactive vs durable worker),
  the resolve/replay path, reload, and the §2.6 mid-session rebind.
- Ran the architecture indexer (enola) for cycles / layering / god-class / complexity;
  verified the flagship credential-deny glob against real canonicalized paths.

## Verdict

The implementation is **sound and close to the design intent.** The headline goals hold
in code: one `Engine#decide` owns classification for both local pipelines, policy is
digest-pinned data, unclassified/opaque-argv tools fail closed to `:once`, evidence
enforcement is correctly located in comms (not spoofable by the engine's caller), and
the "no legacy shims" directive is honored — there are **zero** dangling references to
`ApprovalDeniedError`, `Comms::ApprovalPolicy`, or the old classification chain
(`grep` across `gems/`, `bin/` is clean). Architecture is clean: the gem is a
tamoz-core leaf, the SQLite stores depend on the ports (correct direction), and enola
reports **no new dependency cycle and no layer violation** attributable to the feature.

What follows are the defects and rough edges worth closing. None is a hard-zero
security hole; the two I'd fix before calling this done are **F1** (a duplicated
projection that can silently diverge the two pipelines' grant keys) and **F2** (a
policy tier that advertises a capability the engine can never grant).

Severity legend: **High** = correctness/security risk or a design-invariant breach;
**Medium** = latent bug / misleading behavior; **Low** = cleanliness, dead code, minor
robustness.

---

## Findings

### F1 — The argv/target projection is duplicated across both pipelines (High)

`gems/tamoz-agent/lib/tamoz/agent/session_effects.rb:326-342` and
`gems/tamoz-agent/lib/tamoz/agent/runtime.rb:726-742` contain **byte-identical**
copies of `approval_argv` and `approval_targets`.

This is the exact seam the ADR says must have one home. `session_effects.rb:299-302`
even asserts it: *"the only place tool argument structure is translated into grant-key
material."* It is now in two places. The projection is what feeds `build_request`'s
`argv:`/`targets:`, which the evaluator folds into the **grant key** and the decision
digest. If the two copies ever drift (a new tool added to one, an argument reordered),
the same tool call produces a different grant key / target set in the durable worker
than in the one-shot runtime — silently breaking grant reuse in one path, or minting a
grant keyed on material the other path never presented to the human.

**Fix:** hoist both methods to one shared home (a module method on `Tamoz::Approval`,
or a small `RequestProjection` object the engine exposes) and have both call sites use
it. This is also the natural place to unit-test the projection once instead of twice.

### F2 — `workspace_write`'s `:session` grant scope is structurally unreachable (Medium)

`policy/base.yaml:42-46` declares `workspace_write.grant_scopes: [once, session]`, with
a comment justifying the `session` entry ("an ask must be grantable"). But
`grant_keys` (`base.yaml:60-61`) only has an entry for `local_execute`. In
`evaluator.rb:81-91`, `grant_offer_for` computes the scopes, then:

```
key = grant_key_for(request, tier)   # nil — no grant_keys[:workspace_write]
scopes = [:once] if key.nil?         # session is dropped here
```

So for `apply_patch` / `create_file`, an `:ask` decision is **always** offered `[:once]`,
never `:session` — regardless of what the tier advertises. The consequence surfaces in
the interactive CLI: `cli.rb:479-481` only offers "remember for this session" when
`asked['grant_scopes']` includes `'session'`, which it never will for a file write.
"Remember for session" is therefore silently unavailable for exactly the writes an
`unattended`/tightened profile would gate — which is the floodgate-replacement the
redesign is built around.

Either this is dead/misleading config (drop `session` from the tier) or a missing
`grant_keys: { workspace_write: [...] }` entry. Whichever the intent, the validator
should catch the mismatch — see F3.

### F3 — No validator (and no simulation) guards "advertises `:session` but can't mint it" (Medium)

`policy_document.rb`'s validators (`validate_tiers!` :232, `validate_tool_tiers!` :209)
check that `:session` is *not* offered where forbidden (`NO_SESSION_SCOPE_TIERS`), but
nothing checks the converse: a tier/tool that *does* list `:session` must have a
`grant_keys` entry, or the scope is a no-op (F2). The `simulations:` block
(`base.yaml:85`, run at load) only asserts the **verdict**, never the offered grant
scope, so a policy author gets no signal. Add a load-time check: for every tier whose
`grant_scopes` (or a tool's) include `:session`, require a `grant_keys[tier]`; and/or
extend the simulation schema to optionally assert `expect_scopes`.

### F4 — `:once` grants are persisted but never read back (Low)

`engine.rb:245-259` (`mint_grant`) mints a `Grant` for every approved `:once` answer,
and `resolve` inserts it (`engine.rb:100`) — the durable worker path does this on every
comms approval (`worker.rb:423-427`, always `scope: :once`). But the only reader,
`find_live_session_grant` (`engine.rb:284-299`), returns `nil unless … scopes.include?(:session)`
and looks up `scope: :session`. No code path ever queries a `:once` grant row. They are
write-only: `tamoz_approval_grants` accumulates one dead row per approved action until
`close_session` purges them.

It's harmless (masked by `LIMIT 1` on lookup, cleaned at session close) but it's dead
persistence on the hot path. Either don't insert `:once` grants (mint them, return them,
don't store), or document why the row must exist for replay. If it *is* needed for
resolve-replay idempotency, that intent isn't stated anywhere and should be.

### F5 — Cross-process resolve replay can double-insert a grant row (Low)

`engine.resolve` (`engine.rb:81-102`) serializes lookup→record→insert under a
**per-process** `Mutex`, and the SQLite `record_resolution` (`approval_decision_log.rb:63-85`)
correctly guards the resolution itself with `UPDATE … WHERE answer IS NULL` + replay
read. But the grant *table* has no uniqueness: MIGRATION_17 creates
`tamoz_approval_grants` with only a non-unique index (`migrator.rb:1140-1152`), and
`ApprovalGrantStore#insert` (`approval_grant_store.rb:36-45`) is a bare `INSERT`. In the
window where two processes both read `lookup_resolution == nil`, the loser's
`record_resolution` returns the winner's grant (replay branch,
`approval_decision_log.rb:75-83`) and the loser then re-`insert`s that identical grant —
two physical rows for one logical grant.

The engine's own comment (`engine.rb:78-80`) states the invariant is *exactly one grant
row*. It holds within a process, not across. Add a `UNIQUE(key, scope, session_id,
policy_rev)` (or `INSERT … ON CONFLICT DO NOTHING`) to close it. Functionally low-impact
today because resolve is rarely concurrent across processes and lookup uses `LIMIT 1`.

### F6 — Worker adopts a reloaded document without confirming its rev matches the pointer (Low)

`worker_runtime.rb:786-794` (`sync_approval_policy`) compares the persisted pointer's
`rev` to the live engine rev and, on difference, `reload(pointer.fetch(:path))` — it
loads from the **path** and never checks that the freshly loaded `policy_rev` equals the
`rev` the CLI validated and wrote (`cli_worker_commands.rb:386-402`). If the file on
disk drifts between `tamoz approve --reload` and the worker's next poll, the worker
adopts whatever the file now says (as long as it's structurally valid; an invalid one is
correctly caught and ignored, `:792-793`). The pointer already carries the exact rev, so
the check is nearly free: after reload, assert `new_rev == pointer[:rev]` and skip
(keep-running) on mismatch. Small TOCTOU-hardening; validate-before-activate otherwise
holds.

### F7 — Schema built in three migrations on one unreleased branch (Low, cleanliness)

The branch ships MIGRATION_17 (`migrator.rb:1138`), then MIGRATION_18 (`:1196`) which
**drops and rebuilds** `tamoz_approval_decisions` — a table 17 created on this same
branch — only to add the `step_scope` column and the mode-switch table, then
MIGRATION_19 (`:1292`) adds one more index. Given the redesign's explicit "no backwards
compatibility, databases may be reset" directive (README "Owner directives"), MIGRATION_17
could have been authored in its final shape (one CREATE with `step_scope`, the switch
table, and both indexes), leaving a single clean migration. The three-step churn is
inert once checksums are pinned, but it's avoidable archaeology for a schema no released
build has ever seen. Consider collapsing before merge.

### F8 — Redundant `private` and a 30s policy-staleness window (Low)

- `session_effects.rb:344` is a second `private` inside a block already made private at
  `:324` (methods 326–342 sit between them) — a no-op marker; delete it.
- `lane_ask` (`worker.rb:976-985`) caches the `ask` block (which carries `on_timeout`)
  for 30s per profile. After a reload or §2.6 rebind, a parked ask can evaluate its
  timeout against an up-to-30s-stale `on_timeout`. Benign given the 900s ask timeout,
  but worth a comment, or key the cache on `policy_rev` so a rev change invalidates it.

---

## What is done well (kept, not just tolerated)

- **One classification owner, verified.** Both local pipelines route through
  `Engine#build_request` + `decide`/`decide_or_reuse` (`runtime.rb:657-665`,
  `session_effects.rb:304-312`); the stream relay is left as a pure relay. The nine-method
  delegation chain the audit (`02`) complained about is gone.
- **Fail-closed defaults are real.** Unclassified tools take fallback-tier scopes, and an
  opaque-argv tool can never mint `:session` (`evaluator.rb:93-124` forces `[:once]` when
  no grant key resolves); `validate_tool_tiers!`/`validate_tiers!` reject `:session` on
  `network`/`external_publish`/`destructive`/`child_task` at load.
- **Evidence can't be self-asserted.** The engine deliberately does **not** check
  `actor_evidence` against `required_evidence` (`engine.rb:233-243`); enforcement lives in
  comms where the real channel identity is known (`comms_gateway.rb:257-263`,
  `chat_bound < required_evidence` refuses). Correct trust boundary.
- **Digest over normalized structures** (`policy_document.rb:314-335`) means a no-op
  profile overlay yields the same `policy_rev`, so live grants survive a cosmetic reload —
  the invariant the comment claims actually holds because `digest_basis` hashes the
  normalized fields, not raw YAML.
- **Replay reasoning is careful.** `resolve`'s single critical section, `decide_or_reuse`
  keyed on `execution_id.plan_id.step_id` (`session_steps.rb:81`), and the mode-switch
  idempotency on the request id (`worker.rb:859-905`) are coherent and well-commented.
- The flagship `credential-files` deny (`base.yaml:64-69`) **does** match real
  canonicalized absolute paths (verified: `**/.env*` matches `/…/proj/.env`,
  `.env.local`, `config/.env`) — targets are `File.realpath`-canonicalized before
  matching (`engine.rb:347-360`).

## Recommended order of work

1. **F1** — dedupe the projection (single most important; latent cross-pipeline drift).
2. **F2 + F3** — decide whether `workspace_write` session grants are real; make the
   policy and the validator agree, so authoring can't silently no-op.
3. **F5** — add the grant-table uniqueness constraint.
4. **F4, F6, F7, F8** — cleanliness / hardening, batchable.

Nothing here blocks the design; F1–F3 are what stand between "works in the tests" and
"the policy behaves the way an author reading the YAML would expect."
