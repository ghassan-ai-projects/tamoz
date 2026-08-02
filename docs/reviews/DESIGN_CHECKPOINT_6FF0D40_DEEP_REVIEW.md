# Design checkpoint `6ff0d40` deep review

Verdict: **REJECT AS COMMITTED; ACCEPT WITH THE DOCUMENTATION CORRECTIONS IN THE
WORKTREE.** No implementation file was changed. P10 implementation was explicitly out
of scope; its tracker was only synchronized to the checkpoint landed concurrently by the
other agent.

Reviewed: P11–P18, DR-1–DR-5, their 13 review records, the registry/handover/gauntlet
trackers, authoritative designs/invariants, and the read-only transaction/Store/request
paths in `tamoz-sqlite` and `tamoz-graph`.

## Findings and dispositions

| ID | Sev | Artifact | Finding | Disposition |
|---|---|---|---|---|
| DC-1 | Critical | DR-1 | One scalar row was both a version allocator and the active version. Two candidates could reserve v2/v3 from the same active v1, activate out of order, and leave no authoritative snapshot for later threads. Registry enumeration did not select one pending transition. | Revision 4 separates allocator/active/pending state in one CAS control record, permits one pending transition, stores immutable snapshots by digest, finalizes the active pointer before the transition row, and adds ordering/intake/crash probes. |
| DC-2 | Critical | DR-2 | Per-owner Store keys cannot make one atomic aggregate scope row "flip open". Ephemeral component-instance ids also let a restart appear under a fresh identity and bypass prior evidence. Raw scope concatenation collides/leaks, and the claimed corrupt-record repair could not obtain `if_version` because public `Store#get` fails during decode. | Revision 3 uses one scope record keyed by a domain-separated typed-scope digest with a bounded map of stable policy-owner identities; any owner predicate opens that record. It adds owner overflow/restart tests and a narrowly scoped raw-head `CircuitStore#repair_corrupt` operation with authority + observed-digest binding. |
| DC-3 | Critical | P11 | The plan required Store version/head and lexical index to commit together while declaring public Store unchanged. `Store#put` owns its transaction; the only implied implementations were nested transactions, private `send`, or two commits. | P11 revision 3 names a sqlite-owned `MemoryRepository` and a shared private transaction-aware Store append primitive. Public Store stays unchanged; append/index and purge ownership are explicit. |
| DC-4 | Critical | P13 | The plan required `claim_due` and later `enqueue_occurrence` calls to be one transaction and suggested calling transaction-owning `CheckpointStore#enqueue_request` inside it. This contradicted both the code and P14's correct non-reentrancy analysis. | P13 revision 3 replaces the split public calls with atomic `materialize_due`, implemented inside sqlite, and extracts one private transaction-aware request-enqueue primitive. Kill proof now requires rollback-to-unclaimed or complete occurrence+request. |
| DC-5 | High | P11/P13/P14 | P11 consumes the next schema migration, P13 hard-coded `MIGRATION_2`, and P14 used `MIGRATION_2+`. Sequential phases could reuse an ordinal or overwrite migration assumptions. | Plans allocate the next monotonic checksummed slot at activation; expected sequence on the current baseline is P11=2, P13=3, P14=4, with duplicate-ordinal tests. |
| DC-6 | High | P18 | Production was a closed set of four sources and extra registration had to fail, while H3 required successful registration of a fifth source. Both properties cannot hold. | Revision 3 removes fifth-source extensibility as a v1 property. H3 now proves common-protocol composition across the four built-ins and multiple descriptors within a built-in, while a fifth source must fail. |
| DC-7 | High | DR-4 | The validation callback received a transaction and the runner's terminal helper was said to write inside the claim transaction, creating an unsafe callback/nested-write boundary. The stated `claimed → failed` path also left an unnecessary observable intermediate state. | Revision 3 makes validation pure and capability-free; checkpointer code owns `queued → failed` in the claim transaction. Recover validates in its transaction; runner terminalization is only the post-claim backstop. |
| DC-8 | High | Handover/P11–P18 | P16–P18 were appended without rebuilding the one-active-phase chain. P15 could activate after P14 but before P18, even though P18 delegates API arbitration to P15. Plans hard-coded mutually stale 16/17-case baselines. | One order is now explicit: P10 → DR-4 → DR-5 → P16 → P17 → P11 → P12 → P13 → P14 → P18 → P15. Every phase captures its scorecard baseline at start; new capability cases are additive. |
| DC-9 | High | P17 | "IP pinning or second-resolution comparison" allowed the latter as SSRF enforcement. A second lookup still leaves DNS resolution between check and connect and therefore does not close rebinding TOCTOU. | Revision 3 requires the validated IP to be passed to the actual dialer while TLS verifies the allowlisted hostname; each redirect repeats resolve/classify/pin/dial. A dial-spy asserts the address used. |
| DC-10 | High | P15 | The release outcome required direct evidence and zero unresolved high/critical security findings, but DoD allowed any applicable row except `missing` and the stop gate allowed owner-signing unresolved high/critical security risk. | Revision 3 requires every applicable release-blocking row to be direct-evidence `pass`; indirect is non-release-blocking only; unresolved high/critical security findings cannot be waived into a release candidate. |
| DC-11 | Medium | P18 | `Coverage(methods: true)` cannot classify constants/Data entries and does not automatically capture scorecard subprocesses, yet the plan treated it as complete public-surface measurement. | Revision 3 merges per-process Coverage with the public-api manifest and a named surface probe; measured columns distinguish product method execution, test-only execution, manifest-only resolution, and internal code. |
| DC-12 | Medium | P16 handover | The handover said P16 makes Toolbox a capability-source composition, while the accepted P16 plan explicitly defers capability-host unification to P18. | Handover now says P16 moves/re-exports Toolbox/Skills by identity; composition remains P18. |
| DC-13 | Medium | P14 | The cross-phase rule requires a fixed behavioral case for every new capability, but P14 made its Situation case optional and used a stale numeric baseline. | P14 revision 3 makes `agent.situation-...` mandatory and compares all pre-P14 cases to the measured P14-start baseline. |

## Five whys

1. Why were atomicity claims unimplementable? Because plans named multi-step product
   transactions without tracing which existing methods already own transactions.
2. Why was that missed in review? Because probes tested crash outcomes conceptually but
   did not map every write to the exact adapter call boundary.
3. Why did state models contradict their claimed properties? Because record shapes were
   reviewed field-by-field, not against concurrent multi-owner/multi-candidate histories.
4. Why did phase counts and migrations drift? Because P16–P18 were appended as a second
   chain instead of recomputing the repository's single active topological order.
5. Why could the checkpoint still be marked accepted? Because review dispositions were
   recorded per document without a final cross-document executable-consistency pass.

System correction: every future design checkpoint must include (a) a transaction-owner
map, (b) a state-machine history probe with two writers/restarts, (c) a topological phase
order with migration and scorecard deltas, and (d) a contradiction scan over all hard
gates and non-goals.

## Held-out probes

- Record two behavior candidates from the same active version, reverse registry
  enumeration order, crash after control finalize but before transition finalize, and
  start another thread. Only one pending candidate may apply and later intake must find
  the active snapshot without the canary session.
- Restart a circuit owner under a new process id; it must retain its stable policy owner
  state. Fill the owner map and prove the next owner fails closed. Corrupt payload bytes;
  ordinary get must fail and wrong-digest repair must refuse.
- Kill P11 between Store-version insert, head update, and index insert. Observe old or
  complete new state, never a visible unindexed head.
- Kill P13 at every SQL statement in `materialize_due`; observe neither row or both
  occurrence/request rows. Invoke the public request enqueue concurrently and prove the
  shared primitive preserves byte-identical dedup.
- Attempt P18 construction with a fifth source and with content-shaped forged source
  data; both fail. Add a second MCP server through the built-in MCP dispatcher; no host
  code changes and the authority intersection remains exact.
- DNS resolver returns public A on validation and private A on a later lookup. The HTTP
  stack must dial the validated public address directly or refuse; it may not resolve
  again implicitly.
- Mark a release-blocking requirement `indirect` and an unresolved high security issue
  `owner-signed-residual`; both must block P15.

## Residual risks

- DR-1 revision 4 is a serialized v1 design. If throughput or multiple simultaneous
  canaries becomes a requirement, it needs a new reviewed queue/traffic-allocation
  design rather than relaxing the singleton pending invariant.
- P14 still proves a simulated source/effector path, not a real physical source. P15's
  promotion matrix must either exclude that feature claim from v0.1 or obtain the
  separately required owner/safety evidence; documentation cannot turn simulation into
  physical proof.
- Live-network P17 evidence remains an explicit operator-gated deferral. Unit SSRF proof
  is necessary but not evidence about a provider's production deployment controls.

## Status

All critical/high findings above have documentation dispositions. Implementation must
use the revised documents, not the historical acceptance statements in the original 13
review records. A fresh implementation-time review must verify the named internal seams
before code lands.
