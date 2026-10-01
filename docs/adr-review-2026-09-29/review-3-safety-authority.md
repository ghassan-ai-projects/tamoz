# ADR Review — Lens 3: Safety & Authority

> Round-1 report retained as review history. Read [the round-2 adjudication](./round-2-evidence.md) before relying on its severity totals, missing-symbol claims, or acceptance conclusions.

Date: 2026-09-29 · Scope: adr-001–adr-055 · Method: boundary inventory + invariant/threat-model bar check + code gap spot-checks · Status: COMPLETE

## Boundary inventory

| ADR | Boundary drawn | Invariants? | Threat model? | Change bar? | Verdict |
|---|---|---|---|---|---|
| 001 | Naming identity (Tamoz/tamoz-*) | — | — | — | not safety-bearing |
| 002 | (retired tombstone → 052) | — | — | — | n/a |
| 003 | (retired tombstone → 048+051) | — | — | — | n/a |
| 004 | Composition API (`Tamoz.seq`) | — | — | — | not safety-bearing |
| 005 | Interrupts cannot be swallowed by node-level `rescue` (throw/catch) | implicit (structural impossibility argument) | no | no | note — structurally underpins approval-gate interrupt delivery; no explicit linkage to that gate (P3-level) |
| 006 | State shape + reducer registry | — | — | — | not safety-bearing |
| 007 | Durable values deep-frozen at commit; mutation impossible | implicit | no | no | OK at Tier C — integrity rule, structural, verified |
| 008 | Executor pool selection | — | — | — | not safety-bearing |
| 009 | Prompt-prefix stability is machine-checked (invariant 16) | INV-16 linkage, yes | no (not trust-bearing) | n/a | OK — Tier F with invariant linkage + verification |
| 010 | Ruby version floor/matrix | — | — | — | not safety-bearing |
| 011 | SQLite default persistence; leases/fencing owned by adapter | implicit | no | no | not authority-bearing (durability) |
| 012 | (retired tombstone → 029) | — | — | — | n/a |
| 013 | Vocabulary budget | — | — | — | not safety-bearing |
| 014 | Capability sources are a closed set; a new source is a gem release | no | no | no | finding — Tier F, deliberately restrictive capability boundary, zero apparatus; see F1 |
| 015 | Barrier returns only after checkpoint commits; no async-durable mode | pointer to INVARIANTS.md via Verification | no (no adversary; failure model stated in Context) | no | OK — crisp fail-closed rule, verified |
| 016 | Every effect has a deterministic key + safety class; ambiguous non-idempotent stops as `:unknown`, never blind-retried | pointer only | no | no | finding — the corpus's central effect-safety vocabulary, zero formal apparatus; see F2 |
| 017 | One fenced writer per (thread, ns); monotonic fencing tokens; zombie/concurrent writer cannot commit | decision states the invariant; pointer only | partial (adversary named in Context, no threat→mitigation table) | no | finding — load-bearing split-brain boundary, apparatus missing; see F4 |
| 018 | Backend-assigned integer sequence orders checkpoints | — | — | — | not safety-bearing (Tier C, OK) |
| 019 | Incompatible resume fails before user code | pointer (resume clauses of INVARIANTS.md) | no | no | OK — fail-closed interlock, verified |
| 020 | Serializer rejects secret-shaped values by default; one redaction policy across every surface; no regex scrubbing | no | no | no | finding — secret/trust boundary without threat model or change bar; Marshal refusal owned here lives only in design-refusals.md; see F3, F4 |
| 021 | `execution_id` scopes a turn; resume preserves identity, fork changes it; effect-bearing forks need explicit replay policy | pointer ("execution-identity invariants") | no | no | finding — identity-pinning boundary without threat model; see F4 |
| 022 | No task action runs without an accepted review of that exact persisted plan digest | yes (§4) | yes (§5 table) | no formal change-bar (Rejected table carries the reasoning) | finding — missing change-bar; see F6 |
| 023 | Improvement is promotion w/ holdout + human gate; generated content cannot self-approve; resume pins behavior version | yes (§4) | yes (§5 table) | no formal change-bar | finding — missing change-bar; see F6 |
| 024 | "Smart" = measured behavior, no intelligence claim | — | — | — | not safety-bearing (Tier F, OK) |
| 025 | Evaluator outside the subject; no runtime gem depends on tamoz-evals; evaluator changes start a new lineage | decision states it | no | no | OK/note — structural dependency-direction boundary, verified |
| 026 | Three memory layers; Wisdom activation requires evals + behavior-version transition | pointer (relates-to 023/025/027) | no | no | note — authority substrate; thin but governed via 023/027 |
| 027 | Authorization filters candidates before ranking; Experience never auto-injected; Wisdom pinned by behavior version; corrections propagate with receipts | pointer only | no | no | finding — quality bar §2 names "memory authority" apparatus-required; see F5 |
| 028 | Remediation requires typed failure, versioned rule, reviewed plan, original authority, budgets, verification; rules cannot self-promote | decision states it | partial (audit anecdote in Context) | no | finding — joins F4 retrofit cluster |
| 029 | Protocol/transport delegated to official SDK; Tamoz owns policy, effect identity, durable consent, supervision | decision states ownership split | no | no | OK — boundary is an ownership map, verified; OAuth delegated to SDK is a stated cost |
| 030 | Application is sole authority for trust/effect-class/scope; effective access = intersection of limits; sources only narrow, never grant | decision states it ("requests, not permissions") | no (adversary named in Context, no table) | no | finding — quality-bar-named Tier F example, zero formal apparatus; see F8 |
| 031 | Scheduler materializes occurrences; agent work only via the ordinary plan-gated graph | implicit (delivery/execution separation) | no | no | OK — the safety property (no timer-bypass of the gate) is structural |
| 032 | Jobs pin max capabilities/budgets/approval; run-time authority intersects current policy so revocation wins | decision states it | no (delayed privilege escalation named in Context, no table) | no | finding — delayed-authority boundary without apparatus; see F9 |
| 033 | Skills are inert recipes; scripts run only through ordinary reviewed tools | implicit (structural) | no | no | OK — the inertness claim is structural and verified |
| 034 | Skill identity = canonical tree digest; install/update quarantine → validate → evaluate → atomic activation; generated skills cannot self-approve | decision states it | no (supply-chain swap named in Context, no table) | no | finding — supply-chain promotion boundary without apparatus; see F9 |
| 035 | Unbounded evidence never enters graph/model directly; continuous plane lives outside (Go, per 055) | restated rule + revision pointer | deferred to ADR-055 | n/a | pending ADR-055 |
| 036 | Deterministic operators reduce authenticated events into immutable Situation snapshots; bounded admission, durable non-admissions | implicit (authentication + immutability) | no | no | note — evidence-admission authority; thin |
| 037 | Event-time/backpressure/effect-disabled replay are plane contracts, now owned by the external Go runtime | restated via 055 | deferred to ADR-055 | n/a | OK — honest revision; Ruby side computes no temporal semantics |
| 038 | Model proposes typed ActionIntents only; deterministic policy revalidates against current state and fails closed; approval never bypasses revalidation | inline prose ("R2/R3 fail closed") | partial (prose "Threat note" names asset/adversary/mitigation; no table) | no | finding — quality bar §2 names "physical action"; see F10 |
| 039 | Tamoz is supervisory only; R4 life-safety control stays external; interlocks cannot be weakened by self-healing/improvement | decision states it | no | no | finding — last-line safety claim without formal apparatus; see F10 |
| 040 | Repo layout; proximity grants no runtime dependency | — | — | — | not safety-bearing (carries open audit O1, resolved by 055) |
| 041 | Closed transport set; contract gem owns admission policy; worker makes no network channel call | implicit (closed set) | no | no | note — same closed-set pattern as ADR-014 (F1); apparatus gap shared |
| 042 | Gateway is the only process touching the transport; holds no model credential/toolbox/workspace | decision states it | no (channel-side adversary implied by Context) | no | finding — credential-isolation boundary without threat model; see F11 |
| 043 | Chat identity can deny an exact pending interrupt, never grant; single-use 128-bit digest-bound reference; atomic consumption; grant counters must stay zero | by reference (INV-A..INV-E live in ADR-049) | by reference (ADR-049 §6) | yes by reference (ADR-049 §4 bar) | OK/note — apparatus properly delegated to the amending ADR; but see F12 (the amendment's fallout) |
| 044 | Closed exporter set; conformance-gated adapters on the telemetry-out seam | implicit | no | no | note — shares F1 closed-set pattern |
| 045 | No durable telemetry table; no second writer beside the fenced writer | implicit (fenced-writer exclusivity) | no | no | OK — durability boundary, crisp rule, verified |
| 046 | Content excluded from every signal unless a named digest-bound classification-permitted policy admits it; omitted content = digest + size | decision states it | no | no ("refused for restricted classes" is undefined on paper) | finding — privacy boundary, "restricted classes" never defined; see F13 |
| 047 | Journal records everything; retention decided at export; safety-bearing signals never sampled | decision states it | no | no | finding — "safety-bearing signal" is never defined; see F13 |
| 048 | Sole credential resolver; one canonical projection; provider digest binds config, never credential values | decision states it | no | no | finding — quality-bar-named Tier F example without threat model/change bar; see F13 |
| 049 | Approval authority = evidence lattice (chat_bound < filesystem_operator); approve requires evidence >= requirement; absent/ambiguous never approves | yes (INV-A..INV-E, §3) | yes (§6 table) | yes (§4, five testable conditions) | finding — the reference ADR's own body is now contradicted by its 2026-09-24 policy amendment; see F12 |
| 050 | Automated response only on durable evidence over a non-degraded window, executed only by the owning subsystem; no actuator in observability | yes (clause 62 + 61) | yes (§5) | yes (§6, incl. "general hook is a permanent non-goal") | OK — exemplar; Proposed with named ratification conditions (clause-62 fault-injection test) |
| 051 | No runtime gem depends on `ruby_llm`; model fidelity Tamoz-native | yes (Invariant 11, ADR-020 link) | n/a (removal) | n/a | OK — exemplar of recording an already-made change |
| 052 | Vertical decomposition; one-directional edges to core; no vertical depends on CLI | yes (ADR-040 + Invariant 11) | n/a | n/a | OK |
| 053 | All approval policy is digest-addressed YAML data; gem returns verdicts, never executes; engine decides | yes (preserves INV-A..INV-E, ADR-022, ADR-030) | yes (§5, incl. symlink canonicalization) | n/a (enabling, not restrictive — though see F14) | OK — exemplar; profile "auto/bounded-bypass" vocabulary needs a policy check; see F14 |
| 054 | Websearch = reserved MCP server id with governed egress; fourth closed source | yes (ADR-030 intersection, closed set, 046/047) | yes (§5, exfiltration + impersonation) | implicit (closed set via ADR-014) | OK — exemplar |
| 055 | Continuous plane = external Go authority; Tamoz worker proposes, never disposes; sealed digest-verified snapshot; read-only allowlist host; opaque short-lived tokens | yes (ADR-036/038/039, ADR-009, ADR-020) | yes (§5, five rows) | substance present (frozen `runtime-v1` proto; coordinated two-repo release; Handshake refuses drift) | OK — exemplar; honest "not re-verified here" caveat on the Go side |

## Coverage

| ADR | Safety-bearing | Verdict |
|---|---|---|
| 001 | N | OK |
| 002 | N | OK (tombstone) |
| 003 | N | OK (tombstone) |
| 004 | N | OK |
| 005 | Y (adjacent) | note |
| 006 | N | OK |
| 007 | Y (durability) | OK |
| 008 | N | OK |
| 009 | Y (effect) | OK |
| 010 | N | OK |
| 011 | N | OK |
| 012 | N | OK (tombstone) |
| 013 | N | OK |
| 014 | Y (capability closure) | finding (F1) |
| 015 | Y (durability) | OK |
| 016 | Y (effect safety) | finding (F2) |
| 017 | Y (split-brain) | finding (F4) |
| 018 | N | OK |
| 019 | Y (adjacent, fail-closed) | OK |
| 020 | Y (secrets) | finding (F3, F4) |
| 021 | Y (identity pinning) | finding (F4) |
| 022 | Y (action gate) | finding (F6) |
| 023 | Y (self-mutation ban) | finding (F6) |
| 024 | N | OK |
| 025 | Y (adjacent, evaluator independence) | OK |
| 026 | Y (adjacent, memory authority substrate) | note |
| 027 | Y (memory authority) | finding (F5) |
| 028 | Y (remediation authority) | finding (F4) |
| 029 | Y (adjacent, consent ownership) | OK |
| 030 | Y (capability authority) | finding (F8) |
| 031 | Y (adjacent, no gate bypass) | OK |
| 032 | Y (delayed authority) | finding (F9) |
| 033 | Y (adjacent, inert skills) | OK |
| 034 | Y (supply-chain promotion) | finding (F9) |
| 035 | Y (plane boundary) | pending 055 |
| 036 | Y (adjacent, evidence admission) | note |
| 037 | Y (adjacent, plane contracts) | OK |
| 038 | Y (physical action) | finding (F10) |
| 039 | Y (supervisory-only) | finding (F10) |
| 040 | N | OK |
| 041 | Y (adjacent, closed transports) | note (shares F1 gap) |
| 042 | Y (credential isolation) | finding (F11) |
| 043 | Y (deny-only channel) | OK/note (see F12) |
| 044 | Y (adjacent, exfil surface) | note (shares F1 gap) |
| 045 | Y (adjacent, fenced-writer exclusivity) | OK |
| 046 | Y (content/privacy) | finding (F13) |
| 047 | Y (audit-trail integrity) | finding (F13) |
| 048 | Y (credentials) | finding (F13) |
| 049 | Y (approval authority) | finding (F12, P0) |
| 050 | Y (no authority from measurement) | OK |
| 051 | Y (model boundary) | OK |
| 052 | N (structure) | OK |
| 053 | Y (approval authority) | OK (F15 naming nit) |
| 054 | Y (egress authority) | OK |
| 055 | Y (two-repo authority split) | OK |

## Findings

- **F1 (P2) — ADR-014** (`documentation/adr/adr-014-extensions-are-first-party-adapter-gems-not-plugins.md:1-28`): Tier F
  decision drawing a deliberately restrictive capability boundary ("closed set" of sources,
  adding one requires a gem release) with no Invariant linkage, no Threat model, no change-bar —
  the file has no numbered sections at all. Quality bar §2 makes §8–10 required for
  capability-bearing decisions; E6 requires a change-bar for restrictive Tier F boundaries.
  Nothing on paper states what a future ADR must show to open the source set. Fix: add
  §-numbered Invariant linkage (point at ADR-030/034 as the live capability authority) and a
  §4-style change-bar ("a new source enters only as a gem release with a catalog entry and
  digest identity").
- **F2 (P1) — ADR-016** (`documentation/adr/adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md:1-31`):
  the ADR that owns the effect-safety vocabulary the whole product thesis rests on
  ("ambiguous effects stop as `:unknown`") — deterministic effect key, safety class,
  no blind retry — is a 31-line Tier F page with no Invariant linkage section, no threat
  model (what can an adversary controlling the effect target do? duplicate delivery,
  ambiguous timeout injection), and no change bar (what must a future ADR show to demote
  an effect's safety class?). Quality bar §2 requires all three for effect-bearing
  decisions; the `:idempotent`/`:unsafe` classes it governs are enforced in code
  (EffectDispatcher). Fix: add §-numbered sections mirroring ADR-049 — invariants
  (key identity, class fail-closed, unknown-pauses), a threat table for the effect
  target/channel, and a class-demotion change bar.
- **F3 (P2) — ADR-020 / design-refusals** (`documentation/adr/design-refusals.md:14`,
  `documentation/adr/adr-020-secrets-are-refused-by-type-or-explicitly-protected-never-scrubbed-by-name.md:1-31`):
  design-refusals.md owns the Marshal ban ("`Marshal.load` on a durable artifact is remote
  code execution") to ADR-020, but ADR-020 never mentions Marshal — the refusal and its
  security rationale live only in the digest, so the owning ADR cannot reconstruct why the
  boundary exists (violates the quality bar's "reconstruct from the record alone"). Fix:
  add Marshal-as-serializer to ADR-020's Rejected alternatives (and to its Decision's
  reject-by-default rule).
- **F4 (P2) — Tier F cluster missing formal apparatus: ADR-017, ADR-020, ADR-021**
  (`documentation/adr/adr-017-…:1-27`, `adr-020-…:1-31`, `adr-021-…:1-29`): all three are
  Tier F, all three guard an adversary-bearing boundary (zombie writer; secret reader;
  cross-execution effect reuse), and none has an Invariant linkage section, threat→mitigation
  table, or change bar — each states its invariant inside the Decision prose and points at
  INVARIANTS.md only from Verification. They predate the numbered-section convention
  (ADR-049/022 style). Fix: retrofit the §-numbered skeleton; each already has the raw
  material (Context names the adversary) so this is restructuring, not new analysis.
  ADR-028 (`adr-028-self-healing-is-bounded-remediation-not-catch-and-retry.md:1-34`) joins
  this cluster: its Context carries a real incident ("stale reads authorizing wrong writes")
  and its Decision stacks ten preconditions, but there is no threat→mitigation table and no
  change bar for loosening the rule-earning stages.
- **F5 (P1) — ADR-027** (`documentation/adr/adr-027-memory-retrieval-is-authorization-consolidation-preserves-disagreement.md:1-34`):
  memory retrieval authorization is on the quality bar §2 list of apparatus-required
  boundaries ("memory authority"), and this is its owning ADR — yet it is a 34-line Tier F
  page with no Invariant linkage section, no threat model (the obvious adversary:
  untrusted content that plants or recalls a record — cross-tenant/surface leak via
  relevance ranking), and no change bar. The Decision itself is strong
  (authorize-before-rank is the right shape); the record cannot reconstruct the argument.
  Fix: retrofit §-numbered sections; the threat table almost writes itself from the
  Context's one-sentence failure story.
- **F6 (P2) — ADR-022, ADR-023: no change-bar on the two most restrictive boundaries**
  (`documentation/adr/adr-022-reviewed-plan-gate.md:25-80`,
  `adr-023-self-improvement-promotion.md:22-79`): both have Invariant linkage and threat
  tables (good), neither has the §4-style "bar to change it" that ADR-049 carries — and
  these are the two boundaries a future maintainer is most likely asked to weaken
  ("risk-tier the plan gate", "auto-approve low-risk promotions"). The Rejected tables
  argue against the known weakenings but do not state the conditions a future ADR must
  satisfy. Fix: add a short change-bar section to each, stated as testable conditions
  (022: the gate may never become risk-tiered unless a new ADR proves no ungated action
  class exists; 023: the human gate on capability/security/evaluator/prompt/code is
  permanent).
- **F7 (P3) — hedged Verification lines in safety ADRs** (`adr-022…:87-88`,
  `adr-023…:85-86`): both carry "*Recommended follow-up:* cite the specific conformance
  clause/test … once confirmed" — an open TODO inside a Verification line of a
  safety-bearing ADR. Honest, but it means the gate's proof is not yet named. Fix: land
  the citation.
- **F8 (P1) — ADR-030** (`documentation/adr/adr-030-one-local-capability-catalog-governs-all-sources.md:1-35`):
  the capability-authority ADR — the quality bar §3 names it a Tier F example *alongside
  ADR-049 itself* — has no Invariant linkage section, no threat→mitigation table, and no
  change bar, despite its own Context naming the adversary ("remote or model-supplied
  metadata could quietly grant access"). The Decision carries the right rules (sole
  application authority, intersection semantics, sources narrow-only, epochs at turn
  boundaries) but nothing states the bar for, say, letting a skill self-declare an effect
  class. Fix: retrofit §-numbered sections; the threat table writes itself from Context
  (MCP annotation import, skill `allowed-tools` escalation, memory-granted capability).
- **F9 (P2) — ADR-032, ADR-034: authority-bearing Tier F pages without threat tables or
  change bars** (`documentation/adr/adr-032-…:1-34`, `adr-034-…:1-34`): 032 governs delayed
  authority (Context: "delayed privilege escalation"; Decision: revocation-wins
  intersection) and 034 governs supply-chain promotion (quarantine → validate → evaluate →
  atomic activate; generated skills cannot self-approve). Both name the adversary in
  Context, neither carries a threat table, invariant section, or change bar. Fix: same
  retrofit as F4; for 032 the key missing threat row is the stale-schedule case (a job
  pinned to capabilities later revoked — the revocation-wins rule deserves a stated test).
- **F10 (P2) — ADR-038, ADR-039: the physical-safety boundary lacks formal apparatus**
  (`documentation/adr/adr-038-…:1-37`, `adr-039-…:1-34`): 038 carries a prose "Threat note"
  naming asset/adversary/mitigation and the right fail-closed rules (R2/R3 fail closed;
  approval does not bypass revalidation) but no invariant linkage, no threat table, no
  change bar — despite quality bar §2 naming "physical action" as apparatus-required. 039
  makes the strongest claim in the corpus ("interlocks remain … impossible for
  self-healing/self-improvement to weaken") with no threat model and no change bar stating
  the (presumably "never") conditions under which Tamoz could take on control. Fix: 038
  upgrade the prose note to the §5 table plus invariants (fail-closed on insufficient
  evidence, revalidation-over-approval); 039 needs an explicit change bar — for this
  boundary the bar should read "no ADR can move Tamoz into R4 control; the boundary moves
  only by retiring the product claim".
- **F11 (P2) — ADR-042** (`documentation/adr/adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md:1-34`):
  the credential-isolation boundary (gateway holds the transport credential and never a
  Session/model credential/toolbox/workspace) is what makes the 043/049 authority story
  structurally enforceable — and it has no threat model (channel-side attacker,
  exfiltration via outbound sends, gateway compromise blast radius) and no change bar.
  Fix: add the threat table (the denied capabilities list in the Decision converts to
  invariant rows mechanically).
- **F12 (P0) — ADR-049's body contradicts its own 2026-09-24 policy amendment; the §4 bar
  was never invoked on paper**
  (`documentation/adr/adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md:3` amendment; `:10` abstract; `:42` INV-D;
  `:55-65` §5; `:80` §6): the Status line records that `base.yaml` now *requires only
  `chat_bound` to approve* — the bound Telegram correspondent can Approve. But the body
  still states, in four places, the deny-only world: the abstract ("a Telegram correspondent
  can deny but cannot approve"), INV-D ("v1 profile deny-only by evaluation"), §5 ("Bundled
  profiles keep network/external_publish gated above what `chat_bound` can approve"), and —
  worst — §6's residual-risk claim: "**the residual approval risk is zero** until a
  follow-up ADR lowers a specific effect to `chat_bound`". No follow-up ADR lowering an
  effect exists; the change rode the Status line instead, without the §4 five-condition
  analysis (reversible, argument-bounded, blast-radius stated, shorter TTL + louder audit
  record, default stays deny) it mandates "each with a test". The Verification line
  (2026-08-29) predates the amendment. Consequences: an auditor reading §6 certifies a false
  claim; a maintainer reading INV-D/§5 will describe shipped behavior wrongly; and the
  corpus's own model change-bar was bypassed by its reference ADR. **Code-verified:**
  `gems/tamoz-approval/policy/base.yaml:92-94` sets `evidence: {approve: chat_bound, deny:
  chat_bound}` globally; no bundled profile raises an evidence level (`grep evidence
  policy/profiles/*.yaml` → only base matches), so under every profile a `chat_bound`
  correspondent can approve any ask, including `network`, `external_publish`, and
  `destructive` tiers — making §5's "Bundled profiles keep network/external_publish gated
  above what `chat_bound` can approve" affirmatively false, not just stale. ADR-043's
  "`chat_grants` … must both remain zero" is likewise superseded silently: the counters
  exist (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:1099`) and will now increment.
  Fix (pick one, then make
  the record consistent): (a) if the amendment is intended, revise ADR-049 — rewrite §3/§5/§6
  to the amended policy, document the §4 five-condition analysis for the effects base.yaml
  now allows chat_bound to approve (or state the owner consciously waived the bar, with the
  blast-radius table anyway), re-verify against code with a post-amendment date, and name
  the conformance tests; or (b) if base.yaml was not meant to allow chat_bound approvals,
  fix the policy and strike the amendment. Either way ADR-043's "grant counters must remain
  zero" line and the gateway design doc need the same reconciliation.
- **F13 (P2) — ADR-046, ADR-047, ADR-048: strong rules, missing formal apparatus**
  (`documentation/adr/adr-046-…:1-33`, `adr-047-…:1-32`, `adr-048-…:1-37`): 046's
  "refused for restricted classes" never defines restricted (no pointer to the
  classification source), and its classification-permitted policy has no threat model
  (adversary: an operator or a compromised policy granting capture of restricted content).
  047's "safety-bearing signals are never sampled" never defines which signals are
  safety-bearing — the load-bearing noun is undefined, so nothing fails a test when a new
  signal type is simply not classified. 048 (a quality-bar §3 Tier F example) binds a
  provider digest but has no threat model (credential exfiltration via endpoint choice,
  endpoint-substitution via openrouter) and no change bar for adding a second native
  protocol. Fix: one retrofit pass — define the restricted/safety-bearing classification
  where it lives, add threat tables and change bars.
- **F14 (P1) — the shipped cancellation/stop boundary has no ADR** (code:
  `gems/tamoz-agent-session/lib/tamoz/agent/session_work.rb:9` — `CANCELLED =
  { next_node: 'terminal', terminal_reason: 'cancelled_by_user' }`;
  `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb`,
  `session_effects.rb`, `session_deliberation.rb` all route `Cancellation::Stops`): the
  rule "a user's stop ends the turn; it never aborts the graph — the work loop routes to
  its `cancelled_by_user` terminal and an in-flight model call is abandoned" is enforced
  in code across at least four gems, and the only ADR mention of cancellation in the whole
  corpus is ADR-052's one-line gem listing (`adr-052…:48`). This is exactly the corpus's
  own §5 "no orphans" blocking gap: a shipped decision with no record. It is
  safety-bearing: how a stop interacts with the durable record (running superstep dropped,
  request left `running`, parked approval prompts, in-flight effect calls abandoned vs.
  journaled) is the kind of boundary that gets silently changed and breaks replay/audit
  assumptions. Fix: write ADR-056 — decision (stop never aborts the graph; routes to a
  typed terminal), invariants (no orphaned running work; no partial effect without a
  receipt; a parked approval resolves withheld, not approved), threat row (cancel as an
  audit-evasion vector), change bar.
- **F15 (P3) — ADR-053 names permission modes that don't match the profile files**
  (`documentation/adr/adr-053-approval-gem.md:54` vs
  `gems/tamoz-approval/policy/profiles/`): the ADR says profiles express
  "plan/review/implement/auto/bounded-bypass permission modes"; the shipped files are
  `plan.yaml`, `review.yaml`, `implement.yaml`, `auto.yaml`, `unattended.yaml`. "auto"
  checked out cleanly: it un-gates `workspace_write`/`local_execute` tiers and never
  auto-resolves an ask, so ADR-049's "no form of automatic approval" non-goal holds. The
  "bounded-bypass"/"unattended" naming drift is cosmetic. Fix: one word in ADR-053.

## Code gap spot-checks

Five seams checked; each verified against the tree (grep/read only).

| Seam | Owning ADR? | Verified state | Result |
|---|---|---|---|
| Approval policy seam (policy-as-data, digest pinning) | ADR-053 | `gems/tamoz-approval/policy/base.yaml` + `profiles/{plan,review,implement,auto,unattended}.yaml` carry all tier/verdict/evidence policy; `lib/tamoz/approval/canonical.rb` is the single SHA-256-over-JCS digest recipe; `decision_log.rb` keys on argv/targets digests; no hardcoded verdict constant found | Seam matches the ADR — but the shipped `evidence.approve: chat_bound` contradicts ADR-049's body (F12, P0) |
| Effect safety classes / `:unknown` | ADR-016 | `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal.rb` (+ key/lifecycle/reconciler/transition-log family) implements deterministic keys, logical keys, attempt identity + fence; `EffectDispatcher` (`gems/tamoz-agent-kernel/.../effect_dispatcher.rb`) resolves ambiguous outcomes to terminal `:unknown`; descriptor effect classes `:read_only`/`:unsafe` in `capability_binding.rb:456` | Code is real and richer than the ADR's one-paragraph record (F2, P1) |
| The fenced writer (ADR-017's named boundary) | ADR-017 | 27 files under `gems/tamoz-sqlite/lib/tamoz/sqlite/` reference fence; `lease.rb` (`LeaseGuard`, `:fence`); `checkpoint_committer.rb:148` validates `lease_owner_id = ? AND lease_fence = ?` in the commit transaction | Boundary enforced in code; ADR apparatus still missing (F4, P2) |
| `Cancellation::Stops` (user stop ends the turn, never aborts the graph) | **none** | `session_work.rb:9` routes to the `cancelled_by_user` terminal; `gateway_commands.rb`, `session_effects.rb`, `session_deliberation.rb`, `subagent_report.rb` route through it; sole ADR mention is ADR-052:48's gem listing | **Safety rule in code with no record — F14 (P1)** |
| ADR-043 grant counters ("must both remain zero") | ADR-043 | `comms_store.rb:1099` computes `chat_grants`; `cli_worker_commands.rb:619` pins `headless_auto_approvals => 0` | Counters real; with `base.yaml` now chat-approvable, the must-stay-zero constraint is superseded silently — folded into F12 |

## Summary

**Counts.** 55 ADRs reviewed (53 live pages, 3 tombstones among them). Safety-bearing
(Y or Y-adjacent): 41. Not safety-bearing: 14. The corpus splits cleanly at ADR-049:
everything from ADR-050 onward (and 049 itself, on paper) carries the full numbered
apparatus — invariant linkage, threat tables, change bars — and several are exemplary
(050, 051, 053, 054, 055); everything older is thin pages whose Decision prose is usually
right but whose formal apparatus (invariants, threat→mitigation tables, change bars) is
absent, with the boundary's adversary often named in its own Context.

**Findings: 1 × P0, 4 × P1, 8 × P2, 2 × P3** (F1–F15 above).

**Top 3.**

1. **F12 (P0) — ADR-049's body contradicts its shipped policy.** The 2026-09-24 amendment
   made `chat_bound` approvable (`base.yaml:92-94`, no profile raises evidence), while the
   ADR's abstract, INV-D, §5, and §6 still claim deny-only and "residual approval risk is
   zero", and §4's five-condition bar was never invoked. The corpus's reference ADR is
   internally contradictory on its own subject. An operator-facing safety claim is
   currently false on paper in both directions.
2. **The pre-049 safety corpus cannot reconstruct its own boundaries (P1s: ADR-016, 027,
   030; P2 clusters: 014, 017/020/021/028, 022/023, 032/034, 038/039, 042, 046/047/048).**
   The effect-safety, memory-authority, and capability-authority decisions — three of the
   six apparatus-required domains in quality bar §2 — have no invariant linkage, threat
   model, or change bar; a maintainer asked to weaken any of them finds no stated bar.
3. **F14 (P1) — the cancellation/stop boundary is enforced in code and recorded nowhere.**
   `Cancellation::Stops` → `cancelled_by_user` ships across four gems; no ADR owns how a
   stop interacts with the durable record, parked approvals, and in-flight effects — the
   corpus's own "no orphans" blocking gap.

**Authority-story consistency check (requested):** consistent in code, inconsistent on
paper. ADR-053's policy-is-data seam is real (all verdicts in digest-addressed YAML;
canonical digest recipe in `approval/canonical.rb`; no hardcoded verdict found); identity
pinning (021/032) matches the effect journal's logical-key/attempt/fence machinery; the
fenced writer is enforced. The one inconsistency is F12: deny-only (043) → evidence-gated
(049) → chat-approvable (live policy) is a coherent progression as policy, but only the
last step skipped its own paper bar. ADR-050 (Proposed) is fully specified: it names its
ratification conditions (phase-5 landing + clause-62 fault-injection test), threat table,
and a change bar with a permanent non-goal.

**Questions for the owner.**

1. F12 is the decision point: was the 2026-09-24 `chat_bound`-can-approve policy intended
   to be permanent (then ADR-049 must be revised + the §4 analysis documented or consciously
   waived), or is `base.yaml` wrong (then the policy reverts and the amendment is struck)?
   The current state — false threat-model text plus a counters-must-stay-zero promise in
   ADR-043 that live policy now violates — should not survive another review cycle.
2. Should the §5 "no orphans" rule be applied to cancellation (ADR-056, F14) and to the
   ADR-014/041/044 closed-set refusals (one shared change-bar section each), or recorded as
   accepted exceptions?
3. For the retrofit backlog (F2/F4/F5/F8/F9/F10/F11/F13): is a single "retrofit the
   numbered skeleton onto the pre-049 Tier F pages" pass desirable as one tracked effort,
   given each ADR's Context already names its adversary and the analysis is mostly
   restructuring?
