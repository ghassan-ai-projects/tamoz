# Per-file slice bar

This bar is checked after each file. It does not waive the final requirements in
`BAR.md`; it separates evidence that is available per file from evidence that can only
exist after the full checklist is complete.

- [ ] S1 Scope: only the current file and its per-file evidence note changed.
- [ ] S2 Candidate: the note names the concrete reading-order defect or explains why the
      file remains stable.
- [ ] S3 Story: changed public/top-level functions state their workflow in domain order.
- [ ] S4 Abstraction: changed functions stay at one level and call intent-named helpers.
- [ ] S5 Names: new or renamed helpers add domain meaning and are not wrapper-only names.
- [ ] S6 Preservation: public interfaces, output shapes/bytes, ordering, errors, and side
      effects are unchanged by inspection against the baseline and callers.
- [ ] S7 Restraint: no unrelated cleanup, duplicate machinery, compatibility shim, or
      speculative behavior was added.
- [ ] S8 Hygiene: no scratch files; docs are `0644`; the slice is ready for an
      orchestrator-owned commit.

Deferred until every item is processed: the repository tests and quality gates, the
post-change Enola snapshot/diff, the aggregate file checklist, and final commit hygiene.
