# Audit 026 — `gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb`

Rank 26 · 761 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 3 minor) · Bar fails: SIZE, DEAD, DUP

The single-transaction atomicity seam is honored exactly, but a dead lease API, an ignored
`lease_for`, oversized transaction methods, and a threaded boolean flag need cleanup.

## Findings

- **[major][SIZE]** `put_schedule` is 51 lines (CAS read + insert + re-select + materialization
  inline) and `materialize_due` 38, both past the 30-line hard ceiling. Owning seam: the file's own
  statement/row-shaping helper pattern. (schedule_store.rb:41-91, 163-200)
- **[minor][DEAD]** `renew_occurrence_lease` has no caller anywhere (grep-proven: only its def, the
  tamoz-scheduler interface def, and the contract-test double), and both it and `materialize_due`
  accept `lease_for:` the implementation never reads (worker.rb:154 passes 60) — a misleading store
  contract owned by the tamoz-scheduler interface. (schedule_store.rb:484-505, 163-164)
- **[minor][DUP]** The latest-revision JOIN subquery is copy-pasted between `list_schedules` and
  `materialize_due`. (schedule_store.rb:104-116, 169-183)
- **[minor][SIZE]** `include_provenance:` boolean threaded through five methods (`materialize_due`,
  `claim_with_conflict_record`, `claim_one_schedule`, `enqueue_occurrence`,
  `build_request_payload`). Owning seam: an open-vs-closed payload builder.
  (schedule_store.rb:163-208, 414-415, 699-711)

## Resolution — 2026-09-11

- **[minor][DUP] fixed.** The latest-live-revision JOIN, copy-pasted in `list_schedules` and
  `materialize_due`, is now the `LATEST_REVISION_JOIN` constant interpolated into both, so
  they cannot drift.
- **[minor][DEAD] fixed (renew_occurrence_lease).** Grep-proven dead (only its def, the
  tamoz-scheduler interface def, and the contract-test double — zero real callers). Removed
  from all three: the SQLite impl, the `Tamoz::Scheduler::ScheduleStore` interface, and the
  contract-test fake. The contract parity test iterates the interface's own methods, so the
  three stay consistent (28 scheduler tests green).
- **[minor][DEAD] lease_for — declined.** `materialize_due` ignores `lease_for:`, but it is a
  declared keyword of the `Tamoz::Scheduler::ScheduleStore` v2 contract and is passed by
  ~40 call sites (worker + tests + smoke corpus). Removing it is an interface change with
  large ripple and a contract-version bump for an inert param; not worth it against the
  accepted-debt posture. Left as a documented no-op keyword.
- **[major][SIZE] deferred.** `put_schedule` (46/20) and `materialize_due` (33/20) exceed the
  ceiling, but each is one atomic transaction (CAS read → insert → re-select → materialize)
  whose steps share the txn handle and read as a single unit; extracting mid-transaction
  helpers would scatter the atomicity that makes them correct. Left as intrinsic
  transaction-method debt (consistent with the file's other txn methods).
- **[minor][SIZE] include_provenance — left.** A threaded boolean, but it selects
  open-vs-closed provenance in the payload builder; splitting into two builders duplicates
  the surrounding claim/enqueue flow. Minor; not worth the duplication.
