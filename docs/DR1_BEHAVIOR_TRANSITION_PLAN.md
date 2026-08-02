# DR-1 — BehaviorTransition and behavior/cache epochs: shared promotion machinery

Status: design round — revision 3 (re-review ACCEPT-WITH-REQUIRED-CORRECTIONS on
revision 2; C1–C8 integrated; see `docs/reviews/DR1_BEHAVIOR_TRANSITION_PLAN_REVIEW.md`)
Origin: P11 plan review C3; P12 plan review C4/C5; DR-1 deep review (rejected rev1 —
verified: no multi-key Store transaction; `prompt_surface_digest` covers catalog+skills
only; `behavior_version` frozen at intake); DR-1 re-review (rev2 core verified sound:
per-key CAS atomic, two-phase model holds, intake-only matches behavior, extended
digest non-breaking).
Authoritative inputs: `AGENT_DESIGN.md` §§12–14, invariants 16, 19, 22, 24, 28, 29,
35, `MEMORY_DESIGN.md` §7, `SELF_HEALING_DESIGN.md` §11, the P8 `ProfileTransition`
pattern, the session record + epoch seams, and `cli.rb`'s
`resolve_session_authority`/`Profile.from_authority` replay.

## 1. Problem

Two promotion pipelines (P11-W Wisdom, P12-I heuristic) must land behavior changes
without a second promotion engine and without silently violating invariant 16/28.
Verified constraints: the session record commits through the graph checkpoint
(invariant 19), NOT the Store; the Store CAS is per-key (atomic read-check-write in
one transaction — confirmed); `prompt_surface_digest` covers tool+skill catalogs only;
`behavior_version` is frozen at the first intake of a thread (ask on an existing
thread does NOT re-run intake — "new-session intake only" == "first intake of a
thread"); resume/continue/redirect are `boundary: false`.

## 2. Design decision

A `BehaviorTransition` is a durable, singly-writer record with a **two-phase
activation** model; activation applies at **first-intake-of-a-thread only** in v1.
P11-W owns the record + consumption mechanics; P12-I reuses them.

```ruby
BehaviorTransition = Data.define(
  :transition_id,          # sha256(kind + candidate_digest) — identity does NOT include time
  :kind,                   # :wisdom_promotion | :heuristic_promotion
  :candidate_id, :candidate_digest,
  :behavior_version_before,:behavior_version_after,
  :behavior_snapshot,      # the durable system-content delta (bounded inline bytes, C4)
  :rollback_target,        # {behavior_version:, snapshot_digest:}
  :activation_scope,       # v1: :first_intake_of_thread (per-thread scoping dropped)
  :promotion_evidence_digest, :human_gate_evidence,
  :claimant,               # {owner: <pipeline>, attempt: <id>} — C2 claim identity
  :status,                 # :recorded | :claimed | :activated | :rejected | :rolled_back
                           #   (C8: :finalized dropped — no path sets it)
  :consumed_by,            # session record id that activated it
  :created_by, :recorded_at, :activated_at, :rolled_back_at
)
```

**Version allocation (C3):** `behavior_version_after` is assigned AT RECORD TIME by
CAS on a single current-version row (Store `tamoz.agent.behavior.current`, value =
current version). A record-time CAS conflict (two pipelines recording `after=v2` from
`before=v1`) requires re-record of the loser — the monotonic version space is ENFORCED,
not aspirational. T5 covers two transitions targeting the same version.

**Where each artifact lives:**

| Artifact | Storage | Why |
|---|---|---|
| transition registry row | Store namespace `tamoz.agent.transitions`, keyed `kind/candidate_digest` | per-key CAS (get-then-CAS on the version number, with status re-check from the get — C8) |
| behavior snapshot (content bytes) | session record (`behavior_snapshot`, BOUNDED inline, C4) | resume must replay EXACT content; mirrors `Profile.from_authority` replay |
| behavior_version + extended prompt-surface digest + epoch reason | session record, committed in the graph checkpoint | atomic with all intake state (invariant 19) |
| current-version row | Store `tamoz.agent.behavior.current` | version allocation CAS (C3) |
| promotion/human-gate evidence | Store namespace `tamoz.agent.eval_evidence` (written by tamoz-evals) | referenced by digest |

## 3. Two-phase activation (claim → apply → finalize)

1. **Claim (Store CAS):** `:recorded → :claimed` via get-then-CAS, carrying
   `claimant {owner, attempt}`. Exactly one consumer wins per transition_id; the loser
   never builds a `/2` session.
2. **Apply (checkpoint commit):** intake commits the new session record carrying
   `behavior_version_after`, the snapshot, the extended digest, and `epoch_reason =
   transition_id`. Atomic with all intake state (invariant 19).
3. **Finalize (Store CAS):** `:claimed → :activated` with `consumed_by`, keyed by
   `transition_id`.

**Crash rules (C1/C2 — release ordered against finalize):**

- crash before 1: `:recorded`; nothing applied.
- crash between 1 and 2: `:claimed` with claimant identity, no committed session. The
  **same-owner re-claim is allowed** (take-over) when no committed session references
  the transition (C2) — a user retry on the crashed thread proceeds; a DIFFERENT owner
  is refused until release.
- crash between 2 and 3: committed `/2` session (its `epoch_reason` names the
  transition) + `:claimed` row. **Release of a `:claimed` row is permitted ONLY after
  proving no committed session record references `transition_id` via `epoch_reason`
  (or `behavior_version_after`); if such a session exists, the release path runs
  FINALIZE instead** (C1). Release is owner-review-only with a defined sweep (mirroring
  the sqlite lease machinery), or the lease holder identity + TTL is specified — one
  mechanism, pinned: owner-review sweep with a lease holder identity, TTL bounded, and
  the finalize-first check.

**Consumption surface (v1): first intake of a thread.** Existing threads cannot
consume (record frozen at intake; resume/continue/redirect `boundary: false`); they
keep the pinned version and replay the pinned snapshot. Mid-thread adoption deferred
with its invariant-22 treatment named.

## 4. Extended prompt-surface identity and the cache epoch

`prompt_surface_digest = sha256(domain + [catalog_digest, skills.catalog_digest,
behavior_snapshot_digest])` — the invariant-16 "canonical system content" axis finally
digested. **Digest domain over a delimited injection region (C5):** the behavior
snapshot is injected as a delimited, findable block in the prompt (fixed markers), and
`behavior_snapshot_digest` hashes exactly those canonical bytes — so
`verify_behavior_binding!` content comparison is well-posed (region compare, not
whole-prompt). The session record gains `epoch_reason` (invariant 16 "records a
reason").

**Model settings axis (C5):** invariant 16's "model settings" axis remains undigested
and is DEFERRED to a named follow-up (recorded in this DR; the model identity used by
a turn is outside the behavior-transition scope). The DR's "finally digests" claim is
scoped to the system-content axis only.

## 5. Snapshot bounds and sensitive content (C4)

- `MAX_BEHAVIOR_SNAPSHOT_BYTES` defined (e.g. 4 KiB, MemoryLimits order).
- Snapshot-content policy: secret-shaped content is rejected at record/claim (mirroring
  the `CREDENTIAL_ENV_PATTERN` approach in toolbox); invariant-24 `reject_sensitive!`
  only catches Secret OBJECTS, so the plain-string policy is the enforcement.
- Alternative (documented): move the bytes to Store `tamoz.agent.eval_evidence` with
  `sensitive: true`, digest + resolved reference in the session record, resume verifies
  the digest before replay. v1 chooses bounded inline + content policy; the alternative
  is the fallback if inline breaks the checkpoint size contract.

## 6. Human-gate and evidence

- `promotion_evidence_digest`: digest of the eval artifacts (DR-3 artifacts; written by
  tamoz-evals, verified at claim time).
- `human_gate_evidence`: digest of a real approval artifact (actor, timestamp, class
  assignment). Class-assignment authority decided by the promotion pipeline per its
  phase gates; T6 resolves the digest to a real artifact.

## 7. Resume binding and rollback

- The session record carries the pinned snapshot; resume replays it (mirrors
  `Profile.from_authority`); `verify_behavior_binding!` (template:
  `verify_skill_binding!`) compares the SERVED injection region against the pinned
  snapshot (content comparison, not record values).
- Rollback: restores `behavior_version_before` + the before snapshot; guarded by
  `if_version` CAS on status `:activated` AND a check that the current version equals
  `behavior_version_after`; mismatch → fresh rollback transition. Byte-identical
  restore possible (content stored, delimited region).

## 8. Failure model

| Situation | Type | Behavior |
|---|---|---|
| two consumers race one transition | `BehaviorTransitionClaimConflictError` (typed value) | CAS loser; never builds a session |
| same-owner retry after crash-between-claim-and-apply | take-over allowed | re-claims; proceeds |
| release attempted while a committed session references the transition | release runs FINALIZE | never release-then-re-apply (C1) |
| resume cannot rebuild the pinned snapshot | `BehaviorSnapshotUnavailableError` (terminal) | resume stops typed |
| promotion/human-gate evidence missing or unresolvable | `UnverifiedTransitionError` (terminal) | candidate never claims; `:rejected` |
| rollback version mismatch | `BehaviorVersionConflictError` | fresh rollback transition required |
| two pipelines race version allocation | record-time CAS conflict | loser re-records (C3) |
| secret-shaped snapshot content | policy rejection | refused at record/claim (C4) |

All under `Tamoz::Agent::Error`; claim conflicts are typed values, missing evidence and
snapshot unavailability are terminal.

## 9. Acceptance tests

- T1 first-intake-only consumption; in-flight existing thread's served prompt unchanged.
- T2 extended digest: Wisdom-only promotion moves the behavior-content digest AND
  records `epoch_reason` = transition_id; no-op activation rejected at claim.
- T3 resume replay: a pinned-thread session resumed after activation is served the
  pinned snapshot (region content comparison).
- T4 rollback byte-identical; guarded by the version check.
- T5 version allocation: two transitions targeting the same version → one records, the
  other re-records (CAS); two consumers on one claim → one wins.
- T6 evidence-backed: missing/unresolvable evidence → `:rejected` before claim.
- T7 crash injection: kill between claim/apply/finalize in both orders → exactly-once
  activation; **lease-expiry-interleaving** (expiry fires while the `/2` session
  exists → finalize, never release); **same-owner retry** after crash-between-claim-
  and-apply proceeds via take-over.

## 10. Consuming phases (C6 — plans corrected to match)

- P11-W implements the record + claim/apply/finalize + intake wiring + resume binding;
  the P11 plan §4 BehaviorTransition paragraph is REWRITTEN to revision 3 semantics
  (intake-only, two-phase, snapshot-in-record, this field list).
- P12-I consumes the seam (`kind: :heuristic_promotion`); the P12 plan §7 turn-boundary
  text is updated to first-intake-only.
- P15-B verifies old-session resume across a behavior-version change (DR-4 prerequisite).
- P16 keeps the extended prompt-surface identity (digest inputs move with the toolbox).

## 11. Review checklist (re-review)

1. Is release-ordered-against-finalize (C1) implementable with a single Store read of
   the session record's `epoch_reason`?
2. Does the record-time version allocation (C3) close the two-pipeline race with one
   extra Store key?
3. Is the delimited injection region (C5) compatible with how the prompt is composed
   (Deliberation::*_SYSTEM constants + toolbox-derived body)?
4. Does the bounded-snapshot policy (C4) hold without breaking the checkpoint size
   contract?
5. Do T1–T7 catch the three re-review probes (lease-expiry with committed session,
   retry after crash-between-claim-and-apply, two pipelines racing version allocation)?
