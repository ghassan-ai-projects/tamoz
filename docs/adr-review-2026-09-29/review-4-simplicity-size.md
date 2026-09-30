# ADR Review — Lens 4: Simplicity & Size

> Round-1 report retained as review history. Read [the round-2 adjudication](./round-2-evidence.md) before relying on its severity totals, missing-symbol claims, or acceptance conclusions.

Date: 2026-09-29 · Scope: adr-001–adr-055 · Method: rejection-ledger audit + is-it-an-ADR screen + overlap scan · Status: COMPLETE

## Rejection ledger health

| ADR | Rejections present? | Substance |
|---|---|---|
| 001 | none | No Rejected section; "no compatibility aliases" refusal is buried in prose |
| 002 | n/a | Tombstone stub — correct shape |
| 003 | n/a | Tombstone stub — correct shape |
| 004 | none | Alternative (native `Proc#>>`) argued in Context, not recorded as a rejection |
| 005 | none | Alternative (LangGraph exception interrupt) argued in Context, no section |
| 006 | 1 | Substantive (`Data`/`Struct` state) — but thinner than design-refusals.md claims it owns (see F2) |
| 007 | none | Alternatives (shallow freeze, mutable state) implicit only |
| 008 | none | Refusal it owns per digest ("no async/await twin API") absent from the ADR itself |
| 009 | none (Tier F) | "Invariant beats guideline" argued inline, never recorded as a rejection |
| 010 | none | Alternatives (keep 3.2, JRuby now) argued inline only |
| 011 | none | Obvious alternative (server DB / Postgres) unstated |
| 012 | n/a | Tombstone stub — correct shape |
| 013 | none | Hard-cap alternative argued inline only; decision is itself a refusal of machinery |
| 014 | none (Tier F) | The ADR *is* a refusal, but the open-registry alternative it rejects is never tabled |
| 015 | none (Tier F) | "Async durable" alternative argued in Context, never tabled |
| 016 | 1 | Substantive (blind retry — duplicates irreversible work); matches digest |
| 017 | none (Tier F) | No alternative (e.g. optimistic concurrency, fenceless leases) recorded |
| 018 | 1 | Substantive (UUID lexical order — not concurrency/clock-safe) |
| 019 | none (Tier F) | Best-effort-resume / auto-migrate alternatives unstated |
| 020 | 1 | Substantive (regex scrubbing — lossy, incomplete); matches digest |
| 021 | none (Tier F) | Single-level identity / fork-reuses-source-id alternative unstated |
| 022 | 3 | Substantive, threat-model-grade (prompt-only gate; risk-tiered gate; shared discovery/action plan) — the corpus model |
| 023 | 3 | Substantive (live self-mutation; repetition-promotion; auto-approve low-risk) |
| 024 | 1 | Substantive ("smart" as unmeasured personality claim) |
| 025 | 1 | Substantive (scattered test files — no corpora/lineage/release evidence) |
| 026 | 1 | Substantive (one vector store — erases authority/lifecycle differences); cost honesty ("more machinery") explicit |
| 027 | 1 | Substantive (relevance-first then model-side filtering) |
| 028 | 1 | Substantive (free-form "try something else") |
| 029 | 1 | Substantive (in-tree MCP reimplementation — protocol churn couples graph correctness) |
| 030 | 1 | Substantive (MCP annotations / `allowed-tools` as permissions — cross-boundary content can only narrow) |
| 031 | 1 | Substantive (execution inside timer callback — dishonest crash/duplicate semantics) |
| 032 | 1 | Substantive (host-timezone cron + inherited permissions — DST surprises, privilege escalation) |
| 033 | 1 | Substantive (Tamoz-only skill DSL / plugin API — portability loss, premature extension surface) |
| 034 | 1 | Substantive (watching mutable skill dirs, newest-bytes-on-resume — silent shadowing, supply-chain swaps) |
| 035 | 1 | Substantive (token streaming rebranded as bidirectional — no temporal truth/recovery); revision honestly states what 055 changed |
| 036 | 1 | Substantive (per-event invocation / raw windows into prompts — cost+staleness, deterministic→probabilistic) |
| 037 | 1 | Substantive (broker QoS / processing time as semantics) |
| 038 | 1 | Substantive (actuator tools + confirmation prompt — injection, stale state, approval fatigue) |
| 039 | 1 | Substantive (marketing the framework as a safety/robot controller) |
| 040 | 1 | Substantive (separate repos from first commit); the 055 second-repo exception is recorded, not hidden |
| 041 | 1 | Substantive (single comms gem with lazy Telegram require — untested seam, `net/http` in contract load graph) |
| 042 | 1 | Substantive (worker performs the send — connector-zone boundary merely aspirational) |
| 043 | 1 | Substantive (reusing the worker's callback tuple — binds no actor/digest/expiry) |
| 044 | 1 | Substantive (exporter plugin API — unversioned, ungated on the telemetry egress seam) |
| 045 | 1 | Substantive (durable telemetry table — second writer contends with fenced writer, drifts) |
| 046 | 1 | Substantive (capture-by-default + scrub-at-export — cannot prove what never reached the journal) |
| 047 | 1 | Substantive (record-time sampling in an in-memory window — paused turns lost, safety evidence dropped) |
| 048 | 1 | Substantive (second SDK adapter — no exact wire bytes, dual credential/failure paths) |
| 049 | 5 | The model: hard-revert, keep-approve-everything, class-only gate, model-declared risk, separate approval-strength store — each with its reason |
| 050 | 3 | Substantive (threshold-action engine in observability; auto-restart/approve; in-memory alert window) |
| 051 | 3 | Substantive (keep ruby_llm types; compat alias; leave removal implicit under 048 — a rejection row that justifies the ADR's own existence) |
| 052 | 3 | Substantive (keep monolith; split-by-layer; plugin API) |
| 053 | 4 | Substantive (spread policy; policy-as-Ruby; `--all` flag; compat layer) — a simplicity-creating ADR: 8 rule sites in 4 gems → 1 data file + 1 evaluator |
| 054 | 4 | Substantive (new source mechanism; unreserved ordinary MCP server; raw HTTP tool; leaving 030 stale) |
| 055 | 4 | Substantive (keep plane in Ruby; strict one-repo; Tamoz as gRPC client/authority; shared DB instead of sealed snapshot) |

## Coverage

| ADR | Is-it-an-ADR? | Lens verdict |
|---|---|---|
| 001 | borderline | Naming/namespace commitment is expensive to reverse — passes, but ledger empty |
| 002 | yes (tombstone) | Clean stub, no clutter |
| 003 | yes (tombstone) | Clean stub |
| 004 | yes | Real contested trade-off; good deferral of `tamoz-chain`; ledger formally missing |
| 005 | yes | Structural interrupt semantics; ledger formally missing |
| 006 | yes | Matches its design-refusals ownership; ledger incomplete vs digest |
| 007 | yes | Real durability decision; ledger formally missing |
| 008 | borderline | ADR itself argues the default is reversible ("low-stakes") — §1 rule-of-thumb cuts against ADR-hood, but it owns the async-refusal |
| 009 | yes | Real cost-bearing invariant; Tier F with no rejection table |
| 010 | borderline | Support/CI policy, operational rather than architectural |
| 011 | yes | Persistence posture, expensive to reverse |
| 012 | yes (tombstone) | Clean stub |
| 013 | yes | Size-discipline decision in its own right |
| 014 | yes | Core size refusal; formal E3 gap remains |
| 015 | yes | Durability semantics; ledger missing |
| 016 | yes | Effect semantics; ledger healthy |
| 017 | yes | Fencing/split-brain boundary; ledger missing |
| 018 | yes | Checkpoint ordering contract; ledger healthy |
| 019 | yes | Resume compatibility gate; ledger missing |
| 020 | yes | Secret-handling boundary; ledger healthy |
| 021 | yes | Execution identity model; ledger missing |
| 022 | yes | Load-bearing safety gate; the reference page |
| 023 | yes | Learning boundary; full treatment earned |
| 024 | borderline | Product-philosophy definition; enforceable via tamoz-evals metrics, but thin on structure for Tier F |
| 025 | yes | Dependency-graph boundary (evals outside runtime) |
| 026 | yes | Memory authority/lifecycle structure |
| 027 | yes | Retrieval authorization boundary |
| 028 | yes | Remediation boundary |
| 029 | yes | Protocol/dependency boundary |
| 030 | yes | Authority model for all capability sources |
| 031 | yes | Delivery/execution separation |
| 032 | yes | Delayed-authority boundary |
| 033 | yes | Format + execution-concern boundary |
| 034 | yes | Identity + promotion boundary |
| 035 | yes | Continuous/episodic boundary; honest revision |
| 036 | yes | Admission-boundary semantics |
| 037 | yes | Continuous-plane contracts; honest revision |
| 038 | yes | Physical-action authority boundary |
| 039 | yes | Product scope refusal |
| 040 | yes | Repo strategy; exception recorded honestly |
| 041 | yes | Transport seam as a tested seam |
| 042 | yes | Process/trust boundary |
| 043 | yes | Deny-only transport rule + change bar |
| 044 | yes | Telemetry egress seam |
| 045 | yes | Data-authority refusal |
| 046 | yes | Capture-default boundary |
| 047 | yes | Sampling boundary |
| 048 | yes | Single-transport rule |
| 049 | yes | The reference ADR |
| 050 | yes | Proposed, honestly marked not-yet-implemented |
| 051 | yes | Removal record with its own reasoning, justified against 048 |
| 052 | yes | Gem-granularity rule; honest cost and coupling watch |
| 053 | yes | Policy-as-data consolidation |
| 054 | yes | Source-set extension without new mechanism |
| 055 | yes | Authority split; every simpler path explicitly rejected with reasons |

## Findings

1. **P1 — Tier F contested decisions carry no rejection ledger: 015, 017, 019, 021 (plus formal gaps 009, 014).** These are safety-bearing, genuinely contested choices — 015 explicitly weighed an "async durable" mode, 017 could have been optimistic concurrency, 019 could have been best-effort resume, 021 could have reused the source execution id on fork — and none of it is recorded as a rejection. §2.7 requires the section at every tier; §0.2 says an unrecorded rejection "is an invitation to re-add the thing we already rejected." On a durability/authority boundary that invitation is the expensive kind. Fix: one rejection row each, transcribed from the argument already in Context/Consequences (015: async-durable barrier return — quietly weakens every resume guarantee; 017: fenceless/optimistic writes — zombie commits; 019: best-effort resume — user code against a mismatched graph; 021: fork-reuses-source-id — effect leakage into re-execution).
2. **P2 — Systemic early-corpus gap: 14 of 52 live ADRs have no `Rejected alternatives` section** (Tier C: 001, 004, 005, 007, 008, 010, 011, 013; Tier F: 009, 014, 015, 017, 019, 021). In every case the losing alternative is argued in Context/Consequences prose — the analysis exists, only the ledger is missing — so the fix is transcription, not new analysis. But as it stands §0.2's mechanism ("size discipline is enforced by writing down every rejection") does not operate on anything decided before ADR-016.
3. **P2 — design-refusals.md points at analysis that is not there (ADR-006, ADR-008).** The digest owns two refusals to ADR-006 ("A `Memory` abstraction class family", "Config-dict behaviour dispatch") and one to ADR-008 ("no async/await API beside the sync one"), and says the "full rejected-alternatives analysis lives" in the owning ADR. ADR-006's table holds only `Data`/`Struct`-typed state; ADR-008 contains no rejection row at all (only an oblique `:fibers requires async, lazily`). Fix: backfill the rows, or re-point those three digest rows at GOAL non-goals.
4. **P3 — Verbatim Context→Decision duplication inflates pages** (010 "Ruby 3.2 reached end-of-support before the design date" opens both sections; same pattern in 008, 009, 011, 013, 043). §2.4 says Context states the problem, not the solution restated; the duplication adds length without information — contrary to the quarter-the-size thesis the corpus itself enforces.
5. **P3 — ADR-035's title no longer states its live rule.** "Streaming input is a distinct first-class runtime" was written when the distinct runtime was Ruby `tamoz-stream`; post-055 the decision is that the continuous plane lives in an external Go runtime and `tamoz-stream` is only the episode worker. The body is honest, but title-as-claim now delivers yesterday's architecture to anyone indexing by title (§2.1). Fix: retitle to the live claim, or fold into 055 and leave a tombstone.
6. **P3 — Sprint-plan content inside the reference ADR.** ADR-049 §9 "Adoption" is a three-step implementation checklist — precisely what §1's table puts on the *not*-an-ADR side ("a plan for *how* to implement it this sprint — that is a `docs/*_PLAN.md`"). Three inert lines, but the corpus's model page models the exception to its own rule. Also: 049's Next reads links `README.md` twice (lines 111/114) — one more instance of the finding-4 duplication pattern.
7. **Overlap scan — no consolidation flag anywhere; no cross-ADR contradiction.** Tested by reading both members: durability 015/016/017/018 (when a barrier returns / what happens to an ambiguous effect / who may write / how checkpoints order); resume 019/021 (compatibility gate / identity model); observability 044/045 (gem structure / data authority); transport 048/051 (051's rejection row "leave the removal implicit under ADR-048" is its own justification for separate existence); decomposition 002→052 and 040/052/055 (repo count / gem granularity / language-authority split — three questions, no double ownership, and 055 explicitly rejects the simpler paths "strict one-repo" and "keep the plane in Ruby" with structural reasons); skills 033/034 (format+execution / identity+promotion); streaming 035/036/037/055; comms 041/042 (library seam / process boundary). No ADR re-introduces an abstraction design-refusals.md refuses. No P0.
8. **Counter-evidence: the ledger discipline works where it is practiced.** 016 onward, every live ADR carries ≥1 substantive rejection with the reason it lost; 022/023/049/050/053/055 are full-fidelity pages; 053 is simplicity-*creating* (8 rule sites in 4 gems → 1 data file + 1 evaluator). The gap in findings 1–2 is a discipline gradient over time, not a corpus-wide inability — which is what makes the backfill cheap.

## Summary

**Counts.** 55 files: 52 live (51 Accepted, 1 Proposed — 050, honestly marked unimplemented) + 3 tombstone stubs (002, 003, 012 — all the correct short shape per §5). Rejection ledgers: **38/52 live ADRs carry a Rejected-alternatives section; all 38 are substantive** (real alternative + reason it lost) — zero boilerplate rows. **14 lack the section**: 8 at Tier C (001, 004, 005, 007, 008, 010, 011, 013), 6 at Tier F (009, 014, 015, 017, 019, 021). Is-it-an-ADR screen: 49 clear yes, 3 borderline (001 naming, 008 self-declared low-stakes default, 010 support policy), **0 records of implementation detail masquerading as ADRs**. Overlap scan: every tested cluster owns its territory twice-checked; **no consolidation required, no cross-ADR simplicity contradiction, no P0**. Severity tally: 0 P0 · 1 P1 · 2 P2 · 4 P3 · 2 informational.

**Verdict on the lens question** — does the corpus enforce "a quarter of the size with the same guarantees"? The refusal machinery is real and increasingly well kept: design-refusals.md indexes the cross-cutting refusals, the closed-set rule is re-affirmed rather than eroded across 014/030/041/044/052/054, and 053/054 actively *delete* or avoid machinery. But the first third of the corpus (001–021) made its choices without recording its rejections — and rejections are the exact mechanism §0.2 names for keeping the framework small.

**Top 3 issues.**
1. (P1) Six Tier F pages — including the four contested durability/identity decisions 015/017/019/021 — record no rejected alternative, on the boundaries where a re-add would be most expensive.
2. (P2) The systemic early-corpus ledger gap (14 ADRs) — cheap to fix, since the losing alternatives are already argued in prose and only need transcribing into tables.
3. (P2) design-refusals.md claims the full analysis for three of its rows lives in ADR-006/ADR-008, where it does not — the size-discipline index over-states the ledger beneath it.

**Questions for the owner.**
1. Backfill strategy for the 14 missing ledgers: mechanical transcription into one-row tables for all 14, or amend only the six Tier F pages and leave terse Tier C records terse?
2. For the three design-refusals rows pointing at 006/008: backfill the ADR tables, or re-point those rows at GOAL non-goals?
3. ADR-035: retitle to the post-055 live claim, or fold it into 055 and retire the stub?
4. ADR-052's "coupling to watch" names `Tamoz::Core` at 203 dependents — the monolith-recreated-by-dependency risk the ADR itself flags. Is the standing `diff_snapshot` review scheduled, and is 27-gem granularity the settled answer to the quarter-the-size bet, or an open question the corpus should record as one?
