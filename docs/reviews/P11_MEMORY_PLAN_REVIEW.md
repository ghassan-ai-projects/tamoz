# P11 memory plan review

Verdict: accept-with-required-corrections (revision 2 integrated the corrections).
Reviewer: fresh-context plan critic (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/P11_MEMORY_PLAN.md` revision 1 against `MEMORY_DESIGN.md`,
INVARIANTS.md 24–31/16–18, the P11 handover card, `store.rb`, session-record/skill
binding patterns, and the eval harness.

## Findings and dispositions

| # | Sev | Plan section | Finding | Disposition (rev 2) |
|---|---|---|---|---|
| C1 | Critical | §4 P11-B / §5 | Authorization-first pipeline unimplementable on the Store surface: `each` filters by key prefix only and materializes (decrypts) sensitive rows; plan self-contradicted (index forbidden before D2, yet B before D2) | Lexical index is an explicit P11-B work item (SQL-filtered columns, no decryption of unauthorized rows); D2 index-propagation precedes B; honest-searchable claim made precise |
| C2 | Critical | §4 P11-E/W | Decisive metric + protected holdout unmeasurable: no treatment/holdout machinery exists in tamoz-evals | P11-ED work package added; two-layer gating; decisive metric defined (see DR-3 for the further correction that CI = injection correctness, live = attribution) |
| C3 | High | §3/§4 P11-W | `BehaviorTransition` undefined; invariant-16/28 cache-epoch interaction missing; P11-W→P12-I handoff undeclared | BehaviorTransition specified; ownership given to DR-1 (record + turn-boundary consumption); cache-epoch-change test added |
| C4 | High | §3 | No legacy sentinel → pre-memory sessions resume with undefined memory behavior | `memory_epoch` optional field with `"none"` sentinel (P9 pattern); resume test |
| C5 | High | §3/§4 P11-B | Retrieval-eligible state set undefined; `rejected` not a state; expiry has no transition; no compatibility field | Eligible = active ∪ consolidated; `rejected` first-class; expiry transition (system actor); `compatibility` field added |
| C6 | High | §4 P11-D2 | Hard-delete after retention boundary has no owner; no version-read for supersession links; invariant-54 receipt unused | Purge owner (tamoz-agent maintenance pass, mirroring thread-purge); prior-version digest carried in new record; invariant-54 receipt shape |
| C7 | High | §3 admission | Primary admission criterion is a model judgment on a no-provider path | Deterministic admission gate (episode/owner-request/consolidation-gates); model proposes, never admits |
| C8 | Medium | §3/§7 | No typed failure model | Failure-model table added (memory classes over the D-7 taxonomy) |
| C9 | Medium | §4 P11-B/§3 | Token budget not implementable as specified; `MemoryLimits` not enumerated | `MemoryLimits` enumerated with overflow behavior (truncate by rank; injection drop recorded) |

## Held-out probes suggested by the critic

Decryption-boundary leak (unauthorized sensitive rows never decrypted during a scan —
became a required probe); consolidated-state eligibility; Wisdom cache epoch; pre-P11
resume sentinel; retention-boundary purge physically removing ciphertext rows.

## Status

Corrections integrated in `docs/P11_MEMORY_PLAN.md` revision 2 (2026-08-02). The
decisive-metric correction is further refined by DR-3 (memory evaluation substrate),
whose review found the CI "attributable reuse" claim was a scripted tautology — the P11
plan's P11-ED section must be read together with DR-3 revision 2.
