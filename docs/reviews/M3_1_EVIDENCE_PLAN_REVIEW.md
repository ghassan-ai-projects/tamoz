# M3.1 evidence-plan review

Review target: [M3_1_EVIDENCE_PLAN.md](../M3_1_EVIDENCE_PLAN.md)

Decision: accepted for implementation after the corrections below.

## Review method

The review started from every residual or future-evidence statement in `M3_PLAN.md`,
`M3.md`, and `M3_DEEP_REVIEW.md`, then mapped it to a direct observable. It attacked the
harness as production software: correlated oracles, false coverage, inherited connections,
target-ledger corruption, platform skips, flaky performance, artifact leakage, sharding,
and evidence from the wrong revision.

The review also compared the proposed work with the user-required phase discipline. M3.1
gets a plan commit first; every implementation slice then receives its own deep review,
full regression gate, and atomic code commit before the next slice starts. Evidence reports
remain separate from subject-code commits. M3.1 does not begin M4 or M5a.

## Findings resolved

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | Tracing existing hooks could report “complete coverage” while durable file boundaries have no hook. | Hook reachability and boundary completeness were conflated. | Add a versioned boundary registry, fail on blind spots, and permit metadata-only hooks around database/backup file creation and mode publication. |
| Critical | Reopening through Tamoz APIs could reproduce the same bug as the transition under test. | Production materialization had been treated as an independent oracle. | Observe raw rows through a separate SQL/reference projector; Tamoz recovery is a second convergence check, not the atomicity oracle. |
| Critical | A plain append-only file used as external-effect truth can itself be torn by `SIGKILL`. | “Outside Tamoz” was mistaken for “durable.” | Use an independent `synchronous=FULL` SQLite target ledger with its own old/new integrity oracle. |
| Critical | A requested kill selector could silently never fire and still leave a recoverable database. | Child death alone does not prove the intended boundary was exercised. | The child fsyncs a selector control record and blocks; the parent validates it and sends `SIGKILL`; missing, mismatched, or unfired selectors fail. |
| Critical | A static inventory could remain aspirational while direct file mutations bypass instrumentation. | A document list does not constrain implementation paths. | Add a versioned boundary registry, instrumented file wrappers, per-operation declarations, and a structural test rejecting direct file mutation outside the wrappers. |
| High | A successful-path trace omits retry/busy paths. | Trace derivation was scoped to one execution path. | Record separate real-lock/retry traces and include them in the coverage manifest. |
| High | A monolithic matrix would be slow enough to invite selective local execution. | Coverage was complete but not operationally composable. | Shard deterministically by scenario/hook digest and verify disjoint full-manifest convergence on merge. |
| High | Treating every dynamic occurrence as a distinct target makes loops unbounded and fixture-sensitive. | Runtime occurrence and semantic storage boundary were conflated. | Key coverage by a bounded semantic tuple and classify repeated hooks into fixed first/middle/final/exhausted cases. |
| High | Process-kill children could inherit writable adapters. | Convenience `fork` patterns conflict with sqlite3's process-safety rule. | Every child starts independently and constructs its adapter after process start; parent verification uses another process. |
| High | `SQLITE_FULL` testing could accidentally fill the host filesystem. | Filesystem exhaustion and SQLite page exhaustion were conflated. | Constrain a disposable database with `max_page_count`; never consume the host volume. |
| High | A performance case could fail randomly on shared CI. | Hardware targets and correctness gates were mixed. | Hard-gate latency only on a named reference runner; normal CI hard-gates resource ownership and records latency informationally. |
| High | Evidence could contain usernames, temporary paths, or host identifiers. | “No prompt content” did not cover operational metadata. | Normalize host-specific paths/identities to bounded public labels before canonical artifacts. |
| High | A later report commit could be cited as evidence for code it changed. | Git commit identity and evidence publication identity differ. | Results bind exact subject revision/tree; a report may cite the preceding code commit only when its own diff is report-only and reviewed. |
| Medium | Transaction-attempt metadata is absent from some current statement hooks. | The proposed selector assumed uniform hook metadata. | The bounded semantic selector is authoritative; attempt is classified only when supplied. |
| Medium | RSS cannot reliably return to an exact baseline after Ruby GC. | Allocator retention was being treated like owned-resource leakage. | Hard-gate connections/threads/FD/WAL ownership; report RSS/heap with tolerance and trend attribution. |
| Medium | The workstation lacks Ruby 3.4/4.0. | Declared CI coverage had been mistaken for executed local evidence. | State the external gate explicitly and accept only exact-revision matrix jobs as proof. |
| Medium | Backup publication has valid old/new filesystem outcomes around rename. | One database-state oracle cannot describe file publication. | Give backup hooks explicit destination/temp existence, mode, digest, and reopen states. |
| Medium | One large implementation commit would weaken phase-level review and rollback. | “Milestone commit” was applied too broadly to eight independent slices. | Make each slice a reviewed phase with focused/full tests and its own atomic commit; commit reports separately. |

## Five Whys: false kill coverage

1. Why can a kill suite pass without covering every boundary? It can iterate only the hooks
   production currently emits.
2. Why is hook enumeration insufficient? A missing hook is invisible to runtime tracing.
3. Why would a boundary lack a hook? File creation and permission publication were added
   outside the transaction wrapper that owns SQL hooks.
4. Why did prior tests not expose this? They killed high-risk checkpoint hooks and injected
   exceptions elsewhere; they did not prove boundary inventory completeness.
5. Why does the corrected design work? A reviewed versioned registry, instrumented file
   wrappers, and per-operation declarations are compared with trace reachability, so missing
   instrumentation is itself a failing treatment.

## Five Whys: correlated recovery oracle

1. Why is `adapter.integrity_check` not enough? It proves SQLite structure, not logical
   transition correctness.
2. Why is `CheckpointStore#latest` not enough? It uses the same queries/codec assumptions as
   normal production recovery.
3. Why can that hide a bug? A writer and reader can agree on the same incorrect partial
   representation.
4. Why use raw SQL? It exposes immutable rows, heads, counters, transitions, receipts, and
   digests without invoking the transition/materializer under test.
5. Why still run Tamoz recovery? Once the independent oracle proves a valid old/new state,
   recovery proves the public runtime converges from it.

## Acceptance conditions

Implementation may start because:

- every M3 residual claim now has a named direct proof;
- boundary completeness and hook reachability are separate gates;
- effect truth and recovery observation are independent;
- all workloads, outputs, samples, and resources are bounded;
- platform limitations cannot silently pass;
- performance claims are runner-scoped;
- every implementation phase has an explicit review/test/commit stop;
- no M4/M5a runtime work is mixed into the phase.

Implementation must stop and revise this plan if the boundary registry cannot define a
finite durable boundary set, if raw SQL cannot express an independent logical oracle, or if
the release matrix cannot be bounded and deterministically sharded.

## Residual external gates

- Ruby 3.4 and 4.0 require either local installations or exact-revision CI jobs.
- GitHub evidence requires a push, which the user has not authorized in this thread.
- Named reference-hardware latency is meaningful only on a stable runner.

These gates narrow release claims; they do not justify skipping local harness implementation.
