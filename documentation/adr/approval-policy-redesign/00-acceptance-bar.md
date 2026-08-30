# 00 — Acceptance bar: `tamoz-approval` redesign

**Status:** authoritative — this is the contract every other document in this folder
is measured against.
**Date:** 2026-08-22

This file makes explicit the bar that `03-redesign-adr.md` §9 ("each bar item 1–8")
and `05-implementation-plan.md` §5 ("each bar item 1–5") already grade themselves
against. Until now that bar lived only in the reviewers' heads and the task contract;
writing it down makes the self-critique auditable and gives a coding agent a single
place to check "am I done, and did I regress anything."

It is the analogue of the OpenClaw study's `implementation-plan/00-implementation-bar.md`:
an end-state contract, a set of invariants that must never regress, a hard-zero list,
and a per-step definition of done — specialized to approval policy.

---

## 1. Purpose

The redesign is complete only when:

1. every approval/permission decision in tamoz is answered by **one** component
   (`Tamoz::Approval::Engine#decide`) reading **one** body of policy **data**;
2. changing that policy — including reclassifying a tool to a stricter tier — is a
   YAML edit in `gems/tamoz-approval`, touching zero Ruby in `tamoz-core` /
   `tamoz-agent`;
3. the change is delivered to running workers without weakening any safety property
   the audit (`02`) credited to the current system; and
4. every claim to (1)–(3) is backed by a test named in the plan, or by an explicit,
   dated verification task.

A feature wish-list, a partial extraction that leaves two policy owners, or a design
whose reload never reaches a live worker does **not** pass, regardless of how much
code moved.

## 2. Evidence standard

Every material claim in this folder is traceable to one of:

1. **source** — repository path + symbol/line (re-verified at implementation time;
   line numbers drift, see `07-evidence-index.md`);
2. **test/fixture** — the behavior it pins, named in `05-implementation-plan.md`;
3. **the policy document itself** — a `simulations:` case, digest-pinned, run at load;
4. **inference** — labelled, derived from cited evidence.

Confidence labels (`07-evidence-index.md`): **High** = source + focused test;
**Medium** = source/doc but the composed path is unverified; **Low** = inference
needing verification before it becomes a build premise.

"A method exists" is not "the method is on the live decision path." The current
`approval_required?` surface is a nine-method delegation chain
(`07-evidence-index.md`); a plan that deletes four of them and leaves five is not done.

## 3. End-state contract

Given a tool call prepared inside a durable session or the one-shot runtime, the system
must be able to:

1. **describe, not classify.** The dispatcher hands the engine a *description* —
   tool, exact argv, realpath-canonicalized targets, the descriptor's effect class —
   and nothing else; it never evaluates policy (kills the audit §5.7
   classifier-is-executor fusion).
2. **canonicalize once.** Exactly one seam (`Engine#build_request`) turns that
   description into the immutable `Request`; deny globs and grant keys rest on that
   one canonicalization, never on two call sites drifting apart.
3. **decide from data.** `decide` evaluates deny rules first (regardless of document
   order), then first-match ask/allow, then the tier default; it **never raises for a
   policy reason** — every gap fails closed to `:ask` (or a rule's `:deny`).
4. **grant with a scope the policy chose, keyed on request structure.** `:once`
   preserves the existing digest-bound single-use decision; `:session` dies with the
   session; opaque-argv classifications (fallback tier, `child_task`,
   network/publish/destructive) can never hold a `:session` grant.
5. **deny as data.** `:deny` is a structured tool result the model can react to; the
   turn continues. No `ApprovalDeniedError`.
6. **resolve idempotently.** A crash-recovery replay of the same answer+scope returns
   the recorded grant; a conflicting resolution raises; the human answer and chosen
   scope are logged — for channel *and* interactive-CLI answers alike.
7. **survive a bad policy edit.** A document that fails schema, matcher, scope, or its
   own `simulations:` block is rejected at load; the previously live policy keeps
   running (`visudo` property), end to end through the reload-delivery path.
8. **bind a rev for a session's life.** A session pins `policy_rev` at start; reload is
   fail-closed for everything new (stale grants never match) and invisible to
   everything already parked (a parked ask resolves against its issuing decision).

## 4. Global invariants (must never regress, in any step)

Each is credited to the audit (`02` §4) or forced by a review finding (`03` §10). A
step that touches a path guarding one of these adds or repoints a regression test for
it. These are the "strengths preserved" made testable.

1. **Fail-closed classification.** A tool absent from `tool_tiers` falls to
   `fallback_tier` → `:ask`. Nothing a tool server, workspace file, or model output
   says can change this. (`02` §4.1; `03` §7.1)
2. **`read_only ⇒ read` is structural.** A `:read_only` descriptor lands in tier
   `read` no matter what the data says — enforced by the evaluator, not by the data.
   The descriptor's build-time `effect_class` invariant is untouched. (`03` §1.2, §7.1)
3. **Opaque argv never becomes session authority.** Any request whose grant key is
   absent or degenerate — no path target, or a fallback/`child_task`/network/publish/
   destructive tier — degrades to `:once`. One approval of a dual-use MCP tool is
   never session-wide exfiltration authority. (`03` §2.3; `04-review-security` #1)
4. **Deny-first evaluation.** Deny rules evaluate before any ask/allow, regardless of
   document order; a broad appended `allow` can never silently void `credential-files`.
   (`03` §2.1; `04-review-security` #3)
5. **Single-use decisions preserved.** The digest-bound single-use decision *is* the
   `:once` scope: fenced claims, derived resume ids, and exact interrupt digest binding
   are unchanged, and `resolve` idempotence makes the crash-recovery replay dedup, not
   crash. (`02` §4.2; `03` §7.2; `04-review-security` #2)
6. **Evidence minted only by trusted paths.** The closed authority-evidence lattice
   and self-minted CLI evidence are untouched; only the *required level* moves from a
   Ruby constant into policy data, validated at load against the symbol set comms
   exposes. A typo'd evidence level fails activation, never a mid-turn prompt build.
   (`02` §4.3; `03` §7.3; `04-review-security` #6)
7. **Atomic single-use prompt consumption** — same store transaction, same CAS. (`03` §7.4)
8. **Durable audit at both layers.** Graph-state journaling is unchanged; the new
   append-only decision log adds `policy_rev`, `rule_id`, and cleartext structural
   fields (`tool`/`verb`/`tier`), arguments as digests only. (`02` §4.5; `03` §2.5, §7.5)
9. **Realpath before match.** Targets are symlink-resolved before any glob or grant
   key is computed; a workspace symlink at `~/.ssh` cannot bypass the `**/.env*` deny
   glob. (`03` §1.2; `04-review-security` #9)
10. **Effect-journal honesty.** In Pipeline A the verdict is captured by the graph
    node's journaled state update (today's `approvals` slot); a replayed node re-reads
    its journaled verdict rather than re-deciding. Decision-log appends are idempotent
    on `decision_id`. Expiry/reload mutate grant state outside the journal, so a
    crash-replay across a reload may re-decide — always fail-closed (a re-prompt, never
    an unasked allow). (`03` §8; `04-review-api` #3)
11. **Zero policy literals in Ruby.** Tier assignment, rules, evidence levels,
    timeouts, grant scopes, and the canned simulation expectations all live in
    `policy/*.yaml`, digest-pinned. The three existing constants
    (`DEFAULT_APPROVAL_REQUIRED`, comms' `required_evidence`, the scheduler hardcode)
    are deleted, not moved into the gem as code. (`03` §8)
12. **Dependency direction.** `tamoz-approval` depends only on `tamoz-core`. Comms
    exposes its evidence symbols as plain data for injection; the gem never imports
    comms. (`03` §1.5, §9.1)
13. **Mode switch is bounded and non-retroactive.** A mid-session mode switch is the
    *only* exception to in-flight rev stability, and stays bounded: it rebinds only one
    session's approval policy profile (not agent roles/budgets/tools/graph), applies to
    the next decision only (never re-decides or reverses an in-flight or completed
    effect), is `session_id`-scoped (never leaks to another session), and a global
    reload still never changes a switched session's chosen mode. (`03` §2.6)

## 5. Hard-zero failures

Any of these in a step's acceptance run fails the step outright — no partial credit,
no "fix in a later step." They are the invariants of §4 restated as the attacks they
forbid, plus the migration discipline the owner directive demands.

- an **unasked allow** on a tool the policy does not classify (invariant 1 breached);
- a **`:session` grant minted for an opaque-argv tool** (fallback, `child_task`,
  network, publish, destructive) — invariant 3 breached;
- an **`allow` shadowing a `deny`** because of document order — invariant 4 breached;
- **denial resurfacing as an exception** anywhere (`ApprovalDeniedError` rescued or
  raised) — end-state contract 5 breached;
- a **broken policy document reaching live workers** — a validation gap that lets a
  bad edit take the system down — end-state contract 7 breached;
- a **symlink bypass** of a deny glob or grant key — invariant 9 breached;
- an **evidence-level typo passing load** and raising mid-turn — invariant 6 breached;
- **two policy owners in the tree at once** — a commit where the engine decides *and*
  the old `approval_required?` chain still fires — end-state contract 1 breached;
- a **legacy shim**: an old table tolerated, an old profile key accepted-but-ignored,
  a read-time compatibility branch — violates the no-backcompat directive (`03` §8);
- a **mode switch re-deciding or reversing** an already-approved or already-executed
  effect, **applying twice** across a restart, or **leaking to another session** —
  invariant 13 breached (`03` §2.6).

## 6. Per-step definition of done

A step in `05-implementation-plan.md` is complete only when:

1. every file action in the step (created/modified/deleted) is done, or dropped with a
   reason recorded in the plan;
2. the step's named tests pass, and any suite it touches is **repointed, not
   softened** — an assertion deleted to make a suite green is a hard-zero-adjacent
   regression;
3. the global invariants (§4) and hard-zero list (§5) hold for every path the step
   touches, with a regression test for any invariant it moved;
4. quality gates (§7) pass;
5. the acceptance scenarios (`06-acceptance-scenarios.md`) the step is mapped to now
   pass, and none that previously passed regress;
6. a one-line evidence note is appended to the step: date, exact gate commands run,
   changed files or explicit no-change reason, and which claims rest on plumbing tests
   vs a real-provider/real-database run.

## 7. Quality gates (every step)

- `bundle exec rake ci` green;
- `bundle exec rubocop` clean for touched files;
- `enola check` — no new structural regression; a dependency cycle or unintended
  coupling introduced by the change is fixed before the step is presented, not after;
- `ci_full` in both locales for any step touching durability, migrations, packaging,
  or evidence (`05` steps 1, 5, 12 by their stated scope — record the exact
  invocation rather than relying on this list);
- comments: none by default, per `AGENTS.md`; name things so the code reads.

## 8. Definition of done (whole program)

The redesign is done when every step in `05-implementation-plan.md` meets §6, the
grep sweep in step 12 returns zero live references to the deleted surface
(`approval_required`, `ApprovalDeniedError`, `ApprovalPolicy`,
`--i-understand-approve-all`, `tools.approval_required`, `unattended_approval_required`)
outside this historical package and `CHANGELOG.md`, every acceptance scenario in
`06-acceptance-scenarios.md` passes, the `enola` delta is exactly the expected one gem
+ three edges with the tools→agent classification coupling gone and no new cycle, and
the final completion note states plainly which claims are proven by plumbing tests and
which by a real database / real-provider run.

Anything still unproven at that point is listed explicitly as an open verification
task — never hidden.
