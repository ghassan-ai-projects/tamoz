# The invariants

Sixty-one clauses define the compatibility and correctness surface. The public API may
move before 1.0; these semantics may change only through an ADR with a migration and new
conformance tests.

Foundation clauses 1–27 and correction clauses 52–55 are the v0.1 release contract.
Memory/skill clauses 29–31 and 41–43 become mandatory for v0.2; improvement/healing clauses
28 and 32–34 become mandatory for v0.3. Clauses 35–37 (MCP), 38–40 (scheduling), and 44–51
(`tamoz-stream`) are fixed conditional conformance and become release-blocking when their
optional packages are promoted. An unavailable feature never pretends to pass its clauses.

## Execution and state (1–8)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 1 | **Barrier atomicity** | A channel receives all writes for a super-step in one update | Order-dependent partial merges |
| 2 | **Write visibility at N+1** | Step N reads one frozen snapshot; its writes become visible only in N+1 | Intra-step read/write races |
| 3 | **Deterministic task and commit order** | Logical activation ids include stable execution/activation identity and survive resume; attempt ids bind invocations to bases; fork changes execution identity; committed writes and model-facing tool results sort by graph/task/call path | Cross-fork result reuse, stale attempt acceptance, and nondeterministic prompts |
| 4 | **Node restart from top** | An interrupted or uncommitted node re-enters at its first line | False continuation semantics |
| 5 | **Resume by call index** | Resume values match interrupt calls positionally within a task; parallel resumes also include task id | An answer reaches the wrong question |
| 6 | **State edits run reducers and append** | `update_state` uses reducers, appends a fork checkpoint, and creates a new execution id when based on history | History mutation and cross-branch pending-write reuse |
| 7 | **Routing is additive when declared additive** | Static successors and `Command#goto` both fire; the builder warns on the combination and docs require intent | Silently dropped transitions |
| 8 | **Conflicting writes fail** | Multiple writes to a reducer-less key raise with all task ids before commit | Silent last-writer-wins loss |

## Runtime isolation and control flow (9–15)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 9 | **Strict checkpoint sequence** | Each `(thread_id, ns)` has a backend-assigned, gap-tolerant, strictly increasing integer sequence; opaque ids are never used as order | Clock/UUID ordering mistakes |
| 10 | **Top-level persistence ownership** | Subgraphs inherit one backend under deterministic namespaces; no nested backend is created implicitly | Split history and collisions |
| 11 | **LLM-independent engine** | Requiring core/graph loads no RubyLLM, HTTP client, provider, or adapter — a load-time invariant; run-time capability injection via node callables and `context.effects` is by design | Vendor coupling and offline-test failure |
| 12 | **Worker-local interrupt capture** | `throw :tamoz_interrupt` is caught inside the same task execution stack and returned as a typed result; ordinary `rescue` cannot swallow it | `UncaughtThrowError` in thread pools or bypassed approval |
| 13 | **Immutable isolated input** | Hashes, arrays, strings, and framework values are copied/frozen at commit; unsupported mutable state is rejected before execution | Sibling state mutation |
| 14 | **No ambient tenant state** | Runtime context is explicit; no `Thread.current`, fiber-local tenant data, or mutable global after boot | Cross-run data leakage |
| 15 | **Streaming is one bounded projection** | Streamed and non-streamed execution commit identical bytes; sink is bounded/closed, cooperative workers join, stuck workers retire and cannot commit | Divergent execution, unbounded queues, unsafe thread kill |

## Durability and compatibility (16–22)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 16 | **Stable model prefix per cache epoch** | Canonical system content, tool schemas, model settings, and skill catalog digest remain stable within an epoch; any change records a reason and increments the epoch | Invisible prompt-cache cost drift |
| 17 | **Only recoverable tool failures become values** | Invalid arguments, denial, timeout, and declared external failures become typed tool results; cancellation, policy violations, programmer bugs, and storage corruption propagate | Hidden fatal failures or brittle agent loops |
| 18 | **Versioned, allowlisted records** | Every record has a format version; only registered JSON codecs revive types; newer unsupported versions fail before partial load | Unsafe or half-valid deserialization |
| 19 | **Atomic compare-and-append commit** | A commit validates base checkpoint and fence, appends one checkpoint, and consumes/associates pending writes in one storage transaction | Torn barriers and lost updates |
| 20 | **Single fenced writer** | Exactly one renewable lease advances a thread namespace; every durable write rejects an expired or stale fence | Concurrent history forks and zombie commits |
| 21 | **Replay-safe effects or explicit ambiguity** | Every side effect has a stable key, safety class, and attempt token; a stale graph owner may record only its attempt's truthful outcome, safe effects may retry, and ambiguous non-idempotent effects become `:unknown` | Duplicate work or lost late receipts |
| 22 | **Graph compatibility before resume** | Checkpoints carry graph name/version/digest; incompatible code fails before user code unless an explicit migration creates a new checkpoint | Silent behavior changes for in-flight runs |

## Security and external input (23–24)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 23 | **External inputs are identified and deduplicated** | Surface requests carry a stable request id; duplicate delivery returns the prior outcome or joins the active turn; a thread's queue order is durable | Duplicate user turns and cron/gateway replays |
| 24 | **Sensitive data is explicit** | Secret values are rejected from checkpoints, streams, and instrumentation unless a named policy protects them; no lossy key-name scrubbing occurs | Credential leakage or silently corrupted state |

## Deliberation, verification, and learning (25–28)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 25 | **Reviewed plan gates task action** | Every new user, scheduled, delegated, or internally generated task persists a versioned plan and accepted review bound to its canonical digest before capabilities run; before review only planning/review, clarification, and normalization of caller-supplied metadata are allowed; an accepted discovery plan opens only its bounded read-only evidence capabilities, while action requires a separately accepted action plan and crash resume reuses the checkpointed exact version | Unexamined action, blind plans, and fabricated after-the-fact plans |
| 26 | **Material change requires re-review** | A change to goal, steps, tools/resources, effect class, budget, approval, or verification creates a new plan version; the old review cannot authorize it, and execution stops at the next safe barrier until the replacement is accepted | Plan drift and review bypass |
| 27 | **Material completion requires evidence** | Observations, inferences, assumptions, and unknowns remain distinguishable; material results are checked against the plan's definition of done using an independent signal when available; inability to verify is reported, not converted into success | Confident but unsupported completion claims |
| 28 | **Self-improvement is evaluated and reversible** | Every behavior change has provenance, isolated candidate and holdout evaluation, policy-gated promotion, a new behavior version, monitoring, and rollback; prefix changes also create a cache epoch, while capability, security, evaluator, prompt-hierarchy, or code changes require human approval | Silent self-modification, reward hacking, and irreversible regressions |

## Durable memory (29–31)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 29 | **Memory promotion is layered and attributable** | Working context is not durable memory; Experience, Knowledge, and Wisdom are distinct versioned layers; every admission/consolidation/promotion preserves epistemic kind, scope, authority, source digests, contradictions, and transition evidence; Wisdom requires `tamoz-evals` promotion and a new behavior version | Repeated claims becoming facts, provenance loss, and unevaluated behavior change |
| 30 | **Memory retrieval authorizes before ranking** | Tenant/user/project/surface authority, sensitivity, layer/class, state, validity, and compatibility filters run before search/ranking; unauthorized candidates reach neither counts nor context; returned records retain provenance/confidence/contradiction metadata and memory never grants permission | Cross-user leakage, stale instruction execution, and high-ranked unauthorized memory |
| 31 | **Memory correction and deletion propagate with proof** | Conflicting prescriptions are surfaced/quarantined rather than averaged; superseded/quarantined/deleted records leave active recall; decay recomputes from stable base/checkpoint; correction/deletion propagates to indexes, derived records, caches, and retained artifacts under policy and emits a receipt | Contradictory action, compounding decay, zombie recall, and unverifiable erasure |

## Bounded self-healing (32–34)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 32 | **Remediation is typed, reviewed, authorized, and bounded** | Automatic remediation requires a versioned typed failure and rule, confidence gate, exact reviewed plan, current preconditions, original authority, known effect state or reconciliation, and explicit attempt/scope/magnitude/cost/time limits; it cannot widen permission or substitute a broader action | Regex-triggered mutation, destructive fallback, and policy-bypass “healing” |
| 33 | **Recovery means the original invariant was independently verified** | A rule-supplied verifier—not the remediation model—decides recovery; unknown effects reconcile before retry; verification failure compensates or escalates; compensation is separately authorized/journaled; configured recurrence, uncertainty, verification, or compensation failures open a durable circuit | False recovery, duplicated effects, hidden rollback failure, and recursive harm |
| 34 | **Healing rules earn authority through staged evaluation** | A rule progresses through replay, shadow, isolated fault injection, canary, and active modes under `tamoz-evals`; unsafe action, unauthorized scope, blind ambiguous retry, false recovery, evaluator tampering, or concealed compensation failure blocks promotion; rules cannot promote or reset themselves | Untested autonomous repair and benchmark gaming |

## Capability and MCP boundaries (35–37)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 35 | **Capability authority is local, intersected, and content-addressed** | Every local, MCP, skill, delegated, or scheduled capability has a source-qualified immutable descriptor; effective authority is the intersection of current application/agent/task/parent limits; descriptions, annotations, manifests, memory, and model output cannot grant or lower risk | Name shadowing, capability laundering, and remote/content-defined policy |
| 36 | **MCP protocol and catalog snapshots are explicit and pinned** | Each server has an approved transport/configuration/protocol profile; discovery validates and digests schemas and metadata into an immutable catalog epoch; list changes, TTL expiry, reconnect, or config edits create a candidate next epoch; resume requires the exact snapshot | Silent protocol drift, mid-turn tool replacement, and stale-schema execution |
| 37 | **MCP calls preserve Tamoz authorization, durability, and uncertainty** | Arguments/results validate against pinned schemas; tools use local effect safety and deterministic keys; remote annotations are untrusted; credentials remain outside state/content; elicitation is a durable originating-call interrupt; retries require proven read-only/idempotent/reconcilable safety; ambiguous work stops | Prompt/metadata injection, credential leakage, fabricated consent, and duplicated remote effects |

## Durable scheduling (38–40)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 38 | **A due time creates one logical occurrence and request** | Occurrence identity derives from schedule id, immutable revision, and nominal UTC instant; durable uniqueness/fencing plus the request inbox survives duplicate pollers and crashes; delivery and agent execution have distinct status | Duplicate turns and false-green enqueue reports |
| 39 | **Civil time, misfire, overlap, and backlog semantics are explicit and bounded** | Cron requires an IANA timezone; DST gap/fold, jitter, clock jump, downtime, misfire, overlap, catch-up limit, concurrency, and queue depth are stored policies with deterministic histories; no implicit host timezone or unbounded replay exists | DST surprises, restart storms, overlapping damage, and infinite backlog |
| 40 | **Scheduled authority cannot widen while delayed or unattended** | A schedule pins payload/capability/behavior/budget/approval/delivery maxima; runtime authority intersects current policy; every agent occurrence still has an accepted plan and verification; missing interactive approval denies or explicitly escalates; schedule self-management is narrowly granted | Revoked access surviving in cron, self-approved unattended action, and schedule self-escalation |

## Skills (41–43)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 41 | **Skills are portable, source-qualified, content-addressed snapshots** | Agent Skills-compatible trees compile to immutable source/name/tree-digest identities; same-name cross-source collisions require explicit binding; catalog/file/install changes create a next epoch; resume loads the exact tree or stops | Silent skill shadowing, same-version swaps, and changed instructions on replay |
| 42 | **Skill content never grants authority or escapes its tree** | `allowed-tools` and compatibility metadata are requested limits only; loading adds no tool/root/credential/env/policy; resource reads verify indexed path/realpath/digest/size; scripts and dependencies use ordinary reviewed, sandboxed, effect-safe tools | Instruction-based privilege escalation, secret exposure, path escape, and load-time code execution |
| 43 | **Skill install, update, and self-improvement are staged and evaluated** | Artifacts stage in quarantine, pass archive/path/schema/provenance/capability-diff checks and comparative evaluation, then activate atomically as a new digest/epoch under policy; generated candidates cannot run their own evaluator or approve scripts/capability widening | Supply-chain execution, unevaluated workflow regression, and self-promoting skills |

## Streaming input and physical-world action (44–51)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 44 | **Input streams are not execution streams or user channels** | Unbounded evidence terminates in `tamoz-stream`; bounded `StreamPart` output remains a projection of one graph run; user surfaces and civil-time scheduling keep their existing request/occurrence contracts | Feeding an infinite source into model context, conflating rendering with recovery, and semantic API drift |
| 45 | **Every observation is authenticated, typed, bounded, and durably admitted** | Channel revision, scoped source/tenant/event identity, schema, digest domain/version, canonical payload hash, size/depth/units/time/sequence/classification limits, and admission outcome are stored; same-id/same-hash is idempotent and same-id/different-hash quarantines | Forged sensors, cross-tenant evidence, schema bombs, digest drift, duplicate state, and silent rejection |
| 46 | **Temporal truth is explicit and replayable** | Event, observed, ingestion, processing, decision, command, and outcome time remain distinct; monotonic per-partition watermarks, source idleness, bounded windows/timers, and declared late-data policies run under virtual time in replay | Processing-time nondeterminism, frozen watermarks, unbounded state, and erased corrections |
| 47 | **Partition transitions and Situations are deterministic and atomic** | State is serial per a versioned stable virtual-partition mapping; repartition is an explicit replay-proven migration; inbox, operators/timers, immutable Situation version, trigger/admission, outbox, and checkpoint commit atomically without model/network/effect calls in the transaction | Split-brain temporal state, partition drift, partial Situation publication, and model latency holding storage locks |
| 48 | **Backpressure and evidence gaps are bounded and visible** | Each channel declares bounded queue/spool plus block/retry/reject/semantic-sample/coalesce behavior; acknowledgement follows durable admission; every drop, gap, duplicate, lag, and overload decision is durable and observable | Silent sensor loss, memory exhaustion, false completeness, and ingestion collapse |
| 49 | **Cognition is admitted against one immutable Situation snapshot** | Every ignored/debounced/coalesced/deferred/admitted/superseded/expired/rejected trigger is durable and explainable; at most one bounded episode is active per Situation; its accepted plan binds the exact snapshot digest and late superseded Decisions are rejected | Agent storms, stale queued reasoning, unbounded prompts, and decisions detached from evidence |
| 50 | **Models propose typed intents; current deterministic policy owns physical dispatch** | No model/skill/MCP content calls an effector directly; policy reloads current state and checks freshness, minimum completeness, uncertainty, evidence quality/quorum, source health/calibration/gaps/conflicts, scope, bounds, approval, quotas, command expiry, external interlocks, and idempotency/reconciliation before journaling a narrow Command; R2/R3 fail closed and `effect_unknown` is never retried blindly | Stale or weak-evidence actuation, approval as a safety bypass, duplicate physical effects, and unverifiable outcomes |
| 51 | **Safety control and replay authority remain outside cognition** | Safety-critical/certified control is advisory-only; external E-stops/interlocks/controllers are authoritative and cannot be disabled or healed around; replay/shadow workers have no production effector credentials; SituationSpec/authority changes use independent staged evaluation | LLM in a hard real-time safety loop, test-to-production effects, disabled safeguards, and self-approved physical authority |

## Cross-cutting implementation blockers (52–55)

| # | Invariant | Required behavior | Failure prevented |
|---|---|---|---|
| 52 | **Logical activation identity survives interruption and retry** | A persisted activation id is stable across interrupt checkpoints, retry, crash resume, and lease takeover; a separate attempt id binds each invocation to its base checkpoint; pending writes, interrupts, and effects use activation identity while the barrier validates attempt identity | Lost resume values, repeated successful siblings, duplicate effects, and acceptance of stale task results |
| 53 | **The request inbox is durable, ordered, and redirect-safe** | Enqueue deduplicates before lease acquisition, allocates backend order, and persists payload digest/delivery mode; claim-next is fenced FIFO; redirect records target/cancellation once and reconciles in-flight effects; every recovery and terminal transition is explicit | Duplicate turns, reordered user input, inaccessible active-run joins, and redirect races |
| 54 | **Thread deletion preserves effect truth** | Deletion first tombstones new work; live leases and prepared/running/unknown effects block purge unless each effect has a separately authorized recorded resolution; late attempt receipts retain a durable sink; final purge emits a complete deletion receipt | Lost remote-operation outcomes, orphaned attempts, failed receipt commits, and unverifiable erasure |
| 55 | **Discovery is reviewed, read-only, and cannot authorize action** | Insufficient evidence produces a digest-bound discovery plan with locally classified read-only capabilities, roots/sources and resource budgets; it cannot mutate, delegate, execute scripts, widen credentials, or authorize later work; gathered evidence feeds a separately reviewed action plan | Blind plans, performative planning, metadata-based authority escalation, and discovery disguised as execution |
| 56 | **A user channel is identified, bound, and grants nothing** | Every inbound message resolves to a bound correspondent and conversation under a named surface revision before it becomes anything; its disposition (request/decision/ignored/rejected) is durable with a reason class; message content can never name a profile, thread authority, capability, root, model or budget | Anonymous senders spending owner authority, silent drops, and content-defined policy |
| 57 | **Channel delivery is ordered, bounded, and ambiguity-safe** | Outbound work is a bounded durable outbox claimed under a fenced lease; a transport offset is persisted only after durable disposition of the returned prefix; terminal capacity is reserved at admission; agent output is journaled and an ambiguous non-idempotent send becomes `:unknown` with no automatic retry | Lost answers, unbounded queues, invisible duplicate messages, and blind retry of an ambiguous send |
| 58 | **A channel decision is exact, expiring, and cannot widen authority** | A callback resolves a single-use expiring reference to exactly one `(thread, occurrence, interrupt digest, correspondent, prompt receipt)` and consumption is atomic; v1 accepts denial only, and no channel component may answer on a human's behalf | Replayed buttons, decisions on changed questions, chat-derived privilege escalation, and headless auto-approval |
| 59 | **Observation cannot change execution, and its surface is bounded and versioned** | Committed checkpoint bytes, model-facing message order, control flow and outcomes are identical with observation enabled, disabled, and failing, and an instrumentation call cannot raise into a caller regardless of payload or notifier; every signal, buffer, batch, label set and file is bounded, signal names and attributes form a closed versioned catalog whose change requires a version bump, no correlation identifier is admitted as a metric label, and every drop is counted and inspectable | Telemetry-induced behavior change, a hung collector stalling a turn, unbounded memory or cardinality, silent schema drift, and loss mistaken for health |
| 60 | **Telemetry is redacted by construction and content capture is an explicit named policy** | No `Tamoz::Secret` reaches any signal, label, journal line or export body — with no policy exemption, which is narrower than invariant 24's "unless a named policy protects them"; prompts, tool arguments, tool results, plan and review text are excluded unless a named, digest-bound, classification-permitted policy admits them per class within byte bounds; every signal records the governing policy digest, and omitted content is represented by a digest and size | Credential leakage, invisible content capture, and a trace whose emptiness cannot be distinguished from an empty run |
| 61 | **Safety-bearing observability is derived from durable evidence, correlated by durable identity, and never overstates what it measured** | Counters and states asserting a safety property are computed from the durable record rather than reported by the component they describe; trace identity is a pure function of thread and execution identity and span identity of a durable per-kind anchor, so a resumed, retried, approved or duplicated turn is one reproducible trace; a span without a durable interval is marked as ordering-only rather than given a fabricated duration; a cost value carries whether it was measured or estimated and from which pricing source; divergence between live and reconstructed views is counted and reported | A component vouching for itself, traces split by resume or approval, fabricated durations, estimates read as measurements, and unreported telemetry loss |

## Required conformance tests

| Clauses | Test shape |
|---|---|
| 1, 2, 8 | Parallel writers share one snapshot. Reducer update receives the whole sorted batch once; a reducer-less conflict names every task and commits nothing |
| 3 | Golden task-id fixtures plus randomized completion timing; final checkpoints and model-facing tool-message order remain byte-identical |
| 4, 5, 12 | A threaded node contains three interrupts under `rescue => e`; it pauses without `UncaughtThrowError`, restarts from line one, and consumes values by task/call index |
| 6, 9 | Fork from history, apply reducer-backed edits, and assert a new execution id and strict sequence without changing or consuming work from the source chain |
| 7 | Exercise static plus dynamic routing and assert both successors; assert the compile-time warning is deterministic |
| 10 | Nested parallel subgraphs share one backend and isolate deterministic namespaces |
| 11 | Require gems in clean subprocesses while forbidding socket creation and inspecting loaded features |
| 13, 14 | Mutate every supported nested state shape and race two tenant contexts under threads; unsupported mutable objects fail at commit |
| 15 | Stop stream consumption at every event index; assert bounded memory, cancellation, cooperative cleanup, stuck-task fencing/circuit behavior, and identical last committed checkpoint |
| 16 | Record canonical request-prefix digests over ten turns; vary one input at a time and assert only sanctioned epoch changes alter it |
| 17 | Matrix every tool error category and assert the correct value/exception boundary |
| 18, 22 | Round-trip every registered type; fuzz unknown tags and versions; resume against same, migrated, and incompatible graph definitions |
| 19 | Kill before, during, and after each SQL statement in commit; observe either the old or complete new checkpoint, never a partial state |
| 20 | Race two owners, expire the winner, then let the stale owner attempt a commit; only the current fence succeeds |
| 21 | Kill/expire the lease at prepare, during effect, after effect, and before receipt. A late worker can complete only its attempt receipt, cannot commit graph state; idempotent targets converge and unsafe targets stop `:unknown` |
| 23 | Deliver the same CLI/gateway/cron request concurrently and after restart; one logical turn is committed |
| 24 | Property-test secret wrappers and redaction policies across checkpoints, stream parts, logs, exception text, and `inspect` |
| 25, 26 | Attempt tool, subagent, and effect scheduling with no review, a mismatched digest, and a materially edited plan; all are blocked, while an accepted exact version runs and replanning resumes only after a new review |
| 27 | Seed false assumptions, unverifiable outputs, and contradictory tool evidence; the agent distinguishes each category, runs available independent checks, and never records successful completion without the required evidence |
| 28 | Generate candidates from evaluation trajectories; assert training/holdout separation, immutable provenance, capability-change human approval, compare-and-set activation, behavior-version pinning on resume, explicit turn-boundary transition, cache-epoch change only for prefix changes, regression rollback, and no self-approval |
| 29 | Attempt unattributed context→Knowledge, Experience→Wisdom, ungrounded consolidation, recalled-content reinforcement, and provenance/scope loss; each is rejected. An explicit scoped owner “remember” request may enter Knowledge as reported/prescribed with conflict/policy checks, while Wisdom still changes only through evaluated behavior transition |
| 30 | Seed highly relevant cross-user, expired, superseded, contradictory, sensitive, and incompatible memories; authorization removes them before ranking/counting, explicit and automatic retrieval obey different policies/budgets, and returned records preserve epistemic/provenance metadata |
| 31 | Correct, supersede, quarantine, decay repeatedly, and delete records with derived/index/cache copies; active recall changes immediately, decay is idempotent at one checkpoint, conflicts remain visible, and deletion receipts enumerate removed/retained/pending material |
| 32 | Fuzz typed codes, legacy text, confidence, stale targets, missing reads, directory/file mismatch, stale edits, scopes, authority, effect state, and every budget; only the exact reviewed minimal authorized rule can mutate |
| 33 | Inject timeout/unknown effect, verifier failure, compensation failure, recurrence, and lease loss at every transition; no false `recovered`, no blind retry, receipts remain truthful, and the correct durable circuit/escalation state results |
| 34 | Replay healthy/failing traces, shadow proposals, run the 250-case isolated matrix, canary one scope, inject hard-gate failures, and attempt self-promotion/reset; only independently gated rules activate |
| 35 | Attempt same-name local/MCP/skill collisions and authority claims in annotations, manifests, memory, and output; source-qualified ids remain distinct and the effective grant never exceeds any parent/current limit |
| 36 | Negotiate allowed/denied protocol profiles, mutate lists/schemas/TTL/health mid-turn, crash/reconnect, and resume after change; the turn remains pinned and incompatible snapshots stop before I/O |
| 37 | Fuzz MCP arguments/results/metadata, OAuth/stdio credentials, elicitation, timeout, disconnect, and every effect class; schemas and local policy hold, consent survives restart, safe calls converge, and unsafe ambiguity stops |
| 38 | Race fifty scheduler owners and kill at claim/outbox/request/complete seams; each nominal occurrence maps to one logical request and delivery status never substitutes for execution status |
| 39 | Model DST gaps/folds, leap days, timezone database change, clock rollback/jump, long downtime, jitter, edits, every misfire/overlap policy, and saturation; history is deterministic and backlog remains bounded |
| 40 | Revoke grants after schedule creation, alter behavior/capabilities, remove approval destinations, and attempt self-edit; execution narrows/denies/escalates and no action precedes an exact accepted plan |
| 41 | Fuzz source collisions, same-version content swaps, file watcher races, removal, and resume; bindings are explicit, digests change, epochs transition only at boundaries, and unavailable exact trees stop |
| 42 | Fuzz YAML, archives, paths, symlinks/hard links, resource sizes, scripts, dependencies, secrets, and `allowed-tools`; loading is inert, reads stay contained, and execution uses the ordinary policy/effect boundary |
| 43 | Crash install/update/uninstall at every seam; attempt malicious provenance, capability widening, candidate data leakage, evaluator use, and self-approval; only atomically installed, independently evaluated artifacts activate |
| 44 | Route an unbounded synthetic source, a user request, a scheduled occurrence, and one graph's `StreamPart`s concurrently; each uses its own contract and only a persisted Situation admission starts an agent episode |
| 45 | Fuzz identities, source signatures, tenant bindings, schemas, hashes, sizes, nesting, units, clock skew, sequence, classification, duplicates, and conflicting ids; only valid bounded events advance state and every outcome is durable |
| 46 | Replay reordered, late, idle, skewed, silent, and corrected sources under virtual event/processing clocks; watermarks never regress, windows stay bounded, and Situation bytes/admission history are identical |
| 47 | Race partitions and kill at every statement around event/Situation/admission/outbox/checkpoint commit; observe the old or complete new transition, deterministic per-partition order, and no I/O inside the transaction |
| 48 | Saturate every overflow policy, exhaust spools, interrupt acknowledgements, and inject sequence gaps; memory/disk stay bounded, semantic sampling is declared, and no loss or false completeness is silent |
| 49 | Cause trigger storms, cooldown, cost pressure, expiry, and mid-episode correction; admission history explains every case, one episode remains active, and superseded output cannot become a current Decision |
| 50 | Attempt direct effect calls, stale/expired approvals, changed device state, scope/bound violations, disabled interlocks, duplicate/ambiguous commands, and prompt-injected intents; only a current typed policy-approved Command reaches the simulated effector |
| 51 | Give deterministic, recorded, shadow, and counterfactual replay jobs production-looking payloads; assert no real credential/effector is reachable, R4 remains advisory, interlocks cannot be changed, and spec/authority candidates cannot self-promote |
| 52 | Interrupt after effects and alongside successful siblings, then retry, crash, and transfer the lease; activation/effect ids remain stable, attempt ids/bases change, siblings are not rerun, and stale attempt results cannot commit |
| 53 | Race duplicate enqueue before any lease, enqueue ordered queue/redirect inputs from many surfaces, and kill at every state transition; one request row/execution exists per id, FIFO holds, redirects reconcile, and recovery is explicit |
| 54 | Expire a lease while each effect class is prepared/running/unknown, request deletion, then deliver late receipts; tombstoning blocks new work, purge cannot erase unresolved truth, receipts commit, and the final report accounts for every record |
| 55 | Give tasks insufficient evidence and hostile read-only claims from MCP/skills; discovery remains inside reviewed roots/budgets with no mutation/delegation/script/effect, and only a separately accepted evidence-backed action plan can act |
| 56 | Drive inbound through every disposition (request/decision/ignored/rejected) with unbound/anonymous/group/oversize/malformed shapes; message content naming profiles or tools never reaches policy |
| 57 | Saturate the outbox, kill at every offset/claim/send seam, and replay an ambiguous send; no lost answer, no offset past an undurable disposition, no blind retry, and the reserved terminal delivery survives saturation |
| 58 | Replay, expire, swap user/chat/message/binding, forge a grant action, and race two presses; only one exact valid denial is consumed and both safety counters stay zero |
| 59 | Run one fixture observed, unobserved, with a raising recorder, with a hanging collector, and with a malformed payload under a null notifier; assert identical committed bytes and message order, unchanged latency, bounded memory in both lanes, no raise into the caller, and that the registry gate fails on an unregistered name or an identifier used as a metric label |
| 60 | Property-test secrets and credential shapes across every signal surface; enable each content class in turn; assert restricted classifications refuse capture at load and that omitted content yields a stable digest and size |
| 61 | Duplicate a request, `kill -9` mid-turn, resume through an approval decision, fork, and restore from backup; assert one reproducible trace id per execution with a parent link across the fork, ordering-only spans marked as such, derived counters equal to `tamoz status`, cost values carrying their basis, and a counted divergence when the bulk lane drops |

## Fault model

The suite tests process termination, raised exceptions, cancellation, lost lease, storage
busy/full/corrupt responses, serializer rejection, and delayed worker completion. It does
not claim to survive loss of the underlying database file without a backup, Byzantine
adapters, or a remote effect that is both non-idempotent and impossible to reconcile.

Crash equivalence is defined at **committed barriers**. Work after the last barrier may be
re-executed. Clause 21 controls whether that replay is safe.

## Change control

Changing an invariant requires:

1. an ADR describing the user-visible break;
2. a checkpoint and graph migration or a deliberate fail-fast boundary;
3. conformance tests for old and new behavior;
4. release notes naming the earliest affected format and graph versions.

No concept-count limit can overrule a correctness requirement. Public vocabulary still
stays small, but correctness contracts are not cut to hit an arbitrary number.
