# ADR Review — Lens 5: Clarity & Completeness

> Round-1 report retained as review history. Read [the round-2 adjudication](./round-2-evidence.md) before relying on its severity totals, missing-symbol claims, or acceptance conclusions.

Date: 2026-09-29 · Scope: adr-001–adr-055 · Method: rubric pass per ADR + link integrity + unwritten-decision sweep · Status: COMPLETE

## Coverage

| ADR | Tier | Rubric pass? | Decision unambiguous? | Worst issue |
|---|---|---|---|---|
| 001 | C | No — E3: no Rejected alternatives section | Yes | No rejected alternative anywhere (rename alternatives unrecorded) |
| 002 | tombstone | Yes (stub per §5) | n/a | — |
| 003 | tombstone | Yes (stub per §5) | n/a | — |
| 004 | C | No — E3: no Rejected alternatives section | Yes ("revised" status doesn't name the revising record) | Rejection (native `>>`) lives only in Context prose |
| 005 | C | Borderline — rejection present in prose, no section | Yes | E3 content exists but not in the declared section |
| 006 | C | Yes | Yes | — |
| 007 | C | Borderline — E3: rejection only implicit (mutable style) | Yes | No explicit rejected alternative |
| 008 | C | No — E3: no Rejected alternatives | Weak — Decision never states ":threads is the default"; inferable only from title | Decision rule not restated in Decision section |
| 009 | F | Borderline — E4: invariant 16 cited inline, no Invariant linkage section | Yes | Tier F without dedicated Invariant linkage |
| 010 | C | No — E3: none | Yes | No rejected alternative (e.g. keeping 3.2, JRuby now) |
| 011 | C | No — E3: none | Yes | Persistence alternatives (Postgres/files) nowhere recorded |
| 012 | tombstone | Yes | n/a | — |
| 013 | C | Borderline — rejection (numeric cap) in prose, no section | Yes | — |
| 014 | F | No — E5/E6: capabilities-adjacent Tier F with no Threat model, no change-bar | Yes | Declared Tier F but no authority-safety structure |
| 015 | F | No — E3/E5: rejection in prose only; no Invariant linkage, no Threat model | Yes | Effect-bearing Tier F without safety structure |
| 016 | F | No — E5: has Rejected alternatives but no Invariant linkage/Threat model | Yes | Effect-bearing Tier F without threat table |
| 017 | F | No — E3/E5: no Rejected section, no Threat model | Yes | Split-brain adversary implied in Context, never formalized |
| 018 | C | Yes | Yes | — |
| 019 | F | No — E3/E5: no Rejected section, no Invariant linkage/Threat model | Yes | — |
| 020 | F | No — E5: secrets-bearing Tier F with no Threat model | Yes | Secrets policy without a threat table is the sharpest gap in batch |
| 021 | F | No — E3/E5: no Rejected section, no Threat model | Yes (dense but parseable) | Two-level identity model demands slow reading |
| 022 | F | Near-pass — full structure; no change-bar (§2 item 10) | Yes — bolded rule sentence | Missing "bar to change it" for THE central restrictive gate |
| 023 | F | Near-pass — full structure; no change-bar | Yes — bolded rule sentence | Same missing change-bar; "non-negotiable" gate has no written loosening conditions |
| 024 | F | Yes at tier (stance ADR; no threat model needed) | Yes | — |
| 025 | F | Yes at tier | Yes | Verification doubles as a clarification (O3) — fine |
| 026 | F | No — E5: memory-authority Tier F, no Threat model/Invariant linkage | Yes | Joins corpus safety-structure gap |
| 027 | F | No — E5: authorization-before-ranking is a trust boundary, no Threat model | Yes | Sharpest memory gap |
| 028 | F | No — E5: healing authority, no Threat model | Yes | — |
| 029 | F | No — E5: host/consent boundary, no Threat model | Yes | — |
| 030 | F | No — E5/E6: named Tier-F exemplar in QUALITY_BAR §3, yet no Threat model and no change-bar | Yes | Trust-boundary centerpiece without a threat table |
| 031 | F | Yes at tier (rejection present; not authority-bearing) | Yes | — |
| 032 | F | No — E5: delayed-authority ADR, no Threat model | Yes | — |
| 033 | F | Borderline — E5 mild; dated revision note is good practice | Yes | — |
| 034 | F | No — E5: supply-chain promotion with no Threat model | Yes | Adversary (skill-swap author) obvious but unwritten |
| 035 | F | Borderline — E5 mild; revised-by note is model clarity | Yes | Best-in-corpus revision hygiene with 022/023 |
| 036 | F | Borderline — E5 mild | Yes | — |
| 037 | F | Borderline — E5 mild; revision state exemplary | Yes | — |
| 038 | F | Borderline — threat content present as inline "Threat note", not §2 table/section | Yes | Physical-action ADR without formal threat table |
| 039 | F | No — E5: life-safety boundary, no Threat model | Yes | — |
| 040 | F | No — stale Audit-O1 note says the second repo "needs an ADR" (ADR-055 closed this) | Yes | Verification contradicts corpus state |
| 041 | F | Yes at tier | Yes | — |
| 042 | F | No — E5: credential-isolation boundary, no Threat model | Yes | — |
| 043 | F | Yes — carries its own change-bar inline; threat model properly deferred to 049 | Yes | — |
| 044 | F | Yes at tier (closed-set note; not authority-bearing) | Yes | — |
| 045 | F | Yes at tier | Yes | Bare "§18.4" cross-ref with no named document |
| 046 | F | Borderline — E5 mild (sensitive-content boundary) | Yes | — |
| 047 | F | Yes at tier | Yes | — |
| 048 | F | No — E5: named Tier-F exemplar touching credentials, no Threat model | Yes | Digest "never credential values" deserves the table |
| 049 | F | No — internally stale after the 2026-09-24 policy amendment (see finding 5) | Yes | Reference ADR contradicts its own Status amendment |
| 050 | F | Yes — full structure, honest not-implemented Verification | Yes | (Proposed, correctly labeled) |
| 051 | F | Yes | Yes | — |
| 052 | F | Yes | Yes | Verification cites 27 gems; architecture/gems.md now says 29 |
| 053 | F | Yes (no change-bar, mild) | Yes | Adopts an uncataloged redesign ADR — good provenance |
| 054 | F | Yes — model implementation of Tier F | Yes | — |
| 055 | F | Yes — model implementation; honest cross-repo caveat | Yes | — |

## Unwritten decisions

Sweep basis: AGENTS.md owner directives (with line numbers), `documentation/design/README.md` page list, and the ADR index. Candidates verified against ADR coverage before inclusion.

1. **ADR-056 candidate — "A user's stop ends the turn; it never aborts the graph."** Evidence: `AGENTS.md:71-75` (cancel drops the running superstep, request stays `running`, next pass recovers; `/cancel` routes through `Tamoz::Cancellation::Stops` / `Worker#watching_for_stop` to a `cancelled_by_user` terminal; in-flight model call abandoned). No ADR owns cancellation semantics — ADR-005 covers interrupt-by-throw (framework interrupt inside a worker), not user-stop versus durable-execution recovery. Load-bearing for the durability claim; contested trade-off (abort vs. recover).
2. **ADR-057 candidate — "Domain knowledge is data, never code" (B9 / P4 gate-4).** Evidence: `AGENTS.md:85-95` — domain content only in `test/fixtures/domains/*.json` via `test/support/domain_loader.rb`; six pinned wire digests (aqua/clim intent, diag, prompt); protocol SHA in `documentation/benchmark/BENCHMARK_PROTOCOL.json`; Go parity digest `e4f86620…` gating Ruby edits. No ADR mentions domain-knowledge-as-data, digest-gated data edits, or the cross-repo parity gate (checked 009/024/025 and the full index). Load-bearing for the evidence chain.
3. **"Real model for real runs; fakes stay in tests" (extend ADR-024 or new ADR).** Evidence: `AGENTS.md:96-99`. ADR-024 defines measured "smart" but nowhere is the evidence-honesty rule (a stub/fixture/deterministic provider is never shown as agent evidence) recorded.
4. **Durable no-backwards-compat / migration policy (new ADR).** Evidence: `AGENTS.md:33-37` — no legacy-row handling, checksummed manifest-pinned migration ordinals, fresh-schema assumption. The stance appears per-instance (ADR-001 "no compatibility aliases", ADR-048, ADR-053 "No legacy shims") but no ADR owns the migration mechanism or the standing no-compat rule.
5. **Effect receipt immutability + request-keyed dedup (extend ADR-016).** Evidence: `AGENTS.md:61-70` — "Key identity and dedup on the request, never on the answer. Terminal receipts are immutable" and the ephemeral-runtime journals-through-the-same-dispatcher rule. ADR-016 owns the deterministic key, safety classes, and `:unknown`; the receipt-immutability and dedup-on-request refinements are in no ADR.
6. **Gem facade-only boundary mechanism (extend ADR-040/052).** Evidence: `AGENTS.md:44-48` — access only through the facade named in the gem's README, guarded by a leak-failing test. ADR-040/052 own the manifest/dependency-boundary rule; the facade-README mechanism is unrecorded.
7. **Weaker / owner question:** the coding harness decisions (frozen header, append-only surface, spill, pruner, compaction — `documentation/design/coding-harness.md`, listed in `documentation/design/README.md:40`) have no owning ADR. Likely "how, not whether" (design-level), but compaction policy borders on decision territory. Owner to rule.

Considered and excluded (not architecturally significant per ADR_QUALITY_BAR §1): never force-push (`AGENTS.md:8-9`, process), never-pay-real-time-in-a-test (`AGENTS.md:112-113`, testing), enola baseline usage (`AGENTS.md:131-161`, workflow), clean-house-as-you-go (`AGENTS.md:49-54`, process).


## Findings

Severity-ordered digest (details carry their numbers from the traversal-order list below):

- **P0-1** — Unwritten decision: "a user's stop ends the turn; it never aborts the graph" exists only in AGENTS.md folklore (`AGENTS.md:71-75`); no ADR owns cancellation semantics. → UD-1 below, ADR-056 candidate.
- **P0-2** — Unwritten decision: "domain knowledge is data, never code (B9/P4)" with digest-gated edits and the Go parity gate exists only in AGENTS.md folklore (`AGENTS.md:85-95`). → UD-2 below, ADR-057 candidate.
- **P1-1** — Finding 5: ADR-014 (Tier F, capabilities) has no Threat model, no change-bar.
- **P1-2** — Finding 7: corpus-wide — Tier F effect/safety-bearing ADRs (015, 016, 017, 019, 020, 021, 026, 027, 028, 029, 032, 034, 039, 042, 048) lack the §2 safety structure; sharpest: 020 (secrets), 017 (split-brain), 027 (authorization).
- **P1-3** — Finding 14: ADR-049 is internally stale — its 2026-09-24 Status amendment (chat_bound may approve) contradicts §6's "residual approval risk is zero" and threat row "cannot approve any action".
- P2 — findings 1, 3, 4, 6, 9, 11, 12, 17, 18. P3 — findings 2, 8, 10, 13, 15, 16, 19.

1. **P2 — ADR-001, ADR-004 (Tier C): no Rejected alternatives.** Evidence: `documentation/adr/adr-001-framework-is-tamoz-…md` (no such section, no rejection in prose); `adr-004-…md` (rejection of native `Proc#>>` in Context only, no section). §2 item 7 / §4 E3 make ≥1 rejected alternative required at Tier C. Fix: add a Rejected alternatives section (native `>>` for 004; e.g. "two identities / rename later" for 001).
2. **P3 — ADR-005, ADR-007: rejection present but not in the declared section / only implicit.** 005 states the rejected alternative (exception-based interrupt) in Context; 007's only rejection (mutable fluent style) appears inside the Cost clause. Fix: normalize to the section.
3. **P2 — ADR-008: Decision section does not state the decision.** Evidence: `documentation/adr/adr-008-threads-is-the-default-pool-inline-in-tests.md` lines 11-14 — the Decision paragraph argues network-bound-ness and describes `:inline`/`:fibers`, but the rule "`:threads` is the default pool" appears only in the title. Fix: restate the rule as the first Decision sentence.
4. **P2 — ADR-009 (Tier F): no `## Invariant linkage` section.** Evidence: same file, lines 1-29 — invariant 16 is cited inline (lines 19, 24) but the Tier-F linkage section required by §2 item 8 / E4 is absent; sections unnumbered. Fix: add the linkage section (content already exists).
5. **P1 — ADR-014 (Tier F, capabilities): missing Threat model and change-bar.** Evidence: `documentation/adr/adr-014-no-plugin-api-in-v0-1.md` lines 1-27 — the ADR draws a deliberately restrictive capability boundary ("friction is deliberate", line 18) but has no threat model (§2 item 9 / E5) and no bar-to-change section (§2 item 10 / E6), and no Invariant linkage. Fix: add threat table (adversary: third-party source author) + the bar to reopen a plugin surface.
6. **P2 — ADR-010, ADR-011: no Rejected alternatives at all.** Evidence: `adr-010-…md`, `adr-011-…md` — neither names a single rejected alternative (JRuby-only deferral in 010; no Postgres/file-store comparison in 011). §4 E3. Fix: add one-row tables.
7. **P1 — corpus pattern: Tier F effect/safety-bearing ADRs lack the §2 safety structure (Invariant linkage + Threat model; no numbered sections, no change-bar).** Evidence: `adr-015-…md`, `adr-016-…md`, `adr-017-…md`, `adr-019-…md`, `adr-020-…md`, `adr-021-…md` — all declare **Tier: F**, all touch effects/secrets/durability authority, yet none carries `## Invariant linkage` or `## Threat model` (each names a conformance suite only in Verification). ADR-049 is declared the reference implementation of exactly this structure (ADR_QUALITY_BAR.md §2: "ADR-049 is the reference implementation"). Sharpest cases: 020 (secrets policy) and 017 (split-brain/zombie writer — the adversary is already described in its Context but never formalized). Fix: add threat→mitigation tables + invariant linkage to the six; the material largely exists in prose.
8. **P3 — ADR-015, 017, 019, 021: Rejected alternative present only implicitly (as the danger in Context), no section.** Fix: one-row rejection tables, as 016/018/020 already do.
9. **P2 — ADR-022, ADR-023: no "bar to change it" section.** Evidence: `adr-022-reviewed-plan-gate.md` (ends §7 Verification, no change-bar), `adr-023-self-improvement-promotion.md` (same). §2 item 10 requires exact re-loosening conditions for a deliberately restrictive boundary; 022 is the product's central gate and 023 calls its human gate "non-negotiable" without writing the conditions under which that stance could ever change. Fix: add a §"The bar to change it" to both.
10. **P3 — the nine full-page ADRs (022, 023, 049, 050, 051, 052, 053, 054, 055) each carry a stray `Current version: 0.1.0.alpha.1` line** (e.g. 022 line 12, 023 line 12, 049 line 12, 050 line 14, 055 line 15) — release boilerplate that belongs to READMEs, not ADR pages; no short-form ADR has it. Fix: drop the line everywhere.
11. **P2 — ADR-030: named Tier-F exemplar (ADR_QUALITY_BAR.md §3) yet lacks Threat model and change-bar.** Evidence: `adr-030-one-local-capability-catalog-governs-all-sources.md` lines 1-35 — it draws the corpus's central trust boundary ("the application … assigns trust, effect class, scope, and authority", "a source can only narrow authority, never grant it") with no threat→mitigation table and no written conditions for loosening the closed-source-set rule. Fix: add both; the Context already names the adversary class (remote/model-supplied metadata).
12. **P2 — ADR-040: stale audit note in Verification contradicts the corpus.** Evidence: `adr-040-one-monorepo-multiple-independently-publishable-gems.md` line 29 — "*Audit O1: the `agentic-stream` Go authority is a second repo whose relationship to this rule needs an ADR*" — but ADR-055 is accepted, in the index (README amendment chain `040→055`), and named in 040's own Consequences (line 21) as recording the exception. The record now disagrees with itself in one page. Fix: delete or update the O1 note.
13. **P3 — ADR-038: threat model exists but as an inline bolded note, not the §2 threat table.** Evidence: `adr-038-physical-action-….md` lines 19-21 ("**Threat note:** the asset is actuation…"). Content is right; structure is not the declared Tier-F shape. Fix: promote to the table form.
14. **P1 — ADR-049: the 2026-09-24 policy amendment in the Status line contradicts the body the rest of the page still asserts.** Evidence: `adr-049-telegram-approval.md` line 2-3 (amendment: "`base.yaml` requires `chat_bound` to approve, so the bound correspondent can Approve") vs. line 73 (threat table: "`chat_bound` cannot approve any action under v1 policy; the strongest a leaked token buys is denial") and line 80 ("residual approval risk is zero"). A maintainer reading §6 comes away with a wrong security posture for today's policy. Fix: revise §5/§6 against the amended policy (INV-D's text at line 42 already anticipates profile-set tiers; the residual-risk paragraph and threat row need the same update), per the corpus's own A4 rule ("never silently wrong").
15. **P3 — ADR-049: duplicated `Next reads` entry.** Evidence: lines 111 and 114 both link `README.md` ("the full ADR index" / "the authoritative ADR catalog"). Fix: drop one.
16. **P3 — ADR-049 section order deviates from the declared order.** README.md lines 17-19 claim safety-bearing ADRs keep "the section *names and order* the same either way"; 049 places Consequences at §7 (template: immediately after Decision) and adds Adoption (§9) not in the declared set. Defensible for the reference ADR, but then the README claim is too strong. Fix: soften the README wording or reorder.
17. **P2 — the public invariants page lags the corpus by one clause.** Evidence: `documentation/architecture/invariants.md:1` ("Sixty-one clauses") vs ADR-050 `adr-050-automated-response-durable-evidence.md` lines 42, 59-62 (ratifies INVARIANTS.md clause 62; traceability row 050 lists "61, 62"). A reader following 050's citation to the public contract finds no clause 62. Fix: refresh the public summary (61 → 62) or note the phase-5 clause.
18. **P3 — gem-count drift between ADR-052 and the gem map.** Evidence: `adr-052-agent-gem-decomposition.md` line 88 ("27 `tamoz-*` gems", verified 2026-08-29) vs `documentation/architecture/gems.md:1` ("twenty-nine independently publishable gems"). Two gems arrived after 052's Verification without an ADR touch; not an ADR defect (A4 is lens 1's), but a completeness reader gets two numbers. Fix: refresh 052's Verification line or note the count is point-in-time.
19. **P3 — ADR-045 cites "§18.4" with no named document.** Evidence: `adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md` lines 16-17 ("(OBSERVABILITY_DESIGN §10) … (§18.4; ADR-050)") — the second reference drops the document name. Fix: write "OBSERVABILITY_DESIGN §18.4".

## Summary

**Counts.** 55 files read in full (every ADR 001–055, ~50 lines each); 8 external link targets existence-checked, all resolve; 2 context/doc sweeps (AGENTS.md, design/README.md). Corpus composition: 3 tombstone stubs (002, 003, 012 — correct §5 shape), 10 Tier C, 42 Tier F. Coverage table: all 55 rows filled.

- Rubric pass at declared tier (this lens): **~16 clean**, **~13 borderline** (content present, section/structure off), **~26 with a gap** — dominated by one corpus-wide pattern (finding 7) rather than 26 distinct defects.
- Findings: **2 P0, 3 P1, 9 P2, 7 P3** (digest at the top of Findings).
- Decision-text clarity is a strength: every in-force ADR has an identifiable, quotable rule; only ADR-008 forces the reader to infer the rule from the title.
- Link hygiene is excellent: zero broken links found across every file read plus the 8 sampled external targets.

**Top 3.**
1. **P0 — two load-bearing decisions live only in AGENTS.md** (user-stop-never-aborts-graph; domain-knowledge-is-data with digest/parity gates). Write ADR-056/057.
2. **P1 — ADR-049, the declared reference ADR, is internally stale**: its §6 residual-risk claim ("zero", leaked token buys only denial) contradicts the 2026-09-24 policy amendment recorded in its own Status line. The corpus's scariest document says two things.
3. **P1 — the Tier-F safety-structure gap is generational, not random**: everything elevated or written after the 2026-08-29 audit (022, 023, 050–055) has the full structure; the short-form Tier-F ADRs from before it (effects, secrets, memory authority, fencing) have none of it. A batch edit adding Invariant linkage + threat tables to ~15 files closes the gap with material that already exists in their prose.

**Questions for the owner.**
1. Ratify ADR-056 (user-stop semantics) and ADR-057 (domain-knowledge-as-data) — or name where these belong if not ADRs?
2. Should the ~15 pre-audit Tier-F ADRs be elevated to the full-page structure, or should ADR_QUALITY_BAR §3 be softened so "F" does not promise threat models the corpus mostly does not carry? (Current state: tier label and reality disagree.)
3. ADR-049: amend §5/§6 to the post-2026-09-24 policy in place, or supersede with a new ADR?
4. Is the coding-harness/context-engine policy (design page, no owning ADR) design-level "how", or is compaction/surface policy a decision you want recorded?









