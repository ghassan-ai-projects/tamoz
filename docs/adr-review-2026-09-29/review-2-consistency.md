# ADR Review — Lens 2: Consistency & Supersession Integrity

> Round-1 report retained as review history. Read [the round-2 adjudication](./round-2-evidence.md) before relying on its severity totals, missing-symbol claims, or acceptance conclusions.

Date: 2026-09-29 · Scope: adr-001–adr-055 · Method: chain-by-chain edge check + status cross-walk + contradiction clusters · Status: COMPLETE

## Chain audit

| Edge | Resolves? | Successor covers predecessor's decision? | What is lost |
|---|---|---|---|
| 002→052 | Yes, bidirectional (002 tombstone → 052; 052 names 002 as superseded in Relates to + Context) | Yes — 052 records the real topology (27 gems, 8 verticals + composition root) that falsifies "four gems" | Nothing |
| 003→048 (transport half) | Partially — 003 names 048; **048 never names 003** (its Relates to lists only 051; Verification defers to 051) | Yes — 048 owns the transport replacement, retires `RubyLLMModel` | Nothing material; reciprocity only |
| 003→051 (RubyLLM-removal half) | Yes, bidirectional (051 names 003 and explicitly splits its two halves) | Yes — passthrough half retired, durable-codec half retained as `Tamoz::StateCodec`; loss is named and intentional | Nothing |
| 012→029 | Weak — 012 tombstone → 029; 029 names 012 only as an **unlinked parenthetical inside Verification** ("supersedes the…retired ADR-012"), no Relates to link | Yes — ADR-029 states the replacement decision (native at the edge, official SDK, shipped) | Nothing; reciprocity is prose-only, not a link (quality bar §2 item 3) |
| 030→054 | Yes, bidirectional (030 status + Relates to → 054; 054 names 030) | Yes — 030's Decision now reads "four sources"; 054 supplies mechanism + threat model | Nothing, **but** 054 §1 still says "ADR-030 was never updated" and §3 says 030's "three sources is now stale" — both false against 030's current text |
| 035→055 | Yes, bidirectional; 035 status "revised by 055" | Textbook — 035's Decision states the surviving rule and exactly what moved (continuous plane → Go `agentic-stream`; `tamoz-stream` → EpisodeWorker) | Nothing |
| 037→055 | Yes, bidirectional; 037 status "revised by 055" | Textbook — Decision rewritten: contracts now owned by the stream, "Tamoz computes none of them" | Nothing |
| 040→052 | Yes, bidirectional ("instantiated by" both sides) | Yes — 052 is the concrete application of 040's rule | Nothing |
| 040→055 | **Broken as a recorded edge** — 055 names 040 ("deliberate exception"); 040 mentions 055 only in Consequences prose; **040's Relates to omits 055**, so catalog.json (`040.amended_by=["052"]`, `055.amends=["035","037"]`) and relationships.md drop the edge — while README Notes lists "040→055" | Yes in substance — 055 §3 records the exception and its justification | The edge itself, in catalog + graph: 3 of 4 surfaces disagree |
| 043→049 | Yes structurally (bidirectional; 049 is the "new ADR" 043's change-bar requires) | Yes for the v1 policy — **but** 049's 2026-09-24 status-line amendment (`base.yaml` lets `chat_bound` approve) contradicts 049 §6's own threat table ("chat_bound cannot approve any action under v1 policy"; "residual approval risk is zero") and bypasses 049 §4's bar, which requires **a later ADR** per effect; 043's change-bar likewise demands "a new ADR" | The threat model and residual-risk text are stale inside the live safety ADR; the policy change has no ADR of its own |
| 048→051 | Yes, bidirectional ("completed by" / "this ADR completes") | Yes — 051 explains why 048 alone understated the change | Nothing; note "completed by" is a one-off status relation outside quality bar §5's vocabulary (P3) |

## Coverage

Status-in-file is the `**Status:**` line (files are source of truth); README is the index row. "Partners" = ADRs whose text this one must stay consistent with.

| ADR | Status in file | Status in README | Consistent? | Partners |
|---|---|---|---|---|
| 001 | Accepted 2026-07-30. | Accepted | Yes | 052 (27-gem count) |
| 002 | Retired — superseded by ADR-052 | Retired → 052 | Yes | 052, RETIRED |
| 003 | Retired — superseded by ADR-048 (transport) + ADR-051 | Retired → 048+051 | Yes | 048, 051, RETIRED |
| 004 | Accepted (revised after an executable counterexample). | Accepted | Partly — README drops "revised"; no Date line | 051 (`Tamoz.seq` link) |
| 005 | Accepted. | Accepted | Yes (no Date line) | — |
| 006 | Accepted. | Accepted | Yes (no Date line) | 007 (frozen values) |
| 007 | Accepted. | Accepted | Yes (no Date line; stale `ruby_llm` prose) | 006, 051 |
| 008 | Accepted. | Accepted | Yes (no Date line) | — |
| 009 | Accepted. | Accepted | Yes (no Date line) | 055 (cache invariant inside episode) |
| 010 | Accepted (revised after support-status review). | Accepted | Partly — README drops "revised"; no Date line | — |
| 011 | Accepted. | Accepted | Yes (no Date line) | 015–018 |
| 012 | Retired — superseded by ADR-029 | Retired → 029 | Yes | 029, RETIRED |
| 013 | Accepted (revised after review). | Accepted | Partly — README drops "revised"; no Date line | — |
| 014 | Accepted. | Accepted | Yes (no Date line) | 030, 054 (closed source set, named in prose) |
| 015 | Accepted. | Accepted | Yes (no Date line) | 016, 017, 019 |
| 016 | Accepted. | Accepted | Yes (no Date line) | 015, 018, 037 (effect-disabled replay) |
| 017 | Accepted. | Accepted | Yes (no Date line) | 011, 015 |
| 018 | Accepted. | Accepted | Yes (no Date line) | 016, 019 |
| 019 | Accepted. | Accepted | Yes (no Date line) | 021 |
| 020 | Accepted. | Accepted | Yes (no Date line) | 046, 051 (one redaction policy) |
| 021 | Accepted. | Accepted | Yes (no Date line) | 019 |
| 022 | Accepted 2026-07-30 | Accepted | Yes (cosmetic: no trailing period) | 023, 028, 049, 050, 053 |
| 023 | Accepted 2026-07-30 | Accepted | Yes | 022, 025, 026, 027, 028, 034 |
| 024 | Accepted 2026-07-30. | Accepted | Yes | 025 |
| 025 | Accepted 2026-07-30. | Accepted | Yes | 023, 026, 052 |
| 026 | Accepted 2026-07-30. | Accepted | Yes | 023, 027, 036 |
| 027 | Accepted 2026-07-30. | Accepted | Yes | 026 |
| 028 | Accepted 2026-07-30. | Accepted | Yes | 022, 050 |
| 029 | Accepted 2026-07-30; **shipped** (`tamoz-mcp`) | Accepted (shipped) | Yes | 012, 030, 054 |
| 030 | Accepted 2026-07-30; **extended by ADR-054** | Accepted (extended → 054) | Yes | 054, 014, 033, 034, 053 |
| 031 | Accepted 2026-07-30; **shipped** (`tamoz-scheduler`) | Accepted (shipped) | Yes | 032 |
| 032 | Accepted 2026-07-30. | Accepted | Yes | 031 |
| 033 | Accepted 2026-07-30. | Accepted | Yes | 034, 052 (2026-08-29 note) |
| 034 | Accepted 2026-07-30. | Accepted | Yes | 033, 023, 030 |
| 035 | Accepted 2026-07-30; **revised by ADR-055** | Accepted — **arrow missing** | **No — README row lacks (revised → 055)** | 055, 036, 037 |
| 036 | Accepted 2026-07-30. | Accepted | Yes (reinforced, not amended, by 055) | 035, 038, 055 |
| 037 | Accepted 2026-07-30; **revised by ADR-055** | Accepted — **arrow missing** | **No — README row lacks (revised → 055)** | 055, 016, 035 |
| 038 | Accepted 2026-07-30. | Accepted | Yes | 036, 039, 055 |
| 039 | Accepted 2026-07-30. | Accepted | Yes | 038, 055 |
| 040 | Accepted 2026-07-30; **instantiated by ADR-052** | Accepted (instantiated → 052) | Yes for 052; **040→055 edge absent from file header, catalog, graph** | 052, 055 |
| 041 | Accepted 2026-08-10. | Accepted | Yes | 042, 043, 014 |
| 042 | Accepted 2026-08-10. | Accepted | Yes | 041, 043, 049 |
| 043 | Accepted 2026-08-10; **amended by ADR-049** | Accepted (amended → 049) | Yes | 049, 041, 042, 053 |
| 044 | Accepted 2026-08-10. | Accepted | Yes | 045, 046, 047, 050 |
| 045 | Accepted 2026-08-10. | Accepted | Yes | 044, 050 (carve-out named both sides) |
| 046 | Accepted 2026-08-10. | Accepted | Yes | 044, 047, 054 |
| 047 | Accepted 2026-08-10. | Accepted | Yes | 044, 046, 050 |
| 048 | Accepted 2026-08-26; **completed by ADR-051** | Accepted (completed → 051) | Yes for 051; **does not link predecessor 003** | 051, 003 |
| 049 | Accepted 2026-08-12; policy amended 2026-09-24 (owner) | Accepted | Partly — index carries no trace of the 09-24 amendment | 043, 053, 022 (022/042 not named back) |
| 050 | Proposed — observability phase 5 | Proposed | Yes | 044, 045, 047, 022, 028 |
| 051 | Accepted 2026-08-26 | Accepted | Yes | 003, 048, 002, 004 |
| 052 | Accepted 2026-08-26 | Accepted | Yes (README title is a truncated paraphrase) | 002, 040, 025, 053 |
| 053 | Accepted 2026-08-22 (implemented) | Accepted | Yes (README omits "(implemented)" — cosmetic) | 049, 022, 043, 030, 052 |
| 054 | Accepted 2026-08-26 | Accepted | Yes (but 054's own prose says 030 "was never updated" — now false) | 030, 029, 014, 046, 047 |
| 055 | Accepted 2026-08-12 | Accepted | Yes (README title is a truncated paraphrase) | 035, 037, 036, 038, 039, 040 |

## Findings

**F1 — P0 — ADR-049 (+ADR-043): the 2026-09-24 approval-policy amendment contradicts the ADR's own change-bar and leaves the threat model stale.**
Evidence: `adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md` line 3 (status: "policy amended 2026-09-24 (owner): `base.yaml` requires `chat_bound` to approve, so the bound correspondent can Approve"); §4 (lines 45–53: "A **later ADR** may set `required_evidence = chat_bound` for a specific effect **only if** all of the following hold, each with a test" — five conditions incl. blast-radius statement and shorter TTL + louder audit record); §5 (line 64–65: bundled profiles stay above `chat_bound` "unless a future ADR invokes §4"); §6 threat row (line 73: "`chat_bound` cannot approve any action under v1 policy") and Residual risk (line 80: "residual approval risk is **zero** until **a follow-up ADR** lowers a specific effect to `chat_bound`"); `adr-043` lines 20–21 ("Any future grant mode requires **a new ADR**, a threat model, and a step-up identity decision — the bar ADR-049 §4 now defines").
What's wrong: the live safety policy was changed (chat_bound approvals enabled in `base.yaml`) by an owner edit recorded only in a Status line. No ADR meets §4's five conditions; 043's change-bar is bypassed; and 049's own §6 still tells an operator/auditor that a leaked bot token can never approve and residual risk is zero — the opposite of the status line. INV-D was updated for the new world; §5's last sentence, §6, and Residual risk were not. This is the product's central safety boundary, so a misleading record here is a P0.
Fix direction: write the §4 ADR (which tiers/effects are chat_bound-approvable, per-effect blast radius, shorter TTL + distinct audit record, tests) or revert `base.yaml`; then rewrite 049 §5/§6/Residual-risk to the amended reality; give the README index an arrow to the new ADR.

**F2 — P1 — ADR-040 → ADR-055: the "deliberate two-repo exception" edge exists in README Notes only; the file, catalog.json, and relationships.md all drop it.**
Evidence: `adr-040` line 6 — `Relates to:` names only ADR-052; Consequences (line 21) mentions ADR-055 in prose only; `catalog.json` — `040.amended_by = ["052"]`, `055.amends = ["035","037"]` (no 040); `relationships.md` graph has no `A040 --> A055` edge; README Notes line 117 lists "040→055 (deliberate two-repo exception)" as a chain. ADR-055 line 5 names ADR-040, so the successor half exists.
What's wrong: three of the four surfaces (file header, machine catalog, graph) disagree with the fourth (README Notes). A reader of the graph concludes the monorepo rule has one amendment (052) and no exceptions. Since files are the catalog's source, the 040 header is the root cause.
Fix direction: add "ADR-055 (deliberate two-repo exception to the one-monorepo rule)" to 040's `Relates to`, regenerate `catalog.json` + `relationships.md`. Also delete 040's stale Verification parenthetical "(Audit O1: the `agentic-stream` Go authority … needs an ADR)" — ADR-055 is that ADR and says it resolves O1.

**F3 — P1 — README index rows for ADR-035 and ADR-037 omit the amending arrow their files carry.**
Evidence: `adr-035` line 3 and `adr-037` line 3: "Accepted 2026-07-30; **revised** by [ADR-055]"; README rows (lines 88, 90): plain "Accepted". README's own convention (line 50): "An arrow (→ NNN) names the amending ADR." The Notes section lists 035→055 and 037→055, so the index contradicts the Notes and the files.
What's wrong: status drift index vs file on the two revised streaming ADRs; a reader scanning the table misses that those decisions were substantively rewritten (the continuous plane left the Ruby gem).
Fix direction: change the two rows to "Accepted (revised → 055)".

**F4 — P2 — ADR-054's prose asserts ADR-030 "was never updated" while 030's live text has been updated.**
Evidence: `adr-054` §1 line 21 ("ADR-030 was never updated; the record undercounts…") and §3 line 52 ("ADR-030's 'three sources' is now stale and must read 'four'"); `adr-030` line 18 now reads "The closed source set is now **four**: local tools, skills, MCP, and websearch (ADR-054)".
What's wrong: both files are Accepted and in force, yet 054 describes 030 as stale when the current 030 page is correct. A reader following the chain gets contradictory statements about the same text.
Fix direction: past-tense 054 ("030 had not been updated; this ADR is that revision"), or drop the sentences.

**F5 — P2 — ADR-048 never links its predecessor ADR-003; the 003→048 supersession edge is one-directional.**
Evidence: `adr-048` line 6 — `Relates to:` lists only ADR-051; no mention of ADR-003 anywhere (only "the retired `RubyLLMModel`", line 20). ADR-003's tombstone names 048 as (co-)successor. Quality bar §2 item 3 and §4 A3 require supersession links bidirectional.
Fix direction: add "ADR-003 (supersedes its RubyLLM-transport half)" to 048's Relates to. (ADR-051 already carries the full 003 reciprocity, which is why this is P2, not P1.)

**F6 — P2 — ADR-029's reciprocity to retired ADR-012 is an unlinked parenthetical inside Verification, not a Relates-to entry.**
Evidence: `adr-029` line 27: "(supersedes the 'deferred/post-v0.1' timing of the retired ADR-012)" — plain text, no `adr-012` link, no header entry; `adr-012` tombstone links 029. Quality bar §2 item 3 requires links with one-line reasons.
Fix direction: add `**Relates to:** ADR-012 (retired — this ADR replaces its deferred-timing decision)`.

**F7 — P2 — Batch of unreciprocated "Relates to"/prose edges.**
022 → 049 (049 nowhere names 022 or the reviewed-plan gate it depends on); 023 → 025/026/027/028/034 (none name 023 back); 049 → 042 (042 doesn't name 049); 052 → 025 (not back); 055 → 036/039 (not back in those files' text). 022↔053, 043↔049, 030↔054, 035/037↔055, 002↔052, 048↔051 are reciprocal.
Fix direction: add back-references where the dependency is real (049→022 and 055→036 matter most — both are safety chains); otherwise state in the quality bar that relates-to may be one-directional.

**F8 — P2 — Systemic template gaps vs ADR_QUALITY_BAR §2 (always-required sections).**
(a) 17 ADRs have no `**Date:**` line: 004, 005, 006, 007, 008, 009, 010, 011, 013, 014, 015, 016, 017, 018, 019, 020, 021. (b) ~37 ADRs have no `**Relates to:**` header (all of the above plus 024–029, 031–034, 036, 038, 039, 041, 042, 044–047). Consequence: the generated catalog's `relates_to` is sparse even where real edges exist in prose (e.g. 014 names ADR-030/054 in its Decision, but catalog `014.relates_to` is empty), so `relationships.md` under-reports coupling.
Fix direction: backfill headers on next touch of each file, or amend §2 to make Relates-to required only where edges exist and record the Tier-C grandfathering; then regenerate catalog/graph.

**F9 — P3 — Status vocabulary drift.** Quality bar §5 defines five statuses (Proposed/Accepted/Revised/Superseded/Retired). The corpus adds one-off relations: "Accepted (revised …)" parentheticals (004, 010, 013 — not even annotated in the README), "instantiated by" (040), "completed by" (048), "extended by" (030), "policy amended" (049). README mirrors them. Fix: document the compound-status convention in §5, or normalize.

**F10 — P3 — Title drift in index/graph vs file H1s.** README row 052 "…decomposed into focused gems" vs file "…focused, independently publishable gems"; README row 055 "Continuous plane is a separate Go authority…" vs file "The continuous plane … (`agentic-stream`) …"; relationships.md node labels are mechanically truncated mid-word ("MCP is native at the edge and uses"). Fix: regenerate titles from H1s.

**F11 — P3 — ADR-007 line 17 still compares to "`ruby_llm`'s fluent mutable style" in present tense after ADR-051 removed the dependency. Historical mention, harmless. Fix: "the retired `ruby_llm` dependency" or drop the vendor name.

**F12 — P3 — Cosmetic uniformity.** ADR-049's `Date:` line sits apart from Status (template order is Status/Date/Tier/Relates-to) and its Next-reads lists README.md twice with different labels (lines 111, 114); 022/023/051/052/054/055 status lines omit the trailing period the others carry; README omits 053's "(implemented)". Fix: one normalization pass.

## Summary

- **Counts.** 55/55 ADRs cross-walked (file status vs README index vs RETIRED.md); 10 chain edges audited endpoint-to-endpoint (7 clean, 1 one-directional reciprocity gap 003→048, 1 prose-only reciprocity 012→029, 1 edge broken across surfaces 040→055, 1 resolves-but-stale-content 043→049); 5 contradiction clusters tested (approval, monorepo/two-repo, model transport, memory, effects/durability) — no cluster shows two accepted ADRs contradicting on decision content; 12 findings: 1 × P0, 2 × P1, 5 × P2, 4 × P3.
- **Top 3 issues.**
  1. **(F1, P0)** ADR-049's 2026-09-24 status-line amendment (`chat_bound` can approve via `base.yaml`) bypassed the ADR's own §4 bar and ADR-043's "new ADR" change-bar, and 049's §6 threat model / residual-risk text still say `chat_bound` can never approve and residual risk is zero. The live safety policy has no ADR, and the reference ADR contradicts itself.
  2. **(F2, P1)** The 040→055 "deliberate two-repo exception" chain edge is recorded in README Notes only — 040's `Relates to`, catalog.json, and relationships.md all omit it (and 040's Verification still asks for the ADR that 055 already is).
  3. **(F3, P1)** README index rows for ADR-035 and ADR-037 lack the "(revised → 055)" arrow their files carry, contradicting the index's own arrow convention and the Notes chain list.
- **What held up well.** The retirement hygiene is excellent: 002/003/012 tombstones, RETIRED.md rows, and successors all agree on what died and why; 003's two-half split (transport → 048, codec → 051/`Tamoz::StateCodec`) is explicit with nothing silently lost; 035/037/055 is a textbook revision chain (each side names exactly what changed and what survives); the 030↔054 and 045↔050 carve-outs are stated on both sides; terminology is stable post-052 (capability catalog / sources / skills used consistently; every verification path cites post-decomposition gem names).
- **Questions for the owner.**
  1. Was the 2026-09-24 `chat_bound` change meant to invoke ADR-049 §4 — and if so, should the §4 bar be amended in the corpus rather than bypassed by a policy-data edit? Which tiers in `base.yaml` are now `chat_bound`-approvable?
  2. Should 040→055 be a real `amends` edge (add to 040's header + regenerate catalog/graph), or is an "exception reference" the intended semantics?
  3. Are the missing `Date`/`Relates to` headers on the 004–021 block deliberate grandfathering from the 2026-08-29 audit, or debt to backfill (F8)? Backfilling would also populate the catalog's `relates_to` for edges that today live only in prose (e.g. 014→030/054).
