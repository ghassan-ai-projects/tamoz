# 04 — Review: security-correctness

Perspective: threat model coverage, fail-closed behavior, injection/TOCTOU, digest/grant
semantics, denial and timeout paths, evidence requirements. Document reviewed:
`03-redesign-adr.md`; evidence from `02-current-state-audit.md`, `01-independent-study.md`,
and spot-checks of `tool_catalog.rb`, `mcp_capability_source.rb`, `cli.rb`.

## Verdict

With conditions. The skeleton is right: fail-closed classification with a kept
"nothing a server says can change this" invariant, validate-before-activate reload,
digest-bound single-use decisions preserved as `:once`, evidence minted only by trusted
paths, denial-as-data, and an append-only decision log with `policy_rev` are all correct
and honestly mapped to the audit. But the grant design as specified reopens the exact
over-bundling hole the ADR claims to close: session grants are offered on tiers whose
requests carry opaque argv while the grant key deliberately excludes argv, so one approval
becomes session-wide authority over arbitrary arguments — including for unknown-effects
MCP tools and `child_task`, which the ADR says stays always-ask. Several seams
(reload vs. in-flight sessions, interactive-CLI `resolve`, evidence-symbol validation,
`resolve` idempotence under crash recovery) are underspecified in ways that will be
decided by whoever writes the code, not by the design. Fix the grant key grammar and pin
those seams and the design is sound.

## Findings

1. **[MUST-FIX] Session-grant keys exclude argv; opaque-argv tiers subsume the tiers that
   are barred from session grants** (§2.1 `grant_keys`, §2.3, §4.2 Q1/Q4). The
   `local_execute` key is `[verb, tool, target_root]` and the fallback tier lands
   unknown-effects MCP tools in `local_execute`, which offers `grant_scopes: [once,
   session]`. Three concrete holes:
   - MCP tools default to `:unknown_effects` with arbitrary model-supplied JSON arguments
     (`mcp_capability_source.rb:126-129`); a session grant keyed without argv (and often
     without any path target, so the key degenerates to `[verb, tool]`) auto-approves
     every later call to that tool for the session. One approval of a dual-use MCP tool
     (read + post) is then session-wide exfiltration authority — the "network/publish can
     never hold session grants" bar (§2.1 validation, §4.1 deviation 1) is enforced per
     *tier*, but classification is per *descriptor*, and opaque tools never reach those
     tiers.
   - `run_check` takes a configured check name (`tool_catalog.rb:20`); a session grant on
     `[verb, tool, target_root]` covers *all* configured checks, not the one approved.
   - `child_task` is mapped to `local_execute` (§4.2 Q4) "preserving today's always-ask
     behavior as data" — but `local_execute` offers session grants, so one approval with
     scope `session` ends always-ask for all future child spawns. The claim is false as
     written.
   Suggested change: bar `:session` for the fallback tier and for any tool whose key
   fields are absent/degenerate; for `local_execute`, include an argv-derived component
   chosen per tool in policy data (check name for `run_check`, nothing → `once`-only for
   MCP); keep `child_task` `once`-only. This is study F4/§6.5 applied to the ADR's own
   key grammar.

2. **[MUST-FIX] `resolve` is specified as raise-on-replay, which conflicts with the
   crash-safe resume it sits under** (§1.3). The kept worker path (audit §4 strength 2)
   recovers from a crash between resume and consume by reclaiming the fenced decision and
   re-applying it, with dedup via the derived resume id. If `resolve` raises
   `UnknownDecisionError` for an already-resolved id, that legitimate retry crashes the
   worker as "a defect" (§1.3) instead of deduping. Suggested change: make `resolve`
   idempotent — a replay with the same answer/scope returns the existing grant; only a
   *conflicting* resolution raises.

3. **[SHOULD-FIX] First-match rule order lets `allow` shadow `deny`** (§2.1 `rules`).
   Validation checks verdict membership but not ordering or overlap; an author who appends
   a broad `allow` above `credential-files` silently voids it. Claude Code's documented
   order (deny → ask → allow) and the sudoers opacity lesson (study §6.1/§6.3) both point
   the same way. Suggested change: evaluate all deny rules before ask/allow regardless of
   document order, or have the loader reject an allow rule whose match overlaps a deny
   rule's.

4. **[SHOULD-FIX] Reload semantics for in-flight sessions and pending asks are
   unspecified** (§1.5, §2.3). The study (§4.3) requires in-flight sessions to keep their
   `policy_rev` unless explicitly re-bound; the ADR drops that sentence. After `reload`:
   does a parked `:ask` resolve against the old policy, the new one, or raise? And the
   grant-revalidation rule "grants whose key the new policy would not have issued are
   dropped" is not computable from the stored tuple `(key, scope, session_id, policy_rev,
   …)` — the request is gone and the log keeps only digests. Suggested change: pin the
   simple fail-closed rule — a grant is valid only while its `policy_rev` equals the live
   one (drop-on-mismatch), and parked asks resolve under the policy that issued them.

5. **[SHOULD-FIX] The interactive CLI responder never reaches `engine.resolve`**
   (§2.4 Pipeline A). Only "the worker's resume path" is named; the interactive path
   resumes in-process (`cli.rb:207,277`) and would mint no grant and append no human
   answer to the decision log — so the headline feature (session grants) silently doesn't
   exist in the primary interactive UX, and its audit record is incomplete. Suggested
   change: state that all three responders funnel through `resolve`, with the interactive
   path calling it before `session.resume`.

6. **[SHOULD-FIX] Evidence symbols are data the gem cannot validate** (§1.2, §2.1
   `evidence:`). The gem depends only on tamoz-core, so the loader cannot check that
   `approve: filesystem_operator` names a member of comms' closed lattice; a YAML typo
   raises at prompt-build time, mid-turn, instead of failing load — precisely the
   validate-before-activate property §1.3 claims. Suggested change: wiring validates the
   evidence block once at engine construction (comms exposes a membership predicate
   injected into the loader), keeping the dependency direction intact.

7. **[NIT] `on_timeout: park` + `timeout_s: 900` is a permanent brick, not a declared
   outcome** (§2.1 `ask:`). Prompts and decisions expire at ~900 s today; after expiry
   the ask is unanswerable, so "park" means "parked forever, no longer answerable."
   Either say that plainly, re-issue the prompt on expiry, or make `park` mean
   park-without-expiry.

8. **[NIT] `Decision#id` derivation is unspecified** (§1.2, §8). The repo convention is
   "key identity and dedup on the request"; say explicitly that the id is derived from
   the request digest + `policy_rev`, not random, so duplicate asks dedup.

9. **[NIT] "Canonicalized absolute targets" should mean symlink-resolved** (§1.2, §2.1).
   Otherwise the `**/.env*` deny glob and `target_root` grant keys are bypassable by a
   workspace symlink pointing at `~/.ssh` (study F3 names exactly this swap). One word —
   "realpath" — in §1.2 closes it.

What is solid, one line each: fail-closed fallback and the kept MCP invariant (§1.3, §7.1);
digest-bound single-use decisions preserved as `:once` (§2.3, §7.2); evidence minted only
by trusted paths with the lattice untouched (§7.3); atomic prompt consumption kept (§7.4);
denial-as-structured-result plus the retained repeated-action guard is the right loop
protection (§2.4); grant revalidation on reload with no grandfathering is correctly
fail-closed in intent (§2.3); Pipeline C non-convergence is correctly argued — its guards
are protocol invariants, not policy (§2.4).

## Missed requirements

- **F6 (fatigue attacks) silently dropped.** The study's recommendation maps F6 to ask
  rate-limiting and a visible prompt counter; the ADR's deviation list (§4.1) never
  mentions it. Session grants mitigate habituation but do nothing against a
  steered-agent prompt flood between grants. A one-line deviation ("accepted: the
  repeated-action guard terminates floods as loops") would suffice — but it must be said.
- **R5 (cost/side-effect spend) has no home.** The study recommends cost-bearing verbs as
  their own tier with budget rules in profile data; the tier vocabulary (§2.1) has no such
  tier and no deviation explains the omission. If tamoz budgets live in another subsystem,
  say so in one line.
- **Canned simulation suite location unstated** (§2.1 validation). Cases like "`read
  .env` → deny" are domain knowledge; under B9/P4 they belong in data with digest-pinning,
  and the ADR should name where they live and how they are gated, not leave it to the
  implementer.
- **Interactive-grant UX contract.** If finding 5 is fixed, the interactive prompt must
  also *offer* the scopes from `grant_offer`; §1.4's `Answer.parse` vocabulary has no way
  to express scope choice. Either extend the answer vocabulary or state that interactive
  approvals are `once`-only.
