# 04 — Review: api-evolvability

Perspective: interface shape and Ruby ergonomics, gem boundary correctness, policy/profile
swappability, fit with repo conventions and seams, and the future-change scenarios
(add a policy / add a profile / change a tier) against the "never touch core/agent" goal.

## Verdict

With conditions. The overall shape is right and unusually well-matched to this repo:
a verdict-returning gem that never executes, immutable `Data.define` values, keyword-arg
`resolve`, fail-closed error semantics, visudo-style reload, ports with in-memory + SQLite
implementations (exactly the repo's existing store pattern), and a self-caught comms
dependency leak (§9.1) all point the right way. But the design's load-bearing input —
`Request#effect_class` — is claimed to be an existing descriptor field and is not: the
real enum is `read_only | bounded | reconcilable` with different semantics, so the
migration silently requires a tamoz-core descriptor change plus a per-tool redeclaration
sweep that §5 never lists. Until the classification input's provenance and the
request-construction seam are specified honestly, "policy change = YAML edit, zero Ruby"
is an aspiration, not a property of the written design.

## Findings

1. **[MUST-FIX] `effect_class` does not exist as claimed (§1.2, §2.1 `effect_tiers`,
   §4.2 Q3, §7 strength 1).** The ADR types `Request#effect_class` as "declared by the
   capability descriptor (existing field)" and keys the whole tier map on six classes
   (`read_only, workspace_write, local_execute, network, external_publish, destructive`).
   The real descriptor field is `EFFECT_CLASSES = %i[read_only bounded reconcilable]`
   (`gems/tamoz-core/lib/tamoz/core/capability/descriptor.rb:27,52`), where
   `bounded`/`reconcilable` carry reconciliation semantics with their own build-time
   invariant (`descriptor.rb:172`). None of the ADR's six classes exist anywhere, and §5
   contains no step that redeclares tools. Why it matters: the entire "classification
   collapses to one data map" claim (§6) depends on where tool → class assignment lives,
   and the future scenario "move a tool to a stricter tier" is precisely a core/tools
   change, not a YAML edit — the ADR should say so rather than imply otherwise. Fix:
   either add a distinct descriptor field (e.g. `risk_class`, enum owned by core, values
   consumed only by the gem's data map) or put the tool → class map in policy data keyed
   by tool id; then add the migration step (core descriptor change + redeclaration sweep
   across tamoz-tools and MCP sources, including the `:unknown_effects` path) and correct
   §4.2 Q3's "existing field" claim.

2. **[MUST-FIX] Request construction is an unowned, policy-relevant seam (§1.2, §2.3,
   §2.4).** `Request` demands pre-canonicalized `argv`, absolute `targets`, and a `verb`
   — "callers pass resolved argv and absolute targets" — but no component is named as the
   canonicalizer, and `verb`'s provenance is unspecified entirely (the §1.1 dispatcher
   description list omits it). Why it matters: deny rules (`target_glob: "**/.env*"`) and
   grant keys (`[verb, tool, target_root]`) are only as sound as the canonicalization; two
   call sites (session_steps, one-shot runtime) canonicalizing independently is a
   deny-bypass and grant-fragmentation hazard, and it re-scatters policy-adjacent logic
   back into tamoz-agent — the exact failure the redesign exists to kill. Fix: the gem
   owns a `Request.build`-style factory/canonicalizer (or the capability layer emits one
   canonical description through a single seam), and the ADR states who maps tool → verb.

3. **[SHOULD-FIX] The effect-journal argument in §8 is argued on the wrong premise.**
   "The engine is deterministic" is false as stated: `decide` reads the mutable grant
   store and the injected clock, so two calls with the same request can differ — by
   design (grants, expiry, reload). The correct argument exists and is stronger: in
   Pipeline A the verdict is captured by the graph node's journaled state update (today's
   `approvals` slot, `session_steps.rb:128-140`), and human answers already enter through
   the journaled interrupt path. Why it matters: the repo's journal rule is about
   non-deterministic inputs to durable nodes, and a reviewer applying it literally will
   (correctly) reject the current wording; also the decision-log append inside `decide`
   is an I/O write performed inside a graph node — duplicate appends on node retry need
   one sentence (idempotent-by-decision-id or benign append-only). Fix: re-argue §8 as
   "verdict journaled via node state; grant store is a projection of journaled answers;
   log appends are idempotent on `decision_id`".

4. **[SHOULD-FIX] The rule match DSL's ceiling is undefined (§2.1).** The only shown
   matcher is `{ verb:, target_glob: }`. The highest-value execute policies are
   argv-shaped (`git push --force`, `rm -rf`, `curl | sh`), and `local_execute` requests
   may have empty `targets`. If the matcher cannot predicate on `argv`, "add a policy"
   — the owner's headline scenario — becomes a Ruby change to the evaluator. Fix:
   enumerate the matchable `Request` fields and operators in the ADR (even a short closed
   list), so the data-vs-code boundary of future policies is knowable before build.

5. **[SHOULD-FIX] Dependency accounting is incomplete (Consequences, §2.3, §2.4).**
   By the repo's own pattern, `tamoz-sqlite` depends on every gem whose store contract it
   implements (its gemspec already lists graph, scheduler, stream) — so implementing the
   grant-store and decision-log ports adds a third edge, sqlite → tamoz-approval, which
   the Consequences' "two gems" omits. Separately, §2.4 gives the stream relay's receipt
   TTL "from the policy document" but never says how that value crosses into tamoz-stream:
   stream reading the gem's YAML would duplicate the loader or add an edge that
   contradicts the argued relay independence. Fix: state the sqlite edge explicitly, and
   specify the TTL as plain config injected at subscriber boot (like the relay's other
   ports), not as a policy-document read.

6. **[SHOULD-FIX] `on_timeout` has no enforcement owner (§2.1 `ask:`, weakness #4
   "Fixed").** The engine is pure and cannot fire timers; nothing names who resolves a
   parked ask after `timeout_s` (worker? scheduler? drainer?) or the race contract when a
   human answer and a timeout land together (`resolve` on an expired `decision_id`
   raises — §1.3 — so the loser's outcome is defined, but who calls it is not). The
   weakness-table verdict "Fixed" is overstated until the seam is named. Fix: one
   sentence assigning timeout enforcement to an existing component with a clock.

7. **[NIT] `Request#profile` / `#unattended` are redundant with engine construction
   (§1.2 vs §1.5).** §1.5 binds the profile at engine build (base + overlay resolved once,
   digest-pinned); carrying `profile` and a derived `unattended` flag per request invites
   an engine/request mismatch with undefined precedence. Audit context belongs on
   `Decision`/`policy_rev` and the log record, not the request. Fix: drop both fields, or
   define precedence.

8. **[NIT] `evidence:` symbols cannot be validated at load (§1.2, §2.1).** The gem
   deliberately cannot see comms' lattice, so a typo (`filesystem_opperator`) passes
   schema validation and the canned simulation suite, then raises at prompt build. The
   "as today" raise is acceptable, but say so — or inject the valid symbol set into the
   validator from the wiring layer. One-line fix either way.

Solid areas, one line each: the boundary rule (§1.1) and deletion of classifier-executor
fusion; `Data.define` + kwarg ergonomics are idiomatic for Ruby 3.3; `decide` never
raising for policy reasons is the right contract; `Answer.parse` is correctly scoped and
placed; no-shim deletion matches the owner directive; profile-as-overlay (rules
unreachable from profiles) is the right power asymmetry; the `runtime_contracts`
packaging claim checks out against `gemspec_helper.rb` and tamoz-stream's usage.

## Missed requirements

- **"Add a profile without touching core/agent" is not fully demonstrated.** Profiles are
  YAML and old validators are deleted, but the ADR never states how a profile *name*
  resolves (CLI flag / worker config / schedule spec, §2.2). If any Ruby site whitelists
  or validates profile names, adding a profile touches that gem. State that resolution is
  pure path lookup (`policy/profiles/<name>.yaml` or operator-supplied path), with
  unknown names failing at load.
- **Effect-journal convention (AGENTS.md):** addressed in §8 but on an incorrect premise
  (finding 3); the durable-replay story for `decide`'s mutable inputs must be restated
  before this can be called compliant.
- **Future scenario honesty (owner goal):** "change a tier's default/rules" is a YAML
  edit — good; "reclassify a tool to a different class" is a descriptor change in the
  tool's gem — fine and stated in §4.2 Q3; but neither scenario is possible at all until
  finding 1 supplies the classification input the tier map consumes. That gap is the one
  place the ADR's central promise ("policy changes never touch core/agent") is currently
  unsubstantiated by the migration plan.
