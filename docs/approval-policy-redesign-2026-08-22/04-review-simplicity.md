# 04 — Review: simplicity & operability

Perspective: is the redesign genuinely simpler, migration risk/ordering, operational
burden (authoring, reload, debugging), production failure modes, over-engineering.
Reviewed: `03-redesign-adr.md` in full; audit `02` as evidence; spot-checked repo
claims (no shipped YAML profiles carry `tools.approval_required`; evals harness does
reference denied-approval behavior).

## Verdict

Yes-with-conditions. The core design is sound and honestly simpler: one engine, one
data file, one `Decision` type, denial-as-data, the study deviations (no taint, no
batching, no OPA) are correctly refused, and the Pipeline C non-convergence argument
is the right call. The complexity table (§6) is credible, not marketing. But the ADR
is weakest exactly where operability lives: the `reload` it promises cannot actually
reach the running worker as specified, the grant-revalidation mechanism is both
under-specified and more elaborate than the problem needs, and the timeout "fix"
leaves the default profile with today's park-forever behavior. Two MUST-FIX items,
both in the reload/grant machinery; nothing else threatens viability.

## Findings

1. **[MUST-FIX] `reload` cannot reach the running engine (§1.5, §2.3).** §1.5 builds
   one `Engine` in the worker process at boot and makes reload "an operator action
   (`tamoz approve --reload <path>`-style admin command)". That command runs in a
   separate CLI process; it cannot mutate the worker's in-memory engine. No delivery
   mechanism is specified — not a file watch, not a DB-polled `policy_rev`, not a
   signal. As written, either reload silently does nothing for live workers or it
   requires a restart, and the ADR's headline operability promise ("a policy change
   is a YAML edit") fails in exactly the production case it exists for. This is the
   same class of gap the audit pinned as weakness #8 (writes a row and stops, no
   wakeup). Concrete fix: persist active policy path + `policy_rev` in the database;
   the worker already polls parked threads — have it (or session start) pick up a
   changed rev, or explicitly scope reload to boot-time and say so. Decide which;
   don't leave it to implementation.

2. **[MUST-FIX] Grant revalidation on reload is unimplementable as specified, and
   over-built (§2.3).** "On reload, grants whose key the new policy would not have
   issued are dropped." The grant row is `(key, scope, session_id, policy_rev, …)`;
   the opaque key string does not retain the request fields or grammar needed to
   re-derive "would the new policy have issued this". Building that re-derivation is
   machinery without a caller. The simple solution the repo directive demands is
   already in the schema: `policy_rev` is stored per grant, so a lookup that ignores
   grants whose `policy_rev ≠ current` gives fail-closed-on-reload for free, at read
   time, with no sweep and no revalidation logic. Adopt that; delete the
   revalidation paragraph. Same section: `expires_at_ms` is declared but nothing
   says what sets it for `:session` grants ("dies with the session" — via what
   hook?). Specify, or session grants become permanent rows.

3. **[SHOULD-FIX] `on_timeout: park` semantics are undefined, and the default
   profile keeps weakness #4 (§2.1, §3 row 4).** The base document ships
   `timeout_s: 900, on_timeout: park`. What expires at 900 s, which answer paths
   remain valid afterwards (operator CLI still accepted?), and what an operator does
   with a timed-out parked turn are all unstated. If park means "prompt dies, turn
   waits forever", the weakness-#4 row claiming **Fixed** is true only for the
   `unattended` profile. Either define park precisely (channel prompt expires,
   operator CLI answer still resolves) or ship `deny` as the base default. As
   written this is a production failure mode: an attended run whose human walks away
   is indistinguishable from today.

4. **[SHOULD-FIX] `required_evidence` values are not validated at load (§2.1).**
   The validation list checks tiers, verdicts, and grant scopes but not the
   `evidence:` symbols; §1.2 says non-members "raise there" in comms at prompt-build
   time. A YAML typo (`filesystem_operater`) passes load validation and raises
   mid-session, when a human is being asked — a config-typo production crash that
   load-time validation exists to prevent. Add the evidence vocabulary to schema
   validation (a fixed list in the validator, or declared in the document).

5. **[SHOULD-FIX] The canned simulation suite's home is unspecified, and the
   obvious home violates the ADR's own invariant (§2.1 vs §8).** Cases like
   "`read .env` → deny" are policy expectations; as Ruby they are exactly the
   policy-literals-in-code §8 claims are gone. Make them a `simulations:` block
   inside the policy document — data, digest-pinned with everything else.

6. **[SHOULD-FIX] The stream receipt TTL couples `tamoz-stream` to policy loading
   (§2.4).** "The receipt store gains an `expires_at` field with a TTL from the
   policy document" — but stream deliberately depends only on `tamoz-core`, and who
   reads the YAML and hands the TTL over is unstated. Say it: the subscriber boot
   passes a plain integer from run config; stream never loads policy documents.

7. **[SHOULD-FIX] Migration gaps (§5).** Step 7 lists agent/comms/stream tests but
   omits `tamoz-evals` (`agent_smoke_corpus.rb` pins denied-approval behavior;
   `07_denied_approval` suite cases) — denial-as-result changes what they assert.
   Step 3 deletes the `tools.approval_required` / `unattended.*` validators but never
   states what happens to operator-authored profile files carrying those keys (repo
   ships none; operators may have them). One line — "old keys now fail validation" —
   closes it. Otherwise the ordering is good: gem → migration → call sites →
   comms → scheduler → tests → docs, each step green, and step 3's size is the honest
   price of the no-shims directive.

8. **[NIT] §8 slightly overclaims determinism.** "Grants are deterministic
   projections of journaled answers" ignores that reload-drops and expiry mutate
   grant state outside the graph journal, so crash-replay of a session can re-decide
   differently. The divergence is bounded and fail-closed (a re-prompt, never an
   unasked allow) — say that in one line instead of claiming purity.

9. **[NIT] No retention story for the two new tables (§2.3, §2.5).** Append-only
   decision log and grant rows with no purge repeats the audit §3.3
   "receipts accumulate forever" pattern in new code. One line (purge with thread,
   or explicitly accepted) suffices.

10. **[NIT] Profile overlay resolution with a custom document path (§2.1/§2.2).**
    "A run may point at a different document path" — do profile overlays then come
    from the gem's `policy/profiles/` or relative to the supplied path? Authoring
    ambiguity; state the rule.

11. **[NIT] Secrecy discipline is inconsistent and hurts debugging (§2.3/§2.5).**
    The decision log stores argument digests only, while grant rows store
    tool/target_root in cleartext. Storing the structural fields (tool, verb, tier,
    rule_id — never argv) in the log costs no secrecy and makes "why was this
    asked/denied" answerable from the DB alone; with digests-only it isn't, since
    the request cannot be reconstructed to feed `simulate`.

12. **[NIT] "Each session gets a fresh grant store" (§4.2 Q4)** contradicts §1.5's
    one engine with one injected store — it is `session_id` scoping on a shared
    store. Reword.

## Missed requirements

- **Owner goal, partially undermined:** "policy/profiles swappable without touching
  tamoz-core/tamoz-agent" is architecturally met but operationally hollow until
  finding 1 is resolved — a YAML edit that live workers never see is not swappable.
- **Domain-knowledge-as-data:** finding 5 (simulation cases must be data).
- **No other convention is missed:** the effect-journal invariant is correctly
  reasoned in §8 (modulo nit 8); no-backcompat is embraced, not dodged; the
  not-built list (taint, batching, OPA, push wakeup) is the right cut and the
  simplicity budget table is honest. Nothing in the design is over-engineered
  enough to cut outright except the grant-revalidation machinery in finding 2 —
  which the simpler `policy_rev`-match lookup replaces rather than merely deletes.
