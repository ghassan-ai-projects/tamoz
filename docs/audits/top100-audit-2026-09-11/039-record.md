# Audit 039 — `gems/tamoz-core/lib/tamoz/circuit/record.rb`

Rank 39 · 679 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: SIZE

The immutable-transition design is sound and well defended, but the record class carries the
condition sub-state engine alongside schema validation, and two helpers break the repo's own
ceilings.

## Findings

- **[major][SIZE]** The single Record class mixes persisted-payload schema validation
  (`validate_*` class methods), the condition predicate/sub-state engine (`condition_met?`,
  `apply_failure_condition`, `count_*`, `append_*`, `prune`, `bound_*`), and the transition
  surface. Owning seam: a condition-engine module beside the record, as `Evidence`/`Registry`
  already are. (record.rb:83-227, 522-659)
- **[minor][SIZE]** `with_failure` takes 6 keyword params, over the ≤5 ceiling; a failure-event
  value would group kind/context/run/fingerprint. (record.rb:336-355)
- **[minor][DUP]** Hand-rolled private `deep_copy` while tamoz-core already owns the deep-copy
  discipline (`Core.deep_freeze`) and tamoz-stream hand-rolls `deep_dup` — a third spelling of an
  existing capability. The shared utility belongs in core. (record.rb:669-676)

## Resolution — 2026-09-11

- **[minor][DUP] fixed, but NOT via the suggested remedy.** The finding proposes reusing
  `Core.deep_freeze`; that is a **different operation** and would have broken these call sites.
  `deep_freeze` stringifies keys, freezes the result, and raises on unsupported types, whereas
  `with_failure` deep-copies `owners` precisely in order to MUTATE the copy
  (`next_owners[owner] ||= …`, then `apply_failure_condition` mutates the entry) — a frozen,
  string-keyed structure fails immediately. The real duplication is between record's `deep_copy`
  and tamoz-stream's `deep_dup`, two spellings of a deep MUTABLE copy. Added
  `Tamoz::Core.deep_dup` beside `deep_freeze` (dups keys and strings, preserves key types) and
  routed BOTH `Circuit::Record` and `Stream::DecisionBuilder` through it, deleting both private
  copies. tamoz-stream already requires tamoz/core, so no new dependency edge — dependency
  isolation and public-API gates both green.
- **[minor][SIZE] fixed.** `with_failure` was a genuine `ParameterLists` 6/5 violation (measured
  directly, bypassing the `.rubocop_todo.yml` exclusion). Introduced
  `Record::FailureEvent = Data.define(:kind, :context_digest, :run_id, :fingerprint)` — a
  cohesive "one failure occurrence" value, not an arbitrary bundle — so `with_failure(owner_id:,
  now_ms:, event:)` names the actor, the clock and the occurrence. Threaded the same value into
  `apply_failure_condition` (also 6/5). record.rb now has **zero** ParameterLists violations.
- **[major][SIZE] pending.** Splitting the condition predicate/sub-state engine out of `Record`
  into its own module (beside `Evidence`/`Registry`) is still open.
