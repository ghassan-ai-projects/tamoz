# M3.1 phase 1 deep review — evidence foundation

Review target: phase 1 diff from `5670f11`.

Decision: accepted after the corrections below and the final clean gate recorded here.

Scope:

- first-class canonical `evidence` artifacts;
- bounded shared subprocess execution;
- M1/M2 fixed-runner migration to the shared primitive;
- documentation, packaging, and adversarial tests.

Trace recording, kill selectors, persistence instrumentation, effect targets, races,
storage faults, soak, benchmarks, and public M3 cases remain out of scope for this phase.

## Review method

The review traced three trust boundaries independently:

1. untrusted artifact bytes through schema, digest, reference, and semantic verification;
2. caller inputs through command/environment validation, spawn, output draining, timeout,
   process-group termination, reaping, and immutable result construction;
3. fixed-runner inputs through exact environment construction, sandbox prefixing, bounded
   capture, artifact generation, and result verification.

It then attacked false success, weak provenance, unbounded memory, pipe deadlock, descendant
retention, encoding expansion, shell injection, ambient Ruby/Bundler injection, reference
escape, inconsistent status, and single-process assumptions.

## Findings closed

| Severity | Finding | Root cause | Correction |
|---|---|---|---|
| Critical | M1/M2 captured stdout and stderr without a byte bound. | Each runner owned a copy of ad hoc `Open3` logic. | Added simultaneous draining with fixed retained-byte limits and full-stream byte counts/digests; migrated both runners. |
| Critical | A singular process field could not represent race evidence. | The initial envelope modeled only one child execution. | Use a bounded, uniquely identified process list suitable for crash and multi-process treatments. |
| Critical | Plain case/scenario names did not bind the reviewed definitions. | Identity was confused with provenance. | Evidence now binds exact case version/digest and scenario version/digest, plus subject revision/tree and producer digest. |
| High | Ambient `RUBYOPT`, `RUBYLIB`, Bundler variables, or credential variables could alter child execution. | Inherited environment was the default. | `Process.spawn` uses `unsetenv_others`; callers provide a validated exact environment and fixed runners pass a narrow allowlist without `HOME` plus explicit Bundler controls. |
| High | A process could exceed its deadline yet leave descendants holding output pipes. | Waiting for the leader did not prove process-group quiescence. | Apply monotonic deadline, group `TERM`, bounded grace, group `KILL`, reap the leader, and reject retained descendant streams as execution failure. |
| High | Reading stdout before stderr could deadlock when either pipe filled. | Sequential capture does not provide backpressure to both streams. | Drain both pipes concurrently while retaining only bounded prefixes. |
| High | UTF-8 replacement could expand retained output beyond its byte limit. | The limit applied before invalid-byte replacement. | Bound the final valid UTF-8 representation as well as the raw retained prefix; preserve the full raw digest and byte count. |
| High | A passed artifact could carry failed/unknown claims or diagnostics. | JSON shape alone cannot enforce cross-field meaning. | Semantic verification now maps status to decision and enforces exclusive diagnostics and claim outcomes. |
| High | Evidence classification and sanitization were implicit. | Reference classification was mistaken for an envelope content policy. | Require classification, capture level, and sanitization status; reject public evidence without a positive sanitization declaration. |
| High | Process exit, signal, timeout, termination, truncation, or duration fields could contradict one another. | Independent schema fields lacked relational checks. | Require exactly one exit/signal result, consistent timeout/termination, exact truncation arithmetic, and process durations within envelope duration. |
| Medium | Executable lookup could invoke a shell or relative current-directory entry. | Convenience PATH lookup was not constrained. | Spawn only argument vectors whose first entry is an absolute executable; the helper ignores relative PATH entries and resolves a real file. |
| Medium | Evidence kinds and arrays could grow without an explicit ceiling. | The first draft relied mainly on the artifact byte cap. | Bound claims, measurements, processes, references, diagnostics, identifiers, strings, durations, arguments, environment, and output independently. |
| Medium | Git metadata capture remained outside the new bound. | Migration initially covered only test commands. | Route fixed-runner Git calls through the same bounded exact-environment primitive and reject truncated metadata. |
| Medium | SHA-1-only revision syntax would reject Git SHA-256 repositories. | Current repository object width was treated as universal. | Accept exact lowercase 40- or 64-hex Git object identifiers. |

## Five Whys: unbounded evidence capture

1. Why could a test exhaust evaluator memory? Both output streams were read completely.
2. Why was that duplicated? Each milestone runner embedded its own process lifecycle.
3. Why did timeout not bound memory? A child can emit faster than the deadline expires.
4. Why not stop reading at the cap? The child would block on a full pipe and create a false
   timeout or deadlock.
5. Why does the correction work? Both streams are always drained, only bounded prefixes are
   retained, and complete byte counts/digests preserve truncation evidence.

## Five Whys: weak evidence provenance

1. Why is `case_id` insufficient? A case can change while keeping its identifier.
2. Why is a scenario name insufficient? Harness behavior and fixtures can change under the
   same label.
3. Why does the outer digest not solve attribution alone? It proves envelope integrity but
   not which reviewed definitions the fields intend to reference.
4. Why bind revision/tree and component digests too? Code, working tree, producer, case, and
   scenario are distinct provenance dimensions.
5. Why does the correction work? Every reusable definition has a version/digest and the
   complete binding is itself canonical and domain-separated.

## Evidence gate

Required before commit:

- subprocess unit treatments for exact environment, simultaneous large streams, output
  truncation/digest, invalid UTF-8, cooperative and resistant timeout, retained descendant,
  executable resolution, invalid input, and immutable result;
- evidence artifact treatments for canonical load, reference verification, duplicate and
  missing ids, relational process checks, bounds, every decision class, and diagnostic
  exclusivity;
- real M1 and M2 conformance runs under a self-tested macOS network sandbox;
- documentation, schema, public API, packaging, syntax, design, and full regression gates.

Final gate on the reviewed diff:

- subprocess harness: 8 tests, 62 assertions;
- evidence artifact: 7 tests, 45 assertions;
- M1 real sandbox integration: 2 tests, 51 assertions;
- M2 real sandbox integration: 2 tests, 73 assertions;
- complete CI: 225 tests, 2,515 assertions, zero failures, errors, or skips;
- design validation: 22 documents, 55 invariants, 40 ADRs;
- local platform: Ruby 3.3.11, sqlite3 gem 2.9.5, SQLite 3.53.2.

## Residual risks and non-claims

- `SubprocessRunner` is lifecycle control, not an OS security boundary. Network/filesystem
  containment must be supplied and self-tested by the caller; M1/M2 currently self-test
  network denial, while the stricter M3 public runner belongs to phase 7.
- An exact environment can still contain a secret if the caller explicitly supplies one.
  Fixed runners therefore construct a narrow allowlist; phase 7 adds artifact sanitization.
- The harness cannot reclaim a hostile descendant that deliberately creates a new session.
  It rejects retained streams and requires an outer OS sandbox for hostile workloads.
- Local review uses Ruby 3.3.11. Exact-revision Ruby 3.4/4.0 jobs remain an external release
  gate and are not claimed here.
