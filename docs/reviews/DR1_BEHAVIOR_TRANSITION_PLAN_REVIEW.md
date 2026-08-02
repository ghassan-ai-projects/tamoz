# DR-1 behavior-transition design review

Verdict (revision 1): **REJECT** — the two load-bearing claims were false against the
code. Verdict (revision 2): re-review ACCEPT-WITH-REQUIRED-CORRECTIONS (C1–C8,
integrated into revision 3).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02), two
passes.

## Revision 1 rejection — verified findings

1. **No multi-key Store transaction exists** (`store.rb` `put`/`delete` CAS is
   per-key). The session record (incl. `behavior_version`, `prompt_surface_digest`)
   commits through the graph CHECKPOINT, not the Store; the transition registry is a
   Store namespace — two storage systems, two transactions. The "one transaction,
   four artifacts" claim was fiction.
2. **`prompt_surface_digest` covers the tool+skill catalogs only**
   (`toolbox.rb:182-183`: `[catalog_digest, skills.catalog_digest]`); no digest covers
   the system-content axis at all; a Wisdom-only promotion changes none of its inputs.
3. **`behavior_version` is frozen at intake** (`session_nodes.rb:74`, from the
   constant); no existing-thread path rewrites it; resume is `boundary: false`
   (`cli.rb:214/224/309`).
4. The model-visible prefix is built at call time from constants + the current
   toolbox; no prefix bytes are stored — `prefix_digest_before/after` could not be
   restored to bytes (T4 unimplementable).

The salvageable core (one shared record, turn-boundary-only consumption, evidence
gates, no in-flight mutation) was accepted; the assertions about existing code were
the disqualifying part.

## Revision 2 — corrections integrated

- **Two-phase activation** (claim → apply → finalize): the registry CAS
  (`:recorded → :claimed`) gates BEFORE any checkpoint write (closes the concurrent-
  consumer race); the checkpoint commit applies the new version + snapshot; finalize is
  idempotent keyed by `transition_id`. Crash rules defined per phase.
- **Durable behavior snapshot** in the session record (bounded content, mirrors
  `Profile.from_authority` replay) so resume serves the EXACT pinned content and
  rollback restores bytes, not digests.
- **Extended prompt-surface identity**: `prompt_surface_digest` gains
  `behavior_snapshot_digest` as an input (the invariant-16 system-content axis finally
  digested); session record gains `epoch_reason`.
- **Intake-only consumption** in v1 (existing threads cannot consume — the record is
  frozen; stated honestly); mid-thread adoption deferred with its invariant-22
  treatment named.
- **`verify_behavior_binding!`** on resume (template: `verify_skill_binding!`),
  content comparison not record-value comparison.
- Failure model rebuilt on real mechanisms (claim conflict, claim expiry, snapshot
  unavailability, evidence resolution, rollback version check); T1–T7 include crash
  injection.

## Held-out probes (revision-1 review)

Crash between phase-1 checkpoint and phase-2 registry write (double activation);
two threads consuming one candidate concurrently (unauthorized /2 session);
in-flight durable turn resumed after activation (silent behavior change);
rollback racing a second consumption; Wisdom-only promotion with zero tool/skill
delta.

## Revision 2 re-review — verified fixes + corrections (integrated into revision 3)

Verified FIXED in rev2 (the revision-1 rejection's findings): per-key CAS atomicity
(whole read-check-write in one SQLite transaction); the two-phase model assumes no
multi-key transaction; `behavior_version` frozen at first intake (only write site is
session_nodes.rb:74); `boundary: true` only for ask/follow-up; the extended digest is
non-breaking (nothing pins `prompt_surface_digest`; `enforce_skill_binding!` compares
`skill_epoch` only).

Corrections (C1–C8, integrated into revision 3):

| # | Sev | Finding | Disposition (rev 3) |
|---|---|---|---|
| C1 | High | Claim-expiry can release an applied-but-unfinalized transition (crash between apply and finalize + lease expiry → re-claim → `/3` double-bump) | Release of a `:claimed` row permitted ONLY after proving no committed session references the transition via `epoch_reason`; if such a session exists, release runs FINALIZE; one mechanism pinned (owner-review sweep with lease holder identity + TTL); T7 interleaving test |
| C2 | Med-High | Crash between claim and apply blocks the same user's retry (claim CAS fails against the stuck `:claimed` row) | Claim carries claimant {owner, attempt}; same-owner re-claim with no committed session = take-over allowed; T7 retry-path test |
| C3 | Med-High | Two pipelines can record the same `behavior_version_after` (no version counter) | Version allocated AT RECORD TIME by CAS on a single current-version row; record-time conflict → re-record; T5 covers two transitions targeting the same version |
| C4 | Medium | Inline snapshot unbounded; invariant-24 only catches Secret OBJECTS, not plain-string sensitive content | `MAX_BEHAVIOR_SNAPSHOT_BYTES` + secret-shaped content rejected at record/claim; Store-sensitive alternative documented |
| C5 | Medium | Model-settings axis still undigested; whole-prompt byte comparison ill-posed | Model settings deferred (named follow-up); digest domain over a DELIMITED injection region so content comparison is well-posed |
| C6 | Medium | P11-W/P12 plans contradict rev2 (old existing-thread model, outdated field list) | Both phase-plan paragraphs rewritten to revision-3 semantics |
| C7 | Low | Review doc citation dangled | Doc exists (this file) |
| C8 | Low | `put if_version: recorded` is wrong at the API level (Integer version, not status); `:finalized` never set; "only Store write" imprecise | get-then-CAS wording; `:finalized` dropped; two phases + eval_evidence write noted |

## Held-out probes (revision-2 re-review)

Lease expiry firing with a committed `/2` session (finalize, never release); retry
after crash-between-claim-and-apply (take-over); two pipelines racing version
allocation (record-time CAS).

## Status

Revision 3 in `docs/DR1_BEHAVIOR_TRANSITION_PLAN.md` (C1–C8 integrated). The P11/P12
plans cite DR-1 as the BehaviorTransition owner and have been synced to revision-3
semantics.
