# 03 — ADR: Isolate approval policy into `tamoz-approval`

**Status:** proposed
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
every *policy* decision behind one narrow interface: `decide / resolve / simulate /
reload`. All policy content — tier map, rules, profiles, evidence requirements,
timeout semantics, grant scopes — is **data** (YAML policy documents, content-addressed
by digest) loaded by the gem. Pipelines A and B converge on `Engine#decide`; Pipeline C
stays in `tamoz-stream` as a pure relay (it makes no local decision — argued in §2.4).
The proven *transport* machinery (interrupt/pause/resume, digest-bound single-use
decisions, evidence lattice, atomic prompt consumption) stays where it is and becomes
the answer-delivery layer underneath the gem. No legacy shims: the old profile keys,
the hardcoded constant, `ApprovalDeniedError`, and the scheduler's informational
`approval_policy` hash are deleted outright.

### Consequences

- A policy change is a YAML edit in `tamoz-approval` — zero Ruby changes, zero
  core/agent changes. A profile change is selecting a different named profile.
- Classification collapses from 8 rule sites in 4 gems to 1 data file + 1 evaluator.
- Denial becomes a structured tool result the model can react to; turns no longer die
  on the first "no".
- Session-scoped grants end the "tenth identical `run_check` prompts a tenth time"
  failure without opening the `--all` floodgate (which is deleted).
- Two gems gain a dependency edge on `tamoz-approval` (`tamoz-agent`, `tamoz-comms`);
  `tamoz-sqlite` implements two new store ports behind it. The dependency is
  one-directional: `tamoz-approval` depends only on `tamoz-core`.
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
`capability_binding.rb:144-147`): dispatchers now only *describe* the call (tool name,
argv, targets, effect class) and the engine decides.

### 1.2 Ruby interface

```ruby
module Tamoz
  module Approval
    # Immutable, canonicalized BEFORE the call. What was decided on is exactly
    # what executes (study F3): callers pass resolved argv and absolute targets,
    # never a shell string to be re-parsed downstream.
    Request = Data.define(
      :tool,          # String  — "run_check", "mcp:github:create_pr", "child_task"
      :verb,          # Symbol  — :read, :write, :execute, :network, :publish
      :argv,          # Array<String> — exact invocation
      :targets,       # Array<String> — canonicalized absolute paths / URLs
      :effect_class,  # Symbol  — declared by the capability descriptor (existing field);
                      #           :unknown_effects when undeclared (MCP heuristic, kept)
      :session_id,    # String
      :profile,       # String  — profile name bound to this session
      :unattended     # Boolean — derived from the profile, carried for the audit log
    )

    Decision = Data.define(
      :id,               # String — decision handle; an :ask resolves against this
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
                         # as today).
      :policy_rev        # String — digest of the policy document that decided
    )

    GrantOffer = Data.define(:scopes, :key)
    # scopes: Array<Symbol>, subset of [:once, :session] — policy-chosen, never
    #         caller-chosen.
    # key:    structural grant key (see §2.3), computed by the engine, never from
    #         the answer and never from raw argv.

    class Engine
      def initialize(policy:, grant_store:, decision_log:, clock:)
      # policy:       PolicyDocument (already loaded + validated)
      # grant_store:  GrantStore port (§2.3)
      # decision_log: DecisionLog port (§2.5)
      # clock:        injectable — the engine is a pure function of
      #               (request, policy, grant state); wall-clock enters only through
      #               explicit expiry fields (study P4).

      def decide(request)    # -> Decision
      def resolve(decision_id:, answer:, scope:) # -> Grant | nil
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
  system down (study §4.3, the sudo `visudo` pattern).
- `resolve` raises `Tamoz::Approval::UnknownDecisionError` for an unknown, expired, or
  already-resolved `decision_id`. Resolving with a scope the `grant_offer` did not
  offer raises `Tamoz::Approval::InvalidScopeError`.
- Both errors descend from `Tamoz::Approval::Error < Tamoz::Core::Error`; callers
  rescue the base or let it crash — a policy-component bug is not fail-closed
  *retryable*, it is a defect.
- `ApprovalDeniedError` (Pipeline B's denial-as-exception, audit §1.3) is **deleted**.
  Denial is data (`Decision#verdict == :deny`), not control flow.

### 1.4 Shared answer vocabulary

`Tamoz::Approval::Answer.parse(string) -> :approve | :deny | nil` is the one
normalizer. The durable CLI (`y/yes/a/approve`, `n/no/d/deny`) and the one-shot CLI
(`y/yes` only) currently speak two dialects (audit §5.9); both CLIs now call
`Answer.parse`, and the one-shot path inherits the full vocabulary.

### 1.5 Wiring

The worker runtime builds one `Engine` at boot: it loads the policy document from the
path in run config (default: the gem's bundled `base.yaml`), selects the profile the
run/schedule names (default: `implement`), and injects the SQLite grant store and
decision log. Sessions bind the profile at start; `reload` is an operator action
(`tamoz approve --reload <path>`-style admin command), never something a session does
to itself. The engine is passed into the session effects and the one-shot runtime as
a constructor dependency — no global, no registry.

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

# effect_class (declared by capability descriptors) -> tier. Single source of truth
# for classification; replaces audit §2.1 rows 1-7.
effect_tiers:
  read_only:        read
  workspace_write:  workspace_write
  local_execute:    local_execute
  network:          network
  external_publish: external_publish
  destructive:      destructive
fallback_tier: local_execute   # :unknown_effects lands here — fail closed (kept
                               # invariant: "nothing a server says can change this")

tiers:
  read:             { default: allow }
  workspace_write:  { default: allow }
  local_execute:    { default: ask,  grant_scopes: [once, session] }
  network:          { default: ask,  grant_scopes: [once] }
  external_publish: { default: ask,  grant_scopes: [once] }
  destructive:      { default: ask,  grant_scopes: [once] }

# Structural grant-key fields per tier (study open question 1, answered §4.2).
grant_keys:
  local_execute: [verb, tool, target_root]

# Ordered rules, first match wins, evaluated before tier defaults. Deny rules and
# taint-style conjunctions live here, in data.
rules:
  - id: credential-files
    match: { verb: read, target_glob: "**/.env*" }
    verdict: deny
    reason: "credential files are outside the agent's read scope"

ask:
  timeout_s: 900
  on_timeout: park        # park | deny — expiry now has a declared outcome

evidence:                  # replaces Comms::ApprovalPolicy's constant (audit §5.3)
  approve: filesystem_operator
  deny: chat_bound

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

Validation at load (before activation, study §4.3): schema check; every `effect_tiers`
value is a declared tier; every rule verdict ∈ {allow, ask, deny}; `grant_scopes` for
network/publish/destructive must not include `session`; a canned simulation suite runs
against the document ("`read .env` → deny", "unknown MCP tool → ask") and any failure
rejects the document.

### 2.2 Profile mechanism

A session binds one profile by name at start (CLI flag / worker config / schedule
spec). Profile resolution = base document + profile overlay, computed once at load,
digest-pinned. The old profile keys `tools.approval_required` and `unattended.*`
(audit §3.5, §6.2 `profile/fields.rb:87-97`) are **deleted** — the set they expressed
is now `tier_defaults` in data. `tools.allowed` stays in the agent profile: "may the
tool run at all" is capability config, not approval policy, and the engine only ever
sees tools the runtime already allows.

### 2.3 Grant store

Port defined in the gem; SQLite implementation stays in `tamoz-sqlite` (new table
`tamoz_approval_grants`, new migration ordinal — §5). A grant:
`(key, scope, session_id, policy_rev, created_at_ms, expires_at_ms)`.

- **Key grammar** (study open question 1): the policy declares which request fields
  compose the key per tier — for `local_execute`, `[verb, tool, target_root]` where
  `target_root` is the canonicalized workspace-relative root, not the full path and
  never raw argv (study F4: keys are patterns the policy chose, not request hashes).
- **Scopes:** `:once` (the existing digest-bound single-use decision — kept exactly
  as-is) and `:session` (dies with the session). Network, publish, and destructive
  tiers are schema-barred from `:session` (study §6.5's over-bundling lesson; R1/R2
  get a human every time).
- **Reload revalidation** (study §4.3): on `reload`, grants whose key the new policy
  would not have issued are dropped. Fail closed, no grandfathering.
- An in-memory implementation ships in the gem for tests and the one-shot runtime;
  the durable session uses the SQLite one. Same port, no behavior fork.

### 2.4 Pipeline convergence

**Pipeline A (durable session).** `session_steps.rb:69` stops asking
`effects.approval_required?(tool)` and instead builds a `Request` from the prepared
step and calls `engine.decide`. `:allow` → straight to `step_execute`. `:ask` → the
**existing** interrupt path, unchanged: the descriptor now carries the `Decision`
(id, reason, grant_offer, required_evidence), the turn parks, a human answers through
any of the three existing responders, and the worker's resume path calls
`engine.resolve(decision_id:, answer:, scope:)`, which mints any grant and appends to
the decision log. `:deny` → a **structured tool result** ("denied: <reason>, rule
<rule_id>") fed back to the model; the turn continues (fixes audit §5.6). The
repeated-action guard (`session_plan_outcomes.rb:115-127`) stays — it terminates true
replan loops, and a denied action the model insists on repeating is exactly a loop.

**Pipeline B (one-shot runtime).** Converges and shrinks to a call site:
`runtime.rb:582-605` is replaced by `engine.decide` with the in-memory grant store;
`:ask` prompts through `Answer.parse`; `:deny` returns the same structured tool
result as Pipeline A. The callback-plus-exception contract and `ApprovalDeniedError`
are deleted (audit lesson: "don't add a fourth pipeline… converge, not preserve").

**Pipeline C (stream relay) — argued non-convergence.** The relay never gates a local
tool call: the stream classifies risk and owns authority; tamoz delivers prompts and
returns signed answers (audit §0, §1.3). There is no "may I do X?" to route through
`decide` — forcing one would invent a decision the design does not have. The relay's
guards (audit §2.4: receipt state, relay≠approver, fail-closed expiry, single-use
nonce) are protocol invariants of `io.agenticstream.approval.*`, not tunable policy,
so they stay in `tamoz-stream` — preserving that gem's deliberate independence from
comms (audit §6.3). Two things do change: the receipt store gains an `expires_at`
field with a TTL from the policy document (part of the §5.4 fix), and the gem — not
`bin/tamoz-stream-subscriber`'s dynamic require — documents the port shape the relay
injects. The gem absorbs the *pattern* (port injection, audit §4 strength 6), not the
file.

### 2.5 Decision log

Port defined in the gem; append-only SQLite implementation (new table
`tamoz_approval_decisions`). One record per `decide`, plus the human's answer and
chosen scope recorded by `resolve`: `(decision_id, request digests, verdict, rule_id,
tier, grant scope, actor evidence, policy_rev, timestamps)`. **Arguments are stored as
digests, never raw** (study open question 6): tamoz already digest-binds prompts
(`arguments_digest`, `preview_digest`, audit §3.4); extending that discipline to the
log answers the secrecy tension without a redaction mini-language. This log is in
*addition* to the existing graph-state journaling (`session.rb:427`), which stays.

---

## 3. Weakness mapping (audit §5, all 11)

| # | Weakness | Disposition |
|---|---|---|
| 1 | Three mechanisms, one word | **Fixed.** A and B converge on `Engine#decide` with identical verdict semantics (denial is a structured result in both); C is argued out of scope as a relay (§2.4). One `Decision` type exists. |
| 2 | No single place answers "needs approval?" | **Fixed.** Classification is the `effect_tiers` map + rules in one YAML document; the six runtime sites become one call. The descriptor invariant (`read_only ⇒ no approval`) stays as a build-time check (§7, strength 1). |
| 3 | Evidence policy is a hardcoded constant | **Fixed.** `evidence:` block in policy data; `Comms::ApprovalPolicy` deleted; prompts pin `decision.required_evidence`. Telegram approve becomes a data edit, not a Ruby change. |
| 4 | No timeout semantics; agent blocks forever | **Fixed.** `ask.on_timeout: park\|deny` per document/profile (unattended ships `deny`). Stream receipts gain `expires_at` + TTL (§2.4). |
| 5 | Fail-closed + no scoped grants = maximal interruption | **Fixed.** Grant ladder (`once`/`session`) via `resolve` + grant store (§2.3); per-tier autonomy defaults mean reads and workspace writes stop asking at all. `--all --i-understand-approve-all` is deleted — the profile system is its principled replacement. |
| 6 | Denial is terminal and silent | **Fixed.** `:deny` returns a structured tool result with reason and rule_id; the turn continues and the model can course-correct. |
| 7 | Policy entangled with mechanism across five gems | **Fixed.** One gem owns policy; the dispatcher-routed `approval_required?` chain is deleted; the remaining cross-gem pieces are transport (§2.4) behind ports. |
| 8 | Resume is polling-based | **Not fixed — argued.** The decision write and the worker are separate processes; SQLite has no listen/notify, and a cross-process push channel is machinery without a second caller. Human answer latency (seconds–minutes) dwarfs the poll cadence, and polling is crash-safe by construction. Accepted, documented here as the standing trade. |
| 9 | Two UIs, divergent vocabularies | **Fixed.** `Answer.parse` (§1.4) is the single normalizer; both CLIs use it. |
| 10 | Dead `approval_policy` hash in scheduler | **Fixed by deletion.** The informational hash and the CLI hardcode (`cli_schedule_commands.rb:92`) are removed; a schedule instead names an approval `profile` like any other run. |
| 11 | Prompt activation coupled to delivery plumbing | **Kept, narrowed.** Activation-after-receipt is a delivery-correctness property (a callback must never resolve against a prompt the human couldn't have seen) — it stays in comms. What *moves* is the policy embedded in it: required evidence now comes from the `Decision`, so the plumbing carries policy output instead of consulting a policy constant. |

---

## 4. Study alignment

### 4.1 The §8 recommendation, applied

The study recommends a three-layer stack — rules evaluator (3.1) under tier mapping
(3.2) under profiles (3.4) — plus grant ladder, decision log, taint flags, and a
sandbox floor, with OPA/Cedar deliberately deferred.

**Adopted as recommended:** the evaluator (ordered first-match rules, deny/ask
fallthrough, pure function); tiers as the vocabulary rules and profiles speak in;
profiles as the only user-facing surface; the grant ladder with high tiers barred
from durable grants; the append-only decision log with `policy_rev`;
validate-before-activate reload with grant revalidation; the engine-shaped interface
that keeps OPA/Cedar pluggable later.

**Deviations, each justified:**

1. **No taint flags in v1** (study §8.1 cross-cutting, open question 2). Tamoz has no
   taint mechanism today, no request carries the inputs, and the study itself calls
   approximate taint "the least-solved problem" (F7). Building conservative
   once-tainted-for-session flags without a consumer violates the repo's
   no-rare-cases rule. The mitigation that matters in the meantime — network and
   publish tiers can never hold session grants — is adopted, so the lethal-trifecta
   conjunction cannot be granted away in one click even untracked. The `Request`
   shape has room for taint fields when a real caller appears.
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

### 4.2 The study's 8 open questions, answered for tamoz

1. **Grant-key grammar:** policy-declared per tier (§2.3): `local_execute` keys on
   `[verb, tool, target_root]`; network/publish/destructive are `once`-only so their
   grammar is the exact decision digest that already exists. Tuning against real
   session traces happens by editing data, not code.
2. **Taint lifecycle:** deferred (deviation 1 above). When adopted: flags live on
   `Request`, conservative once-tainted-for-session, cleared never.
3. **Tier assignment ownership:** both, with a single-source rule. The tool author
   declares `effect_class` in the capability descriptor (the existing field — the
   seam being extended); the policy author owns `effect_class → tier` in data;
   anything undeclared falls to `fallback_tier` and asks. New tools fail closed
   automatically, no conflict case exists because the map has one owner per side.
4. **Multi-agent delegation:** a child task is a first-class tool in the policy
   (`tool: child_task`) — the base document maps it to `local_execute`, so it asks by
   default, preserving today's always-ask behavior as data instead of the hardcoded
   `approval_required? → true` (`child_task_dispatcher.rb:117`). Child
   sessions inherit the parent's profile but **grants do not transfer**: each session
   gets a fresh grant store. Attenuation tokens (study 3.3) stay behind the interface,
   unbuilt.
5. **Async queue contract:** while an `:ask` pends, the turn parks (existing
   semantics); the only resolution paths are human answer or `on_timeout`. No
   independent-work continuation in v1.
6. **Log secrecy:** digests only, never raw arguments (§2.5). Retention and access
   control inherit the existing database's; no redaction mini-policy is built.
7. **Profile governance:** profiles are data files in the gem plus operator-supplied
   paths; tamoz is single-operator, so managed/org-pinned profiles are not a
   requirement. If team use appears, a managed profile is just another document path.
8. **Simulation surface:** `simulate` is engine-public and used by load-time
   validation and tests; no user-facing "what could this profile do" command in v1 —
   the data file is short enough to read end-to-end, which is the real
   simulatability win.

---

## 5. Migration path

Ordered; each step leaves the tree green. "Deleted" means deleted — no shims, no
legacy-row handling (owner directive; databases may be reset).

1. **Create `gems/tamoz-approval`.** Gemspec via `gems/gemspec_helper.rb`
   (dependency: `tamoz-core` only). Values (`Request`, `Decision`, `GrantOffer`,
   `Answer`), `PolicyDocument` loader/validator, `Engine`, grant-store and
   decision-log ports + in-memory implementations, `policy/base.yaml` and the three
   profiles capturing *current* behavior as data. New unit tests.
2. **New migration (next ordinal) in `tamoz-sqlite`:** `tamoz_approval_grants` and
   `tamoz_approval_decisions`; SQLite implementations of the two ports; `expires_at`
   added to stream approval receipt records. Ordinals stay monotonic; the existing
   prompt/decision transport tables are untouched (they are in use — §2.4).
3. **Pipeline A call sites (`tamoz-agent`).** `session_steps.rb:69` builds the
   `Request` and calls `decide`; the `ask` path feeds the existing interrupt with the
   `Decision`; the deny path emits the structured tool result. The worker resume path
   (`worker.rb:398-425`) calls `resolve`. **Deleted:** the
   `session_effects.rb:291-292` → `capability_binding.rb:144-147` → dispatcher
   `approval_required?` chain; `Toolbox#approval_required?` (`toolbox.rb:105`);
   `DEFAULT_APPROVAL_REQUIRED` (`tool_catalog.rb:28`); `worker_runtime.rb:864-866`'s
   union (replaced by the `unattended` profile); `child_task_dispatcher.rb:117`'s
   hardcoded `true`; the profile keys `tools.approval_required` / `unattended.*` and
   their validators (`profile/fields.rb`, `authority_validator.rb:115-124`,
   `tool_policy_normalizer.rb:119-133`); `--all --i-understand-approve-all`
   (`cli.rb:472-480`). **Re-pointed:** `deliberation.rb:307-314` digests steps by the
   `Decision`'s rule/tier instead of the old `approval_required:` flag;
   `capability_binding.rb:203,285` keeps synthesizing descriptor metadata but no
   longer answers policy questions.
4. **Pipeline B call site.** `runtime.rb:582-605` shrinks to an engine call;
   `ApprovalDeniedError` (`errors.rb:46`) deleted; `cli.rb:853-858`
   (`approve_one_shot`) re-pointed at `Answer.parse`.
5. **Comms.** `approval_policy.rb` deleted; `approval_prompt.rb:85` pins
   `decision.required_evidence` instead of the constant; `comms_gateway.rb` and
   `outbox_delivery_sink.rb` read evidence from the decision. The evidence lattice,
   binding checks, atomic consumption, and drainer activation are unchanged.
6. **Scheduler.** The informational `approval_policy` hash (`schedule.rb:35,305`) and
   its CLI hardcode deleted; schedule creation takes an optional profile name.
7. **Tests.** Repoint, don't soften: comms evidence/binding suites (they pin
   transport, unchanged semantics with data-driven evidence); agent decision-flow and
   unattended suites rewritten against the engine; `agent_runtime_test.rb` /
   `tool_error_recovery_test.rb` updated for denial-as-result;
   `agent_capability_binding_test.rb:44` (pins the deleted `approval_required?`
   dispatch) deleted with the seam; `public_api_test.rb`,
   `docs/public-api.json`, `documentation/reference/public-api.md` updated
   (`ApprovalDeniedError` out, `Tamoz::Approval::*` in); new load-time simulation
   suite pins the base document's invariants. `stream_invariants_test.rb`'s glob is
   untouched — no stream file moves.
8. **Docs.** ADR-049, `documentation/design/comms.md`, and
   `documentation/architecture/security-model.md` updated where they describe the
   constant policy and the six-site split.

After step 8, the audit §6.1 "things that would move" table resolves as: **moved into
the gem** — policy semantics, grant store contract, decision log contract, answer
vocabulary; **deleted** — the classification chain, the constant, Pipeline B's gate,
the scheduler field; **shrunk to a call site** — `session_steps.rb`, `runtime.rb`,
`comms_gateway.rb`, `outbox_delivery_sink.rb`, `worker.rb`; **stayed** — interrupt
machinery, prompt/decision transport tables, evidence lattice, relay.

---

## 6. Simplicity budget

Every component earns its place in one line:

| Component | Why it exists |
|---|---|
| `Engine` | The one place "may I do X?" is answered — the entire point of the gem. |
| `PolicyDocument` (loader/validator) | Policy is data; someone must parse, validate, and digest it before it can decide anything. |
| `Request` / `Decision` / `GrantOffer` values | The narrow interface made explicit; immutability is what makes decisions auditable. |
| Grant store port + 2 impls | Session grants are the fix for the owner's top pain (§5.5 of the audit); the port keeps durability out of the evaluator. |
| Decision log port | "Who approved this, under which policy" must be answerable after the fact (audit strength 5). |
| `Answer` normalizer | Ends the two-dialect UX split in 10 lines. |
| `policy/*.yaml` | The data the whole redesign exists to isolate. |

Not built (each would fail the one-line test today): taint tracking, plan-level
batching, capability tokens, OPA/Cedar, managed profiles, push wakeup, sandboxing.

**Complexity comparison:**

| Metric | Before (audit) | After |
|---|---|---|
| Classification rule sites | 8, in 4 gems (§2.1) | 1 data map + 1 evaluator |
| Runtime gate decision points | 7 (§2.2) | 5 (Pipeline B gate and `--all` flag gone) |
| Responder/relay guards | 10 (§2.3–2.4) | 10 — unchanged, they are transport |
| **Total decision points** | **25** | **16, and all policy content in one file** |
| Gems touched by a policy change | 4 (tools, agent, comms, core descriptor) | 0 — YAML edit in `tamoz-approval` |
| Ruby constants carrying policy | 3 (`DEFAULT_APPROVAL_REQUIRED`, `required_evidence`, scheduler hardcode) | 0 |
| Denial semantics | 2 (state transition / exception) | 1 (structured result) |
| Answer vocabularies | 2 | 1 |

---

## 7. Strengths preserved (audit §4, all 7)

1. **Fail-closed classification + enforced structural invariant** — kept: unknown
   effect classes fall to `fallback_tier` → ask; the descriptor's
   `read_only ⇒ :none` build-time invariant stays exactly where it is.
2. **Digest-bound, single-use decisions** — kept: it *is* the `:once` grant scope and
   the entire `:ask` transport (fenced claims, derived resume ids, exact interrupt
   digest binding all unchanged).
3. **Authority evidence minted only by trusted paths** — kept: the closed lattice and
   self-minted CLI evidence are untouched; only the *required level* moves from a
   constant into data, pinned at prompt build as today.
4. **Atomic single-use prompt consumption** — kept: same store transaction, same CAS.
5. **Durable audit at both layers** — kept and extended: graph-state journaling
   unchanged; the new decision log adds `policy_rev` and `rule_id` so "why did the
   policy allow it" is finally answerable.
6. **Pipeline C's port-injection shape** — kept as the gem's own architecture: stores
   and clock are injected ports; the gem depends only on `tamoz-core`.
7. **Invariants pinned by tests** — kept: existing suites repoint (§5 step 7); the
   load-time simulation suite adds a new pin around the data itself.

No strength is traded away.

---

## 8. Repo invariants

- **Effect journal:** the engine is deterministic and makes no model, tool, network,
  or clock-uncontrolled calls, so there is nothing to route through
  `EffectDispatcher.run` — the invariant applies to non-deterministic/external calls
  and the gem makes none. Human answers (the only external input) enter through the
  existing interrupt/resume path, which is already journaled in durable graph state;
  grants are deterministic projections of journaled answers plus the policy document.
  Grant keys are computed from the *request structure*, never from any answer —
  exactly the "dedup on the request" rule.
- **Domain knowledge is data:** all policy content — tier map, rules, profiles,
  evidence levels, timeouts, grant scopes — lives in `policy/*.yaml`, digest-pinned
  per document (`policy_rev`). Zero policy literals in Ruby: the three existing
  constants are deleted, not moved into the gem as code.
- **No legacy shims:** old profile keys, `Toolbox#approval_required?`, the dispatcher
  classification chain, `ApprovalDeniedError`, the `--all` flag pair, and the
  scheduler hash are deleted in the same change; the new tables are new (no old rows
  exist to tolerate); migration ordinals advance monotonically and nothing checksum-
  pinned is edited.

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

No known gaps remain against the bar.
