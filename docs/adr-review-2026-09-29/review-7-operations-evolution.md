# Round 2 — Reliability, scalability, operations, security, and evolution

Date: 2026-09-29. Scope: every ADR, with deeper analysis of operational boundary clusters.
These are documentation findings unless an implementation observation is explicitly stated.
No capacity benchmark, production incident exercise, or sibling-repository inspection was performed.

## O1 — P1: Approval risk is documented as zero after chat approval was enabled

ADR-049's status records the owner's 2026-09-24 change. The abstract, §4–§7, and ADR-043 still describe deny-only behavior or a future grant. `base.yaml:92–94` assigns `chat_bound` approval evidence. `Evaluator#build_decision` uses that document-level evidence for an `ask`; it is not a per-effect whitelist in the implementation inspected here.

The risk is therefore approval of an exact pending action by an attacker who controls the bound chat identity or can forge the relevant transport event, subject to the existing prompt bindings, expiry, and current action gates. Exact binding limits replay and substitution; it does not reduce the consequence of approving the correctly bound dangerous action.

**Required repair:** document the current global evidence default and profile behavior; remove the zero-risk and universal deny-only claims; separate the original policy from the current one; state the relationship to §4's former per-effect bar. Enumerate worst outcomes by asked tier, prompt/grant scope, and expiry. Preserve the owner-authorized policy. Do not revert it just because the old prose disagrees, and do not invent evidence that the old bar was satisfied.

`Engine#resolve` deliberately validates the evidence vocabulary without comparing strength (`engine.rb:231–240`); channel identity enforcement is in `Gateway::Callbacks#resolve_callback`. ADR-053 must describe that ownership accurately. This is an enforcement-map requirement, not a demonstrated bypass in this review.

## O2 — P1: “Journal records everything” is broader than the implementation

ADR-047's Decision and Consequences promise complete journaling and that a paused turn is never lost. ADR-045 also says the journal is bounded and rotating. Those are not interchangeable guarantees.

`recorder_journal.rb:90–121` drops closed, disabled, and saturated bulk-lane input. Reserved-lane fallback can also drop on disk failure. Lines 162–196 rotate and delete retained files. `observability_runtime_test.rb` explicitly tests rotation, one-file retention, and counted bulk saturation.

**Required repair:** say that intentional sampling is an export decision, while ingestion can degrade and retained journal data can expire. Name safety-bearing signal classification, durable reconstruction sources, and loss markers. State what survives a days-long pause and under what retention/reconstruction assumptions. Never equate “not sampled” with “cannot be lost.” No implementation change is inferred solely from this prose defect.

## O3 — P2: Durability records omit important deployment assumptions

ADR-011 says SQLite/WAL/one operator; ADR-015 says a barrier returns after commit; ADR-017 requires fences. This is a useful foundation, but an operator needs to distinguish process-crash recovery, database transaction durability, storage failure, and restoration from backup.

**Required repair:** link the owning adapter's actual configuration and backup/restore contract. State the supported filesystem/deployment assumptions, transaction boundary, busy budget, lease renewal expectations, and post-restore authority handling. Do not call a synchronous Ruby method sufficient proof of power-loss durability. Put changing deployment instructions in the persistence guide, with the ADR owning the guarantee and limitations.

`connection_pool.rb:35–45` configures and verifies `synchronous=FULL` and WAL. This is useful implementation evidence. No database configuration defect was established here; the finding concerns the claims' missing deployment and failure assumptions.

## O4 — P2: Single-operator scope and scaling limits are not carried through the corpus

ADR-011 selects a single-file, one-writer store. ADR-031/032 introduce durable scheduled ingress and backlog policies; ADR-042 adds a second process sharing that store; ADR-052 expands package topology. Those decisions need a common workload envelope, otherwise “scalable” can mean incompatible things to different readers.

**Required repair:** state the supported unit of deployment: operator, database, workspace, worker count, and namespace. Link measurements for concurrent sessions, scheduler backlog, approval pause duration, checkpoint/effect growth, and gateway traffic. Identify the first bottleneck and a measured trigger for reconsidering SQLite or partitioning. Leave unmeasured limits explicitly unmeasured. More gems do not establish more runtime throughput.

## O5 — P2: `unknown` is safe only with a usable reconciliation path

ADR-016 rightly refuses blind retries. ADR-021 binds logical identity and attempts. Missing from the records is a compact account of who can reconcile, what evidence is sufficient, how authority stays pinned, and whether further work remains blocked while an outcome is unresolved.

**Required repair:** walk one crash-after-send-before-receipt scenario through the actual dispatcher/journal/reconciler. Specify terminal receipt immutability, request-based identity, safe retry classes, and the operator's allowed resolution. Link the existing operations flow rather than creating a second reconciliation mechanism. Distinguish an abandoned model call from an irreversible external effect; a user stop cannot undo an already completed effect.

## O6 — P2: Process separation is not a complete compromise threat model

ADR-042 puts transport credentials in a separate gateway, but both processes share a SQLite runtime DB. ADR-055 gives the external authority a process boundary and restricted episode tools. Neither process separation nor a read-only tool name proves containment against arbitrary trusted adapter behavior or full host compromise.

`EpisodeCapabilityHost` documents this distinction itself: adapter binding is a trust boundary, and the host guarantees the surface/call path rather than adapter internals (`capability_host.rb:22–28`). Its context excludes the effect journal; the episode execution machinery nevertheless verifies journaled model receipts (`situation_request.rb:954–1041`). ADR-055's “no effect journal” must be scoped to tool access, not the entire episode process.

**Required repair:** distinguish malicious model output, compromised adapter, compromised gateway process, and compromised host/DB access. State credential/filesystem/DB privileges and what each attacker can still do. Identify the authenticating transport for a snapshot: checking a payload's unkeyed digest against a digest delivered alongside it proves consistency, not sender authenticity. Keep mTLS/socket admission distinct from snapshot content identity. These are threat-model corrections, not claims of a newly demonstrated exploit.

## O7 — P2: Supply-chain and deletion promises need lifecycle evidence

ADR-034 specifies tree identity, quarantine, comparative evaluation, and atomic activation. ADR-027 promises propagation of correction/quarantine/deletion to every recall path. These are broad lifecycle contracts with different failure windows.

**Required repair:** identify resume pinning, rollback, revoked-skill behavior, active/pending epoch transitions, derived-memory invalidation, and the receipt for a completed deletion. Compare the replay semantics of a historical checkpoint with the semantics of future recall. Do not assume that a new digest revokes an old pinned behavior, or that a deleted primary row removes every derived copy.

## O8 — P2: Migration policy and graph evolution need explicit scope

ADR-019 allows explicit migration to resume a changed graph. AGENTS.md separately forbids legacy database compatibility machinery while retaining monotonic checksummed migration ordinals. Those rules can coexist: graph-state compatibility and support for old database rows are different contracts.

**Required repair:** name the distinction, supported upgrade/reset workflow, and the responsible artifact owner. Do not backfill old-row readers or compatibility shims while repairing the ADRs. For ADR-055, document wire version/feature compatibility and the coordinated release process without asserting current cross-repo conformance from a dated audit.

## O9 — P2: Cancellation is a first-class durable outcome

AGENTS.md and `SessionWork` describe why user stop routes through a terminal outcome rather than cancelling the executor's running superstep. `Worker#watching_for_stop` registers `Cancellation::Stops`; settlement recognizes `cancelled_by_user` separately from successful verification.

**Required repair:** record stop versus process shutdown, queued versus running versus parked work, model abandonment, children, and irreversible effects. Cite `cancellation_visibility_test.rb` and the existing seam; first inspect its scenario coverage before claiming the whole lifecycle is tested. A missing ADR is a governance gap, not proof that stopping currently fails.

## O10 — P2: Policy digests prove identity, not the merits of a policy

ADR-030/034/048/049/053/055 all rely on digest pinning. That use is valuable, but a stable digest does not prove that the selected policy is safe, that a model response is correct, that a sender is authenticated, or that a new profile preserves an old authority limit.

**Required repair:** state separately trusted origin, schema validity, immutable identity, authorization, freshness, and observed outcome. For live profile changes, show which actions use the newly selected policy, which interrupted decisions remain pinned, and how revocation affects previously issued grants. Reference `approval_reload_test.rb` and `approval_mode_switch_test.rb` as candidate evidence; neither was executed in this review.

## Operational evidence required before acceptance

| Contract | Representative failure to demonstrate | Required observation |
|---|---|---|
| Durable commit and fences | Crash at commit; stale owner resumes | At most one committed advance; stale authority refused |
| Effects and reconciliation | Send may have succeeded, receipt absent | Safety-class-specific retry/refusal; exact resolution audit |
| Plan and approval | Plan changes after review; policy changes while parked | Exact binding; no implicit authority upgrade |
| Memory and skills | Revoked/deleted source; resume of pinned behavior | Documented future-recall and replay behavior |
| Telemetry | Saturation, disk failure, rotation, paused turn | Counted degradation; bounded retention; reconstructable safety evidence |
| Schedule and gateway | Backlog, restart, duplicates, expired prompt | Bounded policy; separate delivery/task outcomes; exact consumption |
| Stream episode | Snapshot mismatch, deadline, redispatch, contract mismatch | Pre-model refusal where required; journal reuse; explicit compatibility result |
| User stop | Stop during model, action, child, or approval pause | Typed terminal and truthful effect outcome |

These scenarios are a review bar. They are not a demand to add speculative machinery. Reuse the existing implementation and tests; add a test only for a real uncovered invariant.
