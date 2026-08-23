# 03 — ADR: Isolate approval policy into `tamoz-approval`

**Status:** implemented — phases 1–12 of `05-implementation-plan.md` landed on
`redesign-approval-policy`; final evidence in `08-implementation-bars.md`
(head commits: `c1de9be` phases 7+7B, `c8ee0b1` phase 8,
`6096996` phase 9 + review fixes). rev 2 (2026-08-22) incorporated the three
staff reviews (`04-review-security.md`, `04-review-simplicity.md`,
`04-review-api.md`); every finding is mapped in §10.
**Date:** 2026-08-22
**Inputs:** `01-independent-study.md` (green-field study), `02-current-state-audit.md` (current-state audit). Section references like "audit §5.3" and "study §4.1" point at those files.

---

## ADR header

### Context

The audit (§0) found that "approval" in tamoz is three mechanisms sharing one word:
the durable-session interrupt gate (Pipeline A), a one-shot callback gate
(Pipeline B), and an external stream approval relay (Pipeline C). The rule that
answers "does this action need approval?" is split across six sites in four gems
(audit §2.1, §5.2); the channel evidence policy is a hardcoded Ruby constant that
neutralizes a fully built mechanism (§5.3); there are no scoped grants, so the only
escape from per-call prompting is a blanket `--all` flag (§5.5); an unanswered
approval parks the turn forever (§5.4); and denial kills the turn silently (§5.6).
The owner's goal: make the policy significantly simpler, and make policy and profile
changes possible without touching `tamoz-core` / `tamoz-agent`.

### Decision

Create a new gem, **`gems/tamoz-approval`** (namespace `Tamoz::Approval`), that owns
every *policy* decision behind one narrow interface: `build_request / decide /
resolve / simulate / reload`. All policy content — tier assignment, rules, profiles,
evidence requirements, timeout semantics, grant scopes — is **data** (YAML policy
documents, content-addressed by digest) loaded by the gem. Pipelines A and B converge
on `Engine#decide`; Pipeline C stays in `tamoz-stream` as a pure relay (it makes no
local decision — argued in §2.4). The proven *transport* machinery
(interrupt/pause/resume, digest-bound single-use decisions, evidence lattice, atomic
prompt consumption) stays where it is and becomes the answer-delivery layer
underneath the gem. No legacy shims: the old profile keys, the hardcoded constant,
`ApprovalDeniedError`, and the scheduler's informational `approval_policy` hash are
deleted outright.

### Consequences

- A policy change is a YAML edit in `tamoz-approval` — zero Ruby changes, zero
  core/agent changes, and that includes reclassifying a tool to a stricter tier
  (tier assignment is data, §2.1). A profile change is selecting a different named
  profile; adding one is dropping a file. Named profiles also express Claude Code's
  permission modes (plan / review / implement / auto / bounded bypass), switchable
  live mid-session (§2.6).
- Classification collapses from 8 rule sites in 4 gems to 1 data file + 1 evaluator.
- Denial becomes a structured tool result the model can react to; turns no longer die
  on the first "no".
- Session-scoped grants end the "tenth identical `run_check` prompts a tenth time"
  failure without opening the `--all` floodgate (which is deleted) and without the
  over-bundling hole (argv-aware keys, opaque-argv tiers barred from `:session`,
  §2.3).
- Three gems gain a dependency edge on `tamoz-approval`: `tamoz-agent`,
  `tamoz-comms`, and `tamoz-sqlite` (which implements the two new store ports — the
  same edge it already carries for every gem whose store contract it implements).
  The dependency is one-directional: `tamoz-approval` depends only on `tamoz-core`.
- The old classification seams (`Toolbox#approval_required?`, the dispatcher-routed
  `approval_required?` chain, `tools.approval_required` / `unattended.*` profile keys)
  disappear. Anything still calling them fails to compile/boot — deliberately; there
  is no compatibility layer to audit.

---

## 1. The decision interface

### 1.1 Boundary rule

The gem returns verdicts; it never executes. Core/agent ask "may I do X?"; they never
evaluate policy. Concretely this deletes the current worst violation — the classifier
being the same object that executes the call (audit §5.7,
`capability_binding.rb:144-147`): dispatchers now only *describe* the call (tool
name, raw argv, targets, the descriptor's effect class) and the engine decides. The
engine's `build_request` factory (§1.2) canonicalizes that description into the
`Request` — no caller ever assembles one by hand, so deny globs and grant keys rest
on exactly one canonicalization seam, not two call sites drifting apart.

### 1.2 Ruby interface

```ruby
module Tamoz
  module Approval
    # Immutable, canonicalized INSIDE the gem by Engine#build_request (study F3):
    # targets are realpath-resolved (a workspace symlink at ~/.ssh must not bypass
    # the .env deny glob), argv is the exact invocation, never a shell string to
    # be re-parsed downstream. What was decided on is exactly what executes.
    Request = Data.define(
      :tool,          # String  — "run_check", "mcp:github:create_pr", "child_task"
      :verb,          # Symbol  — :read, :write, :execute, :network, :publish,
                      #           :unknown (opaque MCP; filled from tool_tiers data)
      :argv,          # Array<String> — exact invocation
      :targets,       # Array<String> — realpath-canonicalized absolute paths / URLs
      :effect_class,  # Symbol  — the descriptor's EXISTING enum (:read_only |
                      #           :bounded | :reconcilable, descriptor.rb:27,52),
                      #           carried as information. It is reconciliation
                      #           semantics, NOT the approval tier: tier assignment
                      #           is policy data (§2.1 tool_tiers). The evaluator
                      #           enforces one structural rule over the data: a
                      #           :read_only descriptor always lands in tier read.
      :session_id     # String
    )

    Decision = Data.define(
      :id,               # String — decision handle, DERIVED from the request digest
                         # + policy_rev (repo rule: identity and dedup on the
                         # request, never the answer); identical pending asks dedup.
                         # An :ask resolves against this.
      :verdict,          # :allow | :ask | :deny
      :reason,           # String — human-legible, names the rule/tier/grant that fired
      :rule_id,          # String — machine handle for the decision log (study P5/P6)
      :tier,             # Symbol — the tier that produced the verdict
      :grant_offer,      # nil | GrantOffer — scopes the human may grant
      :required_evidence, # Symbol — :chat_bound | :filesystem_operator, for an :ask
                         # (replaces the hardcoded constant, audit §5.3); nil for
                         # :allow/:deny. A plain Symbol, NOT Comms::AuthorityEvidence:
                         # the gem depends only on tamoz-core; comms maps the symbol
                         # onto its lattice at the boundary (non-members raise there,
                         # as today — and load-time validation (§1.5, §2.1) makes a
                         # typo fail activation long before that).
      :policy_rev        # String — digest of the policy document that decided
    )

    GrantOffer = Data.define(:scopes, :key)
    # scopes: Array<Symbol>, subset of [:once, :session] — policy-chosen, never
    #         caller-chosen.
    # key:    structural grant key (see §2.3), computed by the engine, never from
    #         the answer and never from raw argv wholesale.

    class Engine
      def initialize(policy:, grant_store:, decision_log:, clock:)
      # policy:       PolicyDocument (already loaded + validated)
      # grant_store:  GrantStore port (§2.3)
      # decision_log: DecisionLog port (§2.5)
      # clock:        injectable — wall-clock enters only through explicit expiry
      #               fields (study P4).

      def build_request(tool:, argv:, targets:, effect_class:, session_id:) # -> Request
      # The one request-construction seam: realpath-canonicalizes targets and fills
      # :verb from the policy's tool_tiers entry (absent → :unknown → fallback tier).

      def decide(request)    # -> Decision
      def resolve(decision_id:, answer:, scope:) # -> Grant | nil (idempotent, §1.3)
      def simulate(request)  # -> Decision — same evaluation, no log append, no grants
      def reload(document)   # -> String (new policy_rev)
    end
  end
end
```

### 1.3 Error semantics

- `decide` **never raises for policy reasons**. Unknown tool, unknown effect class,
  unmatched request, expired grant → fail closed to `:ask` (or `:deny` where a rule
  says so). A gap interrupts; it does not block and it never silently allows
  (study P1/F5).
- `reload` raises `Tamoz::Approval::InvalidPolicyError` on any parse/schema/simulation
  failure and the **previous policy stays live** — a broken document can never take the
  system down (study §4.3, the sudo `visudo` pattern; the end-to-end delivery story
  is §1.5).
- `resolve` is **idempotent under replay**. The kept worker path (audit §4 strength 2)
  recovers from a crash between resume and consume by reclaiming the fenced decision
  and re-applying it; that legitimate retry must dedup, not crash. So: re-resolving a
  `decision_id` with the *same* answer and scope returns the originally recorded
  grant; resolving an already-resolved id with a *different* answer or scope raises
  `Tamoz::Approval::ConflictingResolutionError`; an unknown or expired id raises
  `Tamoz::Approval::UnknownDecisionError`; a scope the `grant_offer` did not offer
  raises `Tamoz::Approval::InvalidScopeError`. A parked ask resolves against the
  decision that issued it (the stored `grant_offer`), never against the live policy —
  a reload mid-park changes nothing for it (§1.5).
- These errors descend from `Tamoz::Approval::Error < Tamoz::Core::Error`; callers
  rescue the base or let it crash — a policy-component bug is not fail-closed
  *retryable*, it is a defect. (Replay with identical inputs is not a bug and never
  reaches this path.)
- `ApprovalDeniedError` (Pipeline B's denial-as-exception, audit §1.3) is **deleted**.
  Denial is data (`Decision#verdict == :deny`), not control flow.

### 1.4 Shared answer vocabulary

`Tamoz::Approval::Answer.parse(string) -> :approve | :deny | nil` is the one
normalizer. The durable CLI (`y/yes/a/approve`, `n/no/d/deny`) and the one-shot CLI
(`y/yes` only) currently speak two dialects (audit §5.9); both CLIs now call
`Answer.parse`, and the one-shot path inherits the full vocabulary. Scope choice is
not squeezed into the answer string: when an approved decision's `grant_offer`
includes `:session`, the interactive CLI asks one follow-up ("remember for this
session? [y/N]") and passes the result as `resolve`'s `scope:`; the channel
responders already carry scope in their payloads.

### 1.5 Wiring

The worker runtime builds one `Engine` at boot: it loads the policy document from the
path in run config (default: the gem's bundled `base.yaml`), selects the profile the
run/schedule names (default: `implement`), and injects the SQLite grant store and
decision log. The boot wiring also injects the valid evidence-level symbol set it
obtains from comms (plain symbols — the gem never imports comms), and the loader
validates the document's `evidence:` block against it at load: a typo'd evidence
level fails activation, not a mid-turn prompt build. The engine is passed into the
session effects and the one-shot runtime as a constructor dependency — no global, no
registry.

**Reload reaches running workers through the database, not a signal.** The operator
command (`tamoz approve --reload <path>`) loads and validates the document in the CLI
process first; only on success does it write `(policy_path, policy_rev)` to a
single-row `tamoz_approval_active_policy` table. The worker — which already polls
parked threads (weakness #8's kept cadence) — compares the persisted rev against its
engine's on each poll pass and at session start, and calls `engine.reload` from the
persisted path when they differ. A document that fails validation never reaches the
table, so a broken edit can never take live workers down (the `visudo` property, now
end-to-end). **In-flight semantics, pinned** (study §4.3): a session binds
`policy_rev` at start and keeps it until it ends; the engine retains a superseded
document only while a live session still references it, then drops it. Parked asks
resolve against their stored decision regardless (§1.3), and grants stay valid for
exactly the rev their session is bound to (§2.3) — reload is fail-closed for
everything new and invisible to everything parked.

---

## 2. Policy as data

### 2.1 Policy document format

One YAML file ships with the gem (`gems/tamoz-approval/policy/base.yaml`, packaged via
the gemspec `runtime_contracts` mechanism the repo already uses for JSON contracts),
plus one per profile (`policy/profiles/*.yaml`). A run may point at a different
document path. Every load computes a SHA-256 digest over the canonical form; that
digest is `policy_rev`, recorded in every decision.

```yaml
# policy/base.yaml
version: 1

# Tool -> tier assignment is DATA, keyed by tool id. This replaces audit §2.1
# rows 1-7 AND is the whole classification seam: moving a tool to a stricter tier
# is a YAML edit, not a descriptor change. The descriptor's existing effect_class
# enum (:read_only | :bounded | :reconcilable) is reconciliation semantics and
# stays untouched — no tamoz-core change, no per-tool redeclaration sweep. Tools
# absent from this map land in fallback_tier and ask.
tool_tiers:
  read_file:   { tier: read, verb: read }
  write_file:  { tier: workspace_write, verb: write }
  run_check:   { tier: local_execute, verb: execute, key_argv: [0] }
               # key_argv: argv positions folded into the grant key — argv[0] is
               # the check name, so approving one check never covers another.
  web_search:  { tier: network, verb: network }
  child_task:  { tier: local_execute, verb: execute, grant_scopes: [once] }
               # once-only: today's always-ask (child_task_dispatcher.rb:117) is
               # preserved for real — a session grant can never end it.
fallback_tier: { tier: local_execute, verb: unknown, grant_scopes: [once] }
               # unknown-effects MCP tools land here — ONCE-ONLY. Their arguments
               # are opaque model-supplied JSON; a session grant keyed without
               # argv would be session-wide authority over a dual-use tool (study
               # F4/§6.5). The "no session grants for opaque argv" bar is enforced
               # here, per classification — not only per named tier.

tiers:
  read:             { default: allow }
  workspace_write:  { default: allow }
  local_execute:    { default: ask,  grant_scopes: [once, session] }
  network:          { default: ask,  grant_scopes: [once] }
  external_publish: { default: ask,  grant_scopes: [once] }
  destructive:      { default: ask,  grant_scopes: [once] }

# Structural grant-key fields per tier (study open question 1, answered §4.2).
# A session grant is issued only when every declared field is present and
# non-degenerate: a request with no path targets has no target_root and degrades
# to once-only.
grant_keys:
  local_execute: [verb, tool, target_root, key_argv]

# Rules. Matchable Request fields — the closed list, so the data/code boundary of
# future policies is knowable before build: verb, tool, target_glob (on
# realpath'd targets), argv_prefix (Array<String> prefix match), argv_flag
# (String membership). DENY RULES ALWAYS EVALUATE FIRST, regardless of document
# order — a broad allow appended above credential-files must not silently void it
# (sudoers opacity lesson, study §6.1/§6.3). Ask/allow rules keep
# first-match-wins among themselves.
rules:
  - id: credential-files
    match: { verb: read, target_glob: "**/.env*" }
    verdict: deny
    reason: "credential files are outside the agent's read scope"
  - id: force-push
    match: { argv_prefix: ["git", "push"], argv_flag: "--force" }
    verdict: ask
    reason: "force-push rewrites published history"

ask:
  timeout_s: 900
  on_timeout: park        # park | deny — semantics pinned below

evidence:                  # replaces Comms::ApprovalPolicy's constant (audit §5.3)
  approve: filesystem_operator
  deny: chat_bound
  # validated at load against the symbol set injected by the boot wiring (§1.5)

# Canned expectations — data, not Ruby (B9): run at load, digest-pinned with the
# rest of the document. Any failure rejects the document.
simulations:
  - { request: { tool: read_file, verb: read, targets: ["**/.env"] }, expect: deny }
  - { request: { tool: "mcp:unknown:anything" }, expect: ask }

# policy/profiles/review.yaml — a profile is tier-default overrides + ask behavior,
# composed over the base document. Nothing else.
profile:
  name: review
  tier_defaults: { workspace_write: ask, local_execute: ask }

# policy/profiles/unattended.yaml
profile:
  name: unattended
  tier_defaults: { workspace_write: ask, local_execute: ask }
  on_timeout: deny        # nobody is watching: expiry resolves to deny, not a park
```

Validation at load (before activation, study §4.3): schema check; every `tool_tiers`
tier is declared; every rule uses only the closed matcher list and a verdict ∈
{allow, ask, deny}; `grant_scopes` for network/publish/destructive, the fallback
tier, and `child_task` must not include `session`; the `evidence:` symbols are
members of the injected set (§1.5); the document's own `simulations:` block runs
against it and any failure rejects the document.

**Timeout semantics, pinned.** `timeout_s` bounds the *channel prompt*: after it, the
prompt expires unanswered exactly as today (the fail-closed transport expiry is
unchanged). `on_timeout` is enforced by the **worker** — the same poll pass that
watches parked threads also checks pending asks' deadlines and applies the outcome,
so the enforcer is an existing component with a clock, not new machinery. `park`
means: the channel prompt lapses, the turn stays parked, and the decision remains
resolvable through the operator CLI (`tamoz approve <id>` calls `resolve` against the
decision record, which does not expire with the channel prompt) — an attended run
whose human walks away is recoverable, not bricked. `deny` (the unattended default)
resolves the ask to a structured denial, so the turn ends with a stated outcome. A
human answer and a timeout landing together is decided by `resolve`'s idempotence
(§1.3): whichever lands first wins.

### 2.2 Profile mechanism

A session binds one profile by name at start (CLI flag / worker config / schedule
spec), and may be explicitly re-bound mid-session by an operator-addressed mode switch
(§2.6) — the one exception to §1.5's in-flight rev stability. Profile resolution = base
document + profile overlay, computed once at load, digest-pinned. The name resolves by pure path lookup — `<document_dir>/profiles/
<name>.yaml`, or the gem's bundled `policy/profiles/` for the bundled base document —
so a custom document path pairs with the overlays beside it, unknown names fail at
load, and adding a profile is dropping a file, never a Ruby edit. The old profile
keys `tools.approval_required` and `unattended.*`
(audit §3.5, §6.2 `profile/fields.rb:87-97`) are **deleted** — the set they expressed
is now `tier_defaults` in data — and an operator-authored profile file still carrying
those keys fails validation loudly at load (the repo ships none; silence would be the
bug). `tools.allowed` stays in the agent profile: "may the
tool run at all" is capability config, not approval policy, and the engine only ever
sees tools the runtime already allows.

### 2.3 Grant store

Port defined in the gem; SQLite implementation stays in `tamoz-sqlite` (new table
`tamoz_approval_grants`, new migration ordinal — §5). A grant:
`(key, scope, session_id, policy_rev, created_at_ms, expires_at_ms)`.

- **Key grammar** (study open question 1): the policy declares which request fields
  compose the key per tier — for `local_execute`, `[verb, tool, target_root,
  key_argv]`, where `target_root` is the canonicalized workspace-relative root and
  `key_argv` is the per-tool argv component declared in `tool_tiers` (argv[0], the
  check name, for `run_check`) — never raw argv wholesale (study F4: keys are
  patterns the policy chose, not request hashes). **A session grant is issued only
  when every declared key field is present and non-degenerate**: a request with no
  path targets has no `target_root`, so it degrades to `:once`. The fallback tier,
  `child_task`, and the network/publish/destructive tiers are schema-barred from
  `:session` entirely (study §6.5's over-bundling lesson, applied to this grammar):
  an opaque-argv tool — unknown-effects MCP, model-supplied JSON arguments — can
  never turn one approval into session-wide authority, and R1/R2 get a human every
  time.
- **Scopes:** `:once` (the existing digest-bound single-use decision — kept exactly
  as-is) and `:session` (dies with the session).
- **Reload, no revalidation sweep:** grant lookup matches on `(key, session_id,
  policy_rev)` where `policy_rev` is the *session's bound* rev (§1.5). A reloaded
  policy binds new sessions to the new rev, so stale grants simply never match —
  fail closed at read time, no grandfathering, and no machinery that re-derives
  "would the new policy have issued this" from an opaque key string.
- **Session end:** grant rows are scoped by `session_id` on the one shared store
  (per-session isolation is the `session_id` match, not a store per session) and are
  deleted by the existing session-teardown path; `expires_at_ms` is set from the
  session's own deadline where one exists, so rows cannot outlive their session even
  if teardown is skipped. The decision log is append-only and retained with the
  database it lives in — accepted, same discipline as the existing journal.
- An in-memory implementation ships in the gem for tests and the one-shot runtime;
  the durable session uses the SQLite one. Same port, no behavior fork.

### 2.4 Pipeline convergence

**Pipeline A (durable session).** `session_steps.rb:69` stops asking
`effects.approval_required?(tool)` and instead calls `engine.build_request` on the
prepared step and then `engine.decide`. `:allow` → straight to `step_execute`. `:ask`
→ the **existing** interrupt path, unchanged: the descriptor now carries the
`Decision` (id, reason, grant_offer, required_evidence), the turn parks, and a human
answers through any of the three existing responders. **All three responders funnel
through `engine.resolve(decision_id:, answer:, scope:)`** — the worker's resume path
for channel answers, and the interactive CLI in-process *before* `session.resume` —
so session grants and the human-answer log record exist in the primary interactive
UX too, not only for channel answers. `resolve` mints any grant and appends to the
decision log. `:deny` → a **structured tool result** ("denied: <reason>, rule
<rule_id>") fed back to the model; the turn continues (fixes audit §5.6). The
repeated-action guard (`session_plan_outcomes.rb:115-127`) stays — it terminates true
replan loops, and a denied action the model insists on repeating is exactly a loop.

**Pipeline B (one-shot runtime).** Converges and shrinks to a call site:
`runtime.rb:582-605` is replaced by `engine.build_request` + `engine.decide` with the
in-memory grant store; `:ask` prompts through `Answer.parse`; `:deny` returns the
same structured tool result as Pipeline A. The callback-plus-exception contract and
`ApprovalDeniedError` are deleted (audit lesson: "don't add a fourth pipeline…
converge, not preserve").

**Pipeline C (stream relay) — argued non-convergence.** The relay never gates a local
tool call: the stream classifies risk and owns authority; tamoz delivers prompts and
returns signed answers (audit §0, §1.3). There is no "may I do X?" to route through
`decide` — forcing one would invent a decision the design does not have. The relay's
guards (audit §2.4: receipt state, relay≠approver, fail-closed expiry, single-use
nonce) are protocol invariants of `io.agenticstream.approval.*`, not tunable policy,
so they stay in `tamoz-stream` — preserving that gem's deliberate independence from
comms (audit §6.3). Two things do change: the receipt store gains an `expires_at`
field with a TTL (part of the §5.4 fix) injected as a **plain integer from run
config at subscriber boot** — `tamoz-stream` never loads policy documents, exactly
like the relay's other injected ports — and the gem — not
`bin/tamoz-stream-subscriber`'s dynamic require — documents the port shape the relay
injects. The gem absorbs the *pattern* (port injection, audit §4 strength 6), not the
file.

### 2.5 Decision log

Port defined in the gem; append-only SQLite implementation (new table
`tamoz_approval_decisions`). One record per `decide`, plus the human's answer and
chosen scope recorded by `resolve`: `(decision_id, tool, verb, tier, rule_id,
verdict, grant scope, actor evidence, policy_rev, argv digest, target digests,
timestamps)`. **Structural fields are cleartext; arguments are digests, never raw**
(study open question 6): tamoz already digest-binds prompts (`arguments_digest`,
`preview_digest`, audit §3.4), and keeping `tool`/`verb`/`tier`/`rule_id` readable
makes "why was this asked/denied" answerable from the database alone without
exposing a single argument. Appends are idempotent on `decision_id`, so a graph-node
retry never double-writes (§8). This log is in
*addition* to the existing graph-state journaling (`session.rb:427`), which stays.

### 2.6 Mid-session mode switch

Profiles are also the redesign's answer to Claude Code's permission *modes*: a mode is
a named `tier_defaults` preset, so the mode ladder is expressed as profiles —
`plan` (reads allow, everything else deny), `review` (workspace_write/local_execute
ask — "manual"), `implement` (the default — "accept edits"), `auto`
(workspace_write/local_execute allow), and a bounded `bypass` (all tiers allow, but
deny **rules** and unknown-tool fail-closed still hold — a profile overrides tier
defaults, never rules, §2.2). Adding a mode is dropping a profile file.

The one capability profiles-at-start do not give is Claude Code's live mode cycling.
This ADR adds it, as a **deliberate, bounded exception** to the in-flight rev binding
of §1.5 — not a general relaxation of it.

**Scope.** A mode switch changes only the **approval engine's active policy profile**
for one session (`tier_defaults` + `on_timeout`). It does **not** touch the session's
*agent* profile (`Session#initialize`'s `profile_roles`, `profile_budgets`,
`profile_narrowed`, allowed tools) or its graph version/nodes — those stay bound at
construction. Permission behavior changes; capability and budget do not.

**The rule that keeps reload and switch distinct.** §1.5 makes a global reload
*invisible* to in-flight sessions on purpose (stability). A mode switch is the opposite
and the only exception: an **explicit, operator-addressed, per-session** rebind that
applies immediately to *this* session and *only* this session.

- A **global reload** (`tamoz approve --reload`) still never changes a running
  session's bound rev.
- A **switch** (`tamoz approve --mode <name> --thread <id>`) rebinds one session's
  active `(profile, policy_rev)` and never leaks to any other session.

**Delivery reuses proven machinery, no new runtime.** The switch is a durable
per-thread control message on the **existing request inbox** the worker already drains
each `poll_once` — the same channel as `submit_cancel` / `submit_follow_up`
(`cli_session_commands.rb`). The worker's poll pass (already gaining reload pickup,
§1.5) applies a pending switch at a durable boundary and rebinds the session's rev; the
interactive one-shot engine (in-memory) swaps its active document directly. Restart
safety is the inbox's existing property.

**Three pinned semantics** (the decisions this exception forces):

1. **Applies to the next decision only.** A switch never re-decides an in-flight step
   and never reverses an already-approved or already-executed effect. Approval is a
   checkpoint, not a boundary (§4.1 deviation 3); a switch moves the checkpoint for
   future calls, nothing retroactive.
2. **Tightening drops stale grants automatically.** The switch changes the session's
   bound `policy_rev`; grant lookup keys on that rev (§2.3), so grants minted under the
   old mode simply stop matching — fail-closed, no sweep. Loosening issues new grants
   going forward as normal.
3. **A parked ask is unaffected.** It resolves against its **issuing decision**'s
   stored `grant_offer` (§1.3), exactly as under a reload — a switch mid-park changes
   nothing for the parked ask; the new mode governs the *next* decision.

**Audit.** The switch is recorded in the decision log (a `mode_switch` record: actor,
thread, from-rev, to-rev, timestamp), so "who changed the mode, when, to what" is
answerable from the database alone (§2.5 discipline).

---

## 3. Weakness mapping (audit §5, all 11)

| # | Weakness | Disposition |
|---|---|---|
| 1 | Three mechanisms, one word | **Fixed.** A and B converge on `Engine#decide` with identical verdict semantics (denial is a structured result in both); C is argued out of scope as a relay (§2.4). One `Decision` type exists. |
| 2 | No single place answers "needs approval?" | **Fixed.** Classification is the `tool_tiers` map + rules in one YAML document; the six runtime sites become one call, and reclassifying a tool is a data edit too. The `read_only ⇒ read tier` invariant is enforced by the evaluator itself, over the data (§7, strength 1). |
| 3 | Evidence policy is a hardcoded constant | **Fixed.** `evidence:` block in policy data, validated at load against the injected symbol set (§1.5); `Comms::ApprovalPolicy` deleted; prompts pin `decision.required_evidence`. Telegram approve becomes a data edit, not a Ruby change. |
| 4 | No timeout semantics; agent blocks forever | **Fixed.** `ask.on_timeout: park\|deny` per document/profile, with pinned semantics and a named enforcer — the worker's existing poll pass (§2.1). Unattended ships `deny`; attended `park` stays answerable via the operator CLI instead of bricking. Stream receipts gain `expires_at` + TTL (§2.4). |
| 5 | Fail-closed + no scoped grants = maximal interruption | **Fixed.** Grant ladder (`once`/`session`) via `resolve` + grant store (§2.3) with argv-aware keys and opaque-argv tiers barred from `:session`; per-tier autonomy defaults mean reads and workspace writes stop asking at all. `--all --i-understand-approve-all` is deleted — the profile system is its principled replacement. |
| 6 | Denial is terminal and silent | **Fixed.** `:deny` returns a structured tool result with reason and rule_id; the turn continues and the model can course-correct. |
| 7 | Policy entangled with mechanism across five gems | **Fixed.** One gem owns policy; the dispatcher-routed `approval_required?` chain is deleted; the remaining cross-gem pieces are transport (§2.4) behind ports. |
| 8 | Resume is polling-based | **Not fixed — argued.** The decision write and the worker are separate processes; SQLite has no listen/notify, and a cross-process push channel is machinery without a second caller. Human answer latency (seconds–minutes) dwarfs the poll cadence, and polling is crash-safe by construction. The same poll pass now also carries reload pickup and timeout enforcement (§1.5, §2.1), so the cadence earns three jobs. Accepted, documented here as the standing trade. |
| 9 | Two UIs, divergent vocabularies | **Fixed.** `Answer.parse` (§1.4) is the single normalizer; both CLIs use it. |
| 10 | Dead `approval_policy` hash in scheduler | **Fixed by deletion.** The informational hash and the CLI hardcode (`cli_schedule_commands.rb:92`) are removed; a schedule instead names an approval `profile` like any other run. |
| 11 | Prompt activation coupled to delivery plumbing | **Kept, narrowed.** Activation-after-receipt is a delivery-correctness property (a callback must never resolve against a prompt the human couldn't have seen) — it stays in comms. What *moves* is the policy embedded in it: required evidence now comes from the `Decision`, so the plumbing carries policy output instead of consulting a policy constant. |

---

## 4. Study alignment

### 4.1 The §8 recommendation, applied

The study recommends a three-layer stack — rules evaluator (3.1) under tier mapping
(3.2) under profiles (3.4) — plus grant ladder, decision log, taint flags, and a
sandbox floor, with OPA/Cedar deliberately deferred.

**Adopted as recommended:** the evaluator (ordered rules with deny-first evaluation,
ask fallthrough); tiers as the vocabulary rules and profiles speak in; profiles as
the only user-facing surface; the grant ladder with high tiers — and opaque-argv
classifications — barred from durable grants; the append-only decision log with
`policy_rev`; validate-before-activate reload with fail-closed grant scoping; the
engine-shaped interface that keeps OPA/Cedar pluggable later.

**Deviations, each justified:**

1. **No taint flags in v1** (study §8.1 cross-cutting, open question 2). Tamoz has no
   taint mechanism today, no request carries the inputs, and the study itself calls
   approximate taint "the least-solved problem" (F7). Building conservative
   once-tainted-for-session flags without a consumer violates the repo's
   no-rare-cases rule. The mitigation that matters in the meantime — network,
   publish, and opaque-argv tools can never hold session grants — is adopted, so the
   lethal-trifecta conjunction cannot be granted away in one click even untracked.
   The `Request` shape has room for taint fields when a real caller appears.
2. **No plan-level batching** (study §5). The durable graph asks per step; batching
   requires plan-ahead classification UI that does not exist. Session grants capture
   most of the same fatigue win with zero new machinery.
3. **No sandbox floor in this ADR** (study P7/§6.2). Correct — and out of scope:
   this redesign isolates the *policy* layer. The ADR states plainly that approvals
   remain a checkpoint, not a boundary, and no design element here claims enforcement.
4. **No async continue-while-pending** (study open question 5). The durable session
   already parks the turn on `:ask` via the interrupt machinery; "provably
   independent work" has no definition in tamoz today and inventing one is exactly
   the elaborate sub-item the owner's simplicity directive warns against. Parked
   waiting plus `on_timeout` semantics is the v1 contract.
5. **No ask rate-limiting / prompt counter** (study F6). Accepted: session grants
   shrink prompt count between fatigues, and the repeated-action guard
   (`session_plan_outcomes.rb:115-127`) terminates a steered prompt flood as the
   replan loop it is. A visible counter is UI without a defined consumer in v1.
6. **No cost-bearing verb tier** (study R5). Spend is already owned by the
   descriptor's `request_budget` / `output_budget` fields and the agent budget
   runtime; the approval layer gates initiation, not cost. Duplicating budgets as a
   tier would be two owners for one rule.

### 4.2 The study's 8 open questions, answered for tamoz

1. **Grant-key grammar:** policy-declared per tier (§2.3): `local_execute` keys on
   `[verb, tool, target_root, key_argv]` with the argv component declared per tool in
   `tool_tiers`; degenerate keys degrade to `:once`; the fallback tier, `child_task`,
   and network/publish/destructive are `once`-only. Tuning against real session
   traces happens by editing data, not code.
2. **Taint lifecycle:** deferred (deviation 1 above). When adopted: flags live on
   `Request`, conservative once-tainted-for-session, cleared never.
3. **Tier assignment ownership:** the policy author, outright. Tier assignment is the
   `tool_tiers` map in data (§2.1); the descriptor's existing `effect_class` enum
   (`:read_only | :bounded | :reconcilable`, `descriptor.rb:27,52`) is reconciliation
   semantics and is *not* reused as the approval class — the first draft of this ADR
   claimed it was the classification field, and review caught it (§10, A1). Anything
   undeclared falls to `fallback_tier` and asks, so new tools fail closed
   automatically and "move a tool to a stricter tier" is a YAML edit with zero Ruby.
   The one structural rule the evaluator enforces over the data: a `:read_only`
   descriptor always lands in tier `read`.
4. **Multi-agent delegation:** a child task is a first-class tool in the policy
   (`tool: child_task`) — the base document maps it to `local_execute` with
   `grant_scopes: [once]`, so it asks every time: today's always-ask behavior is
   preserved as data instead of the hardcoded `approval_required? → true`
   (`child_task_dispatcher.rb:117`), and a session grant can never end it. Child
   sessions inherit the parent's profile but **grants do not transfer**: grant rows
   match on `session_id`, so a child session starts with an empty view of the shared
   store. Attenuation tokens (study 3.3) stay behind the interface, unbuilt.
5. **Async queue contract:** while an `:ask` pends, the turn parks (existing
   semantics); the only resolution paths are human answer (channel or operator CLI)
   or `on_timeout`. No independent-work continuation in v1.
6. **Log secrecy:** structural fields cleartext, arguments as digests only (§2.5).
   Retention and access control inherit the existing database's; no redaction
   mini-policy is built.
7. **Profile governance:** profiles are data files in the gem plus operator-supplied
   paths, resolved by pure path lookup (§2.2); tamoz is single-operator, so
   managed/org-pinned profiles are not a requirement. If team use appears, a managed
   profile is just another document path.
8. **Simulation surface:** `simulate` is engine-public and used by load-time
   validation (the document's own `simulations:` block) and tests; no user-facing
   "what could this profile do" command in v1 — the data file is short enough to read
   end-to-end, which is the real simulatability win.

---

## 5. Migration path

Ordered; each step leaves the tree green. "Deleted" means deleted — no shims, no
legacy-row handling (owner directive; databases may be reset).

1. **Create `gems/tamoz-approval`.** Gemspec via `gems/gemspec_helper.rb`
   (dependency: `tamoz-core` only). Values (`Request`, `Decision`, `GrantOffer`,
   `Answer`), the `build_request` canonicalizer (the one request-construction seam),
   `PolicyDocument` loader/validator (including the injected evidence symbol set and
   the document's `simulations:` block), `Engine`, grant-store and
   decision-log ports + in-memory implementations, `policy/base.yaml` and the three
   profiles capturing *current* behavior as data — `tool_tiers` carries today's
   tool→gate mapping, so **no `tamoz-core` descriptor change and no per-tool
   redeclaration sweep exist**: the descriptor's `effect_class` enum is untouched.
   New unit tests.
2. **New migration (next ordinal) in `tamoz-sqlite`:** `tamoz_approval_grants`,
   `tamoz_approval_decisions`, and the single-row `tamoz_approval_active_policy`;
   SQLite implementations of the two ports; `expires_at` added to stream approval
   receipt records. Ordinals stay monotonic; the existing prompt/decision transport
   tables are untouched (they are in use — §2.4).
3. **Pipeline A call sites (`tamoz-agent`).** `session_steps.rb:69` builds the
   `Request` via `engine.build_request` and calls `decide`; the `ask` path feeds the
   existing interrupt with the `Decision`; the deny path emits the structured tool
   result. The worker resume path (`worker.rb:398-425`) calls `resolve`, and the
   interactive CLI (`cli.rb:207,277`) calls `resolve` in-process before
   `session.resume`, with the scope follow-up prompt from §1.4. The worker's poll
   pass gains the two new jobs from §1.5/§2.1: policy-rev pickup → `engine.reload`,
   and pending-ask deadline checks → `on_timeout`. **Deleted:** the
   `session_effects.rb:291-292` → `capability_binding.rb:144-147` → dispatcher
   `approval_required?` chain — the full surface is **nine methods**
   (`session_effects.rb:291`; `capability_binding.rb:144,343,392`;
   `local_dispatcher.rb:51`; `toolbox.rb:105`; `child_task_dispatcher.rb:117`;
   `governed_browser_source.rb:35`; `mcp_capability_source.rb:129`, the last two
   keeping their `read_only?` predicate), inventoried and dispositioned in
   `07-evidence-index.md` §1; this list abbreviates it. `Toolbox#approval_required?` (`toolbox.rb:105`);
   `DEFAULT_APPROVAL_REQUIRED` (`tool_catalog.rb:28`); `worker_runtime.rb:864-866`'s
   union (replaced by the `unattended` profile); `child_task_dispatcher.rb:117`'s
   hardcoded `true`; the profile keys `tools.approval_required` / `unattended.*` and
   their validators (`profile/fields.rb`, `authority_validator.rb:115-124`,
   `tool_policy_normalizer.rb:119-133`) — operator-authored profile files still
   carrying those keys now fail validation loudly at load; `--all
   --i-understand-approve-all` (`cli.rb:472-480`). **Re-pointed:**
   `deliberation.rb:307-314` digests steps by the `Decision`'s rule/tier instead of
   the old `approval_required:` flag; `capability_binding.rb:203,285` keeps
   synthesizing descriptor metadata but no longer answers policy questions.
4. **Pipeline B call site.** `runtime.rb:582-605` shrinks to `build_request` +
   `decide`; `ApprovalDeniedError` (`errors.rb:46`) deleted; `cli.rb:853-858`
   (`approve_one_shot`) re-pointed at `Answer.parse`.
5. **Comms.** `approval_policy.rb` deleted; `approval_prompt.rb:85` pins
   `decision.required_evidence` instead of the constant; `comms_gateway.rb` and
   `outbox_delivery_sink.rb` read evidence from the decision. Comms exposes its
   lattice members as a plain symbol set for the boot wiring to inject into the
   policy loader (§1.5). The evidence lattice, binding checks, atomic consumption,
   and drainer activation are unchanged.
6. **Scheduler.** The informational `approval_policy` hash (`schedule.rb:35,305`) and
   its CLI hardcode deleted; schedule creation takes an optional profile name.
7. **Tests.** Repoint, don't soften: comms evidence/binding suites (they pin
   transport, unchanged semantics with data-driven evidence); agent decision-flow and
   unattended suites rewritten against the engine; `agent_runtime_test.rb` /
   `tool_error_recovery_test.rb` updated for denial-as-result; **`tamoz-evals`
   updated for denial-as-result** (`agent_smoke_corpus.rb` pins denied-approval
   behavior; the `07_denied_approval` suite cases assert it);
   `agent_capability_binding_test.rb:44` (pins the deleted `approval_required?`
   dispatch) deleted with the seam; `public_api_test.rb`,
   `docs/public-api.json`, `documentation/reference/public-api.md` updated
   (`ApprovalDeniedError` out, `Tamoz::Approval::*` in); the base document's
   `simulations:` block pins its invariants at every load, and the load-time
   validation suite pins the validator. `stream_invariants_test.rb`'s glob is
   untouched — no stream file moves.
8. **Docs.** ADR-049, `documentation/design/comms.md`, and
   `documentation/architecture/security-model.md` updated where they describe the
   constant policy and the six-site split.

After step 8, the audit §6.1 "things that would move" table resolves as: **moved into
the gem** — policy semantics, request canonicalization, grant store contract,
decision log contract, answer vocabulary; **deleted** — the classification chain, the
constant, Pipeline B's gate, the scheduler field; **shrunk to a call site** —
`session_steps.rb`, `runtime.rb`, `comms_gateway.rb`, `outbox_delivery_sink.rb`,
`worker.rb`; **stayed** — interrupt machinery, prompt/decision transport tables,
evidence lattice, relay, and the core descriptor (untouched: tier assignment is
data).

---

## 6. Simplicity budget

Every component earns its place in one line:

| Component | Why it exists |
|---|---|
| `Engine` | The one place "may I do X?" is answered — the entire point of the gem. |
| `build_request` factory | One canonicalizer for deny globs and grant keys; two call sites hand-rolling it is a deny-bypass and grant-fragmentation hazard. |
| `PolicyDocument` (loader/validator) | Policy is data; someone must parse, validate, and digest it before it can decide anything. |
| `Request` / `Decision` / `GrantOffer` values | The narrow interface made explicit; immutability is what makes decisions auditable. |
| Grant store port + 2 impls | Session grants are the fix for the owner's top pain (§5.5 of the audit); the port keeps durability out of the evaluator. |
| Decision log port | "Who approved this, under which policy" must be answerable after the fact (audit strength 5). |
| `Answer` normalizer | Ends the two-dialect UX split in 10 lines. |
| `policy/*.yaml` | The data the whole redesign exists to isolate. |

Not built (each would fail the one-line test today): taint tracking, plan-level
batching, capability tokens, OPA/Cedar, managed profiles, push wakeup, sandboxing,
grant revalidation sweeps (read-time `policy_rev` match replaces them), a new
descriptor field (the `tool_tiers` data map replaces it).

**Complexity comparison:**

| Metric | Before (audit) | After |
|---|---|---|
| Classification rule sites | 8, in 4 gems (§2.1) | 1 data map + 1 evaluator |
| Runtime gate decision points | 7 (§2.2) | 5 (Pipeline B gate and `--all` flag gone) |
| Responder/relay guards | 10 (§2.3–2.4) | 10 — unchanged, they are transport |
| **Total decision points** | **25** | **16, and all policy content in one file** |
| Gems touched by a policy change | 4 (tools, agent, comms, core descriptor) | 0 — YAML edit in `tamoz-approval`, including tool reclassification |
| Ruby constants carrying policy | 3 (`DEFAULT_APPROVAL_REQUIRED`, `required_evidence`, scheduler hardcode) | 0 |
| Denial semantics | 2 (state transition / exception) | 1 (structured result) |
| Answer vocabularies | 2 | 1 |

---

## 7. Strengths preserved (audit §4, all 7)

1. **Fail-closed classification + enforced structural invariant** — kept: tools
   absent from `tool_tiers` fall to `fallback_tier` → ask (nothing a server says can
   change this), and the `:read_only` guarantee is enforced by the evaluator itself —
   a `read_only` descriptor lands in tier `read` no matter what the data says. The
   descriptor's existing build-time invariant stays exactly where it is, and the
   descriptor itself is untouched.
2. **Digest-bound, single-use decisions** — kept: it *is* the `:once` grant scope and
   the entire `:ask` transport (fenced claims, derived resume ids, exact interrupt
   digest binding all unchanged — and `resolve` is idempotent so the fenced-claim
   crash-recovery replay dedups instead of crashing, §1.3).
3. **Authority evidence minted only by trusted paths** — kept: the closed lattice and
   self-minted CLI evidence are untouched; only the *required level* moves from a
   constant into data, pinned at prompt build as today and validated at load (§1.5).
4. **Atomic single-use prompt consumption** — kept: same store transaction, same CAS.
5. **Durable audit at both layers** — kept and extended: graph-state journaling
   unchanged; the new decision log adds `policy_rev`, `rule_id`, and cleartext
   structural fields so "why did the policy allow it" is finally answerable from the
   database alone.
6. **Pipeline C's port-injection shape** — kept as the gem's own architecture: stores
   and clock are injected ports; the gem depends only on `tamoz-core`.
7. **Invariants pinned by tests** — kept: existing suites repoint (§5 step 7); the
   document's `simulations:` block pins the data itself at every load, in production
   as well as in tests.

No strength is traded away.

---

## 8. Repo invariants

- **Effect journal:** `decide` reads mutable state (the grant store, the injected
  clock), so the honest argument is not purity but journaling. In Pipeline A the
  verdict is captured in the graph node's journaled state update (today's
  `approvals` slot, `session_steps.rb:128-140`), and human answers — the only
  external input — enter through the existing journaled interrupt/resume path. A
  replayed node re-reads its journaled verdict rather than re-deciding, and
  `EffectDispatcher.run` has nothing to wrap: the engine makes no model, tool, or
  network calls. Grants are projections of journaled answers plus the policy
  document, keyed on the *request structure*, never on any answer — exactly the
  "dedup on the request" rule. Two bounded divergences are stated plainly:
  decision-log appends happen inside the node and are idempotent on `decision_id`
  (a node retry never double-writes), and expiry/reload mutate grant state outside
  the journal, so a crash-replay across a reload can re-decide differently — always
  fail-closed (a re-prompt, never an unasked allow).
- **Domain knowledge is data:** all policy content — tier assignment, rules,
  profiles, evidence levels, timeouts, grant scopes, and the canned simulation
  expectations — lives in `policy/*.yaml`, digest-pinned per document
  (`policy_rev`). Zero policy literals in Ruby: the three existing constants are
  deleted, not moved into the gem as code.
- **No legacy shims:** old profile keys (which now fail validation loudly), the
  dispatcher classification chain, `Toolbox#approval_required?`,
  `ApprovalDeniedError`, the `--all` flag pair, and the scheduler hash are deleted in
  the same change; the new tables are new (no old rows exist to tolerate); migration
  ordinals advance monotonically and nothing checksum-pinned is edited.

---

## 9. Revision log

One self-critique pass, performed after the full draft above was written: each bar
item 1–8 was re-read against the draft, and every gap found was fixed in the body
before this log was written.

**What the critique found and what changed:**

1. **Bar 1 (interface) — dependency leak caught.** The draft typed
   `Decision#required_evidence` as `Comms::AuthorityEvidence`. That would make
   `tamoz-approval` depend on `tamoz-comms`, contradicting the stated dependency
   edge (`tamoz-approval` → `tamoz-core` only) and inverting the intended graph.
   Fixed: the decision carries a plain Symbol; comms maps it onto its closed lattice
   at the boundary, where non-members raise exactly as they do today.
2. **Bar 1 — Ruby correctness.** The `Decision` `Data.define` block was missing a
   comma after `:required_evidence`, and the `GrantOffer` comment said `scope:` where
   the definition declares `scopes:`. Both fixed; the interface section is meant to
   be paste-accurate Ruby.
3. **Bar 1 — wiring was unspecified.** The draft defined the engine but never said
   who builds it. Added §1.5: worker runtime constructs one engine at boot from the
   configured policy path + named profile, injected into session effects and the
   one-shot runtime as a constructor dependency.
4. **Bar 5 (migration) — two orphan call sites.** The draft's deletion list missed
   `deliberation.rb:307-314` (digests approval-required steps — now keyed on the
   `Decision`) and `agent_capability_binding_test.rb:44` (pins the deleted dispatch —
   deleted with the seam). Both added to steps 3 and 7.
5. **Bar 4 (open questions) — Q4 was non-committal.** "Whatever tier the document
   says" dodged the answer. Fixed: the base document maps `child_task` to
   `local_execute`, so always-ask is preserved as data.
6. **Bars 2, 3, 6, 7, 8 — re-checked, passed without change.** The three-pipeline
   convergence argument (including the argued non-convergence of C), the 11-row
   weakness table with two argued non-fixes (#8 polling, #11 delivery coupling), the
   before/after complexity table, the seven named strengths, and the three repo
   invariants each survived item-by-item re-reading against the source documents.

Rev 2 (2026-08-22): the three staff reviews are incorporated; every finding and its
resolution is mapped in §10. Note on rev-1 item 5: review S1 showed the
`local_execute` mapping alone did *not* preserve always-ask for `child_task` (the
tier offers session grants) — the fix is `grant_scopes: [once]` on the `child_task`
entry, and the claim is now true.

---

## 10. Review incorporation

Three staff reviews were incorporated in rev 2: `04-review-security.md` (S),
`04-review-simplicity.md` (P), `04-review-api.md` (A). All six MUST-FIX items are
fixed in the design; all thirteen SHOULD-FIX items are adopted (three of them were
raised independently by two or three reviews with the same fix, merged below); all
ten NITs are folded in; the reviews' "missed requirements" are addressed as
deviations or one-liners. Where reviewers offered competing fixes, the simpler one
was taken, per the repo rule:

- **A1's two options** (new descriptor field vs. tool→tier map in policy data): the
  data map was chosen — strictly less machinery (no core change, no redeclaration
  sweep) and it makes "move a tool to a stricter tier" a YAML edit, which is the
  owner's headline goal. Verified against `descriptor.rb:27,52`: the review's enum
  claim is correct.
- **P3's two options** (define `park` precisely vs. ship `deny` as the base default):
  `park` was defined precisely (channel prompt lapses, operator CLI still resolves) —
  the attended UX keeps its park-and-answer-later behavior while `unattended` ships
  `deny`.
- **Grant revalidation** (S4 and P2 converged): the read-time `policy_rev` match was
  adopted over any revalidation sweep — fail closed on reload for free, no
  re-derivation machinery.

| ID | Source | Tag | Resolution |
|---|---|---|---|
| S1 | security | MUST-FIX | **Fixed.** Fallback tier, `child_task`, and degenerate keys are schema-barred from `:session`; `local_execute` keys gain a per-tool argv component (`key_argv`) declared in `tool_tiers` — one `run_check` approval covers one check, MCP opaque-argv tools are once-only (§2.1, §2.3, §4.2 Q1/Q4). |
| S2 | security | MUST-FIX | **Fixed.** `resolve` is idempotent: replay with the same answer/scope returns the recorded grant; a conflicting resolution raises; the fenced-claim crash-recovery retry dedups instead of crashing (§1.3, §7 strength 2). |
| S3 | security | SHOULD-FIX | **Adopted (simpler option).** Deny rules always evaluate before ask/allow regardless of document order (§2.1) — chosen over loader overlap-detection, which is more machinery for the same hole. |
| S4 | security | SHOULD-FIX | **Adopted.** Grants match `(key, session_id, bound policy_rev)` at read time; parked asks resolve against their stored decision; in-flight sessions keep their bound rev until they end (§1.5, §2.3). |
| S5 | security | SHOULD-FIX | **Adopted.** All three responders funnel through `engine.resolve`; the interactive CLI calls it in-process before `session.resume`, with a scope follow-up prompt when `grant_offer` includes `:session` (§1.4, §2.4, §5 step 3). |
| S6 | security | SHOULD-FIX | **Adopted** (= P4 = A8, same fix). Boot wiring injects comms' evidence symbols as plain data; the loader validates the `evidence:` block at activation; dependency direction intact (§1.5, §2.1, §5 step 5). |
| S7 | security | NIT | **Folded.** `park` is no longer a brick: the channel prompt expires, the decision record does not; the operator CLI resolves it (§2.1). |
| S8 | security | NIT | **Folded.** `Decision#id` is derived from request digest + `policy_rev`; duplicate asks dedup (§1.2). |
| S9 | security | NIT | **Folded.** Targets are realpath-canonicalized; the symlink bypass of `**/.env*` is named and closed (§1.2). |
| S-M1 | security | missed req | **Addressed.** F6 (fatigue) added as deviation 5: repeated-action guard terminates floods; grants shrink prompt count (§4.1). |
| S-M2 | security | missed req | **Addressed.** R5 (cost spend) added as deviation 6: budgets live on the descriptor + agent budget runtime; approval gates initiation, not cost (§4.1). |
| S-M3 | security | missed req | **Addressed** (= P5). Simulation cases are a `simulations:` block inside the document — data, digest-pinned, run at load (§2.1). |
| S-M4 | security | missed req | **Addressed.** Interactive scope UX: follow-up prompt maps to `resolve`'s `scope:`; channel responders carry scope already (§1.4). |
| P1 | simplicity | MUST-FIX | **Fixed.** Reload delivery: the CLI validates then persists `(policy_path, policy_rev)` to `tamoz_approval_active_policy`; the worker's existing poll pass and session start pick up rev changes and call `engine.reload`; broken documents never reach the table (§1.5, §5 step 2). |
| P2 | simplicity | MUST-FIX | **Fixed.** Revalidation sweep deleted; read-time `policy_rev` match gives fail-closed-on-reload for free (§2.3). Session-grant lifetime specified: `session_id`-scoped rows deleted at session teardown, `expires_at_ms` from the session deadline. |
| P3 | simplicity | SHOULD-FIX | **Adopted (define-park option).** Park/deny semantics pinned, enforcer named (the worker's poll pass); weakness-#4 row reworded to match (§2.1, §3). |
| P4 | simplicity | SHOULD-FIX | **Adopted** — merged with S6/A8 (§1.5, §2.1). |
| P5 | simplicity | SHOULD-FIX | **Adopted** — merged with S-M3: `simulations:` block in the document (§2.1, §8). |
| P6 | simplicity | SHOULD-FIX | **Adopted** (= A5 second half). Stream receipt TTL is a plain integer from run config injected at subscriber boot; stream never loads policy documents (§2.4). |
| P7 | simplicity | SHOULD-FIX | **Adopted.** Migration: `tamoz-evals` (`agent_smoke_corpus.rb`, `07_denied_approval`) added to step 7; old profile keys fail validation loudly, stated in §2.2 and §5 step 3. |
| P8 | simplicity | NIT | **Folded** — merged with A3: §8 re-argued honestly (below). |
| P9 | simplicity | NIT | **Folded.** Retention: grant rows die with their session; the decision log is retained with its database, accepted explicitly (§2.3). |
| P10 | simplicity | NIT | **Folded.** Profile overlays resolve relative to the active document's directory; bundled base pairs with bundled `policy/profiles/` (§2.2). |
| P11 | simplicity | NIT | **Folded.** The log stores `tool`/`verb`/`tier`/`rule_id` cleartext; digests cover argv/targets only (§2.5). |
| P12 | simplicity | NIT | **Folded.** Per-session isolation is `session_id` scoping on the shared store; "fresh grant store" wording removed (§2.3, §4.2 Q4). |
| A1 | api | MUST-FIX | **Fixed.** The "existing field" claim was wrong — verified: `EFFECT_CLASSES = %i[read_only bounded reconcilable]` (`descriptor.rb:27,52`) is reconciliation semantics. Tier assignment moved to the `tool_tiers` data map; no core descriptor change, no redeclaration sweep; §4.2 Q3 corrected; the evaluator enforces `read_only ⇒ read` over the data (§1.2, §2.1, §5 step 1). |
| A2 | api | MUST-FIX | **Fixed.** The gem owns request construction: `Engine#build_request` is the single canonicalization seam (realpath targets; `verb` filled from `tool_tiers` data, absent → `:unknown`); both pipelines call it (§1.1, §1.2, §2.4, §5 steps 3–4). |
| A3 | api | SHOULD-FIX | **Adopted** (= P8). §8 re-argued: verdict journaled via node state, not engine purity; log appends idempotent on `decision_id`; expiry/reload divergence stated as bounded and fail-closed (§8). |
| A4 | api | SHOULD-FIX | **Adopted.** Closed matcher list enumerated — `verb`, `tool`, `target_glob`, `argv_prefix`, `argv_flag` — so argv-shaped policies (`git push --force`) are data, and the data/code boundary is knowable (§2.1). |
| A5 | api | SHOULD-FIX | **Adopted.** Consequences name the third edge (`tamoz-sqlite` → `tamoz-approval`); stream TTL is config injection, merged with P6 (ADR header, §2.4). |
| A6 | api | SHOULD-FIX | **Adopted.** Timeout enforcement owner named: the worker's existing poll pass applies `on_timeout`; the answer/timeout race is decided by `resolve` idempotence (§2.1). |
| A7 | api | NIT | **Folded.** `Request#profile` / `#unattended` dropped — the profile binds at engine/session construction and the audit trail carries `policy_rev`, so per-request copies only invited mismatch (§1.2). |
| A8 | api | NIT | **Folded** — merged with S6/P4 (§1.5). |
| A-M1 | api | missed req | **Addressed.** Profile-name resolution is pure path lookup, unknown names fail at load — adding a profile never touches Ruby (§2.2, §4.2 Q7). |

No known gaps remain against the bar or the reviews.
