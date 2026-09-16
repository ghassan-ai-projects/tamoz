# CF11 — failure classification, safe remediation, candidate improvement, and promotion/rollback — IMPROVE

## Row, boundary, and method

- **Row:** CF11 — failure classification, safe remediation, candidate improvement, promotion/rollback.
- **Code baseline:** branch `audit-15-09`, source commit `582ae5566de1ae073aea82b69bb2bbf444494d3b`.
- **Analyst:** coordinator direct source review; delegation was paused by the owner for this continuation.
- **Method:** traced the typed-failure, remediation, retry, improvement, and behavior-transition paths; re-read the healing and improvement challenges and the F20 re-review; ran the focused contracts and two bounded probes. No production, test, configuration, generated, or unrelated documentation file was changed.

## Source map and ownership

| Source | Boundary role |
|---|---|
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/failure_record.rb:145-234,350-371` | typed failure identity and untrusted-content boundary |
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/classification.rb:104-119,152-177` | typed classification, abstention, and never-mutate routing |
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation.rb:38-76` | public remediation entry point and session construction |
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation/session.rb:25-54,168-249,280-284` | plan/review/preflight/effect/verification state machine |
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation/attempt_evidence.rb:20-52` | transition ledger and return-value seam |
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/preflight.rb:110-128,193-200` | ordered preflight checks and caller-supplied attempt comparison |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb:88-151` | production tool-repair repetition bound and failure identity |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb:20-34,100-106` | session repair configuration and `MAX_REPAIR_ATTEMPTS` |
| `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/evaluation_report.rb:220-235` | promotion human-gate predicate |
| `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/promotion.rb:38-65,209-262,306-361` | candidate promotion, provenance, and transition record |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/transition_registry.rb:70-243` | behavior transition record, claim, finalize, and recovery seam |
| `gems/tamoz-agent-healing/README.md:8-20` and `gems/tamoz-agent-improvement/README.md:5-33` | public contract and ownership claims |

The healing gem owns typed failure, classification, reviewed remediation, and
the verification/compensation protocol. The session gem owns the repair loop
that is actually called by the runtime. The improvement gem records a pending
behavior transition; memory claims and finalizes it at a later thread intake.
The approval engine owns the policy-data decision path, but promotion accepts a
free-form `human:` artifact and has no approval dependency. Those boundaries are
already represented by F20-REL-01/F20-REL-02 and F23-SEC-01; this flow review
checks whether the cross-gem path creates a distinct defect.

## End-to-end behavior path

1. `FailureRecord` accepts bounded typed fields and stores a digest/fingerprint;
   free-form message keys are refused (`failure_record.rb:145-173,350-371`).
2. `Classification.classify` reads `typed_signal` only. Abstention and the
   never-mutate classes route to `:escalated` before a plan or effect
   (`classification.rb:104-119,152-177`; `remediation/session.rb:25-42`).
3. A mutating classification is given a plan, semantic review, and ordered
   preflight. The preflight attempt check compares the caller's `attempt` with
   the rule budget; the healing session does not retain cross-run attempt state
   (`preflight.rb:110-128`; `remediation.rb:63`; `session.rb:19,46,84,258`).
4. `EffectExecution` dispatches through the existing `EffectDispatcher`; the
   session records the receipt and handles `:unknown`, `:wait`, or `:failed`
   (`remediation/session.rb:142-186`; `effect_execution.rb:30-43`).
5. Unknown/wait outcomes terminate unresolved. A failed outcome records
   `:uncertain`, but the transition helper returns the ledger array. The
   truthiness guard in `Session#call` returns that array before verification,
   compensation, terminal validation, or escalation (`session.rb:48-54,168-186`;
   `attempt_evidence.rb:27-31`).
6. Successful effects reach the configured oracle; only a passing oracle can
   produce `:recovered`, while failed verification enters compensation and
   escalation (`session.rb:187-218,238-249`; `oracle.rb:60-75`).
7. The runtime's separate session repair loop bounds repeated failure signatures
   and attempts at two (`session_evidence.rb:124-151`; `session_nodes.rb:26,103-105`).
   A repository-wide production-caller sweep found no call to
   `Remediation.run`, `RuleRegistry`, or `Promotion#promote`.
8. `Promotion#promote` verifies the report/provenance and records a pending
   transition; memory's `TransitionRegistry` later claims and finalizes it
   (`promotion.rb:38-65`; `transition_registry.rb:70-243`). The promotion gate
   checks only a caller-supplied `human:` prefix (`evaluation_report.rb:220-235`).

## Six-lens review

### Correctness

Reviewed. Typed classification and abstention preserve the never-mutate classes,
and the oracle-backed terminal invariant is enforced in the normal path. The
failed-effect branch is a real public contract defect: a remediation call can
return an `Array` rather than the documented `Remediation::Outcome`, so the
declared verify/compensate path is skipped. The direct probe reproduced
`AttemptEvidence#record` and `handle_ambiguous_effect(:failed)` as a truthy
`Array`; the public F20 re-review owns this same seam as **F20-REL-02**. CF11
does not create a second count.

### Security and authority

Reviewed. Failure classification consumes typed fields, legacy text is
non-mutating, and in-band self-modification guards do not trust the caller's
actor string. The improvement gate is weaker: any non-empty string beginning
with `human:` passes, and `tamoz-agent-improvement` declares no
`tamoz-approval` dependency. The existing F23 challenge confirms the gate and
also confirms that promotion has no production caller and records
`activated: false`. CF11 carries **F23-SEC-01** and adds no new authority
finding.

### Reliability and durability

Reviewed. Effect execution uses the durable dispatcher and recovery/rollback
records use the memory transition registry. The healing layer itself has no
cross-attempt repetition state: `attempt:` is forwarded to preflight and the
default circuit counts failures without comparing a fingerprint. The session
layer has the only production repair bound, so the missing healing-side bound is
the existing **F20-REL-01** finding, with its reachability qualification. No
second reliability finding is justified by this flow.

### Observability and evidence

Reviewed. Normal transitions include failure/rule versions, digests, trace and
effect ids, actor, fence, timestamp, evidence, and budgets. On a failed effect,
the `:uncertain` transition is recorded, but the caller receives no terminal
`Outcome`, escalation id, verification, or compensation receipt. That is the
observability face of F20-REL-02, not a separate defect. The focused tests do not
exercise a failed dispatcher result through the public entry point.

### Scalability and resource bounds

Reviewed. Failure ids, rule budgets, plan/review fields, preflight checks,
effect attempts, and heuristic insertions have explicit limits. The healing
protocol can nevertheless be re-entered indefinitely if a future caller varies
trace/call identity, because it has no identity-keyed cross-run bound. The
running session path is bounded at two attempts; the uncalled healing vertical
and its missing ownership are covered by F20-REL-01. No load or soak evidence
was used.

### Maintenance and architecture

Reviewed. Dependencies are directed: healing dispatches through the kernel and
does not create another effect engine; improvement records through the memory
registry rather than activating a second behavior store. Two remediation
verticals exist, however: the tested healing protocol is unwired while the
session repair loop is wired and bounded. The public documentation attributes
the bounded property to the broader healing concept without naming that split.
This is the ownership/documentation face of F20-REL-01, while the unbound
promotion artifact remains F23-SEC-01. No new machine-counted finding is added.

## Focused tests and probes

Each command was run from the repository root, one test file per command. No
real provider, external approval service, or network system was used.

| Command | Runs | Assertions | Failures | Errors | Skips |
|---|---:|---:|---:|---:|---:|
| `ruby -Itest test/healing_remediation_test.rb` | 13 | 74 | 0 | 0 | 0 |
| `ruby -Itest test/healing_failure_contract_test.rb` | 35 | 264 | 0 | 0 | 0 |
| `ruby -Itest test/improvement_candidate_test.rb` | 14 | 284 | 0 | 0 | 0 |
| `ruby -Itest test/agent_improvement_lifecycle_test.rb` | 6 | 13 | 0 | 0 | 0 |

Total: **68 runs / 635 assertions / 0 failures / 0 errors / 0 skips**.

- `/tmp/cf11_rel02b.rb` directly drove the `:failed` branch and printed
  `AttemptEvidence#record returns: Array truthy=true` and
  `handle_ambiguous_effect(:failed) returns: Array truthy=true`.
- `/tmp/cf11_rel02_probe.rb` drove three public `Remediation.run` cycles with
  changing trace/call identity; this setup returned three ordinary escalated
  `Outcome` values because it did not reach a failed dispatcher status. That is
  recorded as a negative end-to-end probe, not used to dismiss the unconditional
  branch defect.
- `rg` over production `gems/`, `apps/`, `bin/`, and `script/` found no shipped
  caller for `Remediation.run`, `Promotion#promote`, or `RuleRegistry`.
- `rg` over `gems/tamoz-approval/policy/*.yaml` found no improvement,
  heuristic, candidate, or promotion policy entries.

## Findings and coordinator disposition

No independent CF11 finding is added. The three lead proposals are real
observations, but each has an existing owner, challenge, source citations, and
machine-counted record:

| Lead proposal | Evidence rechecked | CF11 disposition |
|---|---|---|
| `CF11-COR-01` — failed effect returns a raw transitions array | `attempt_evidence.rb:27-31`; `remediation/session.rb:48-54,168-186`; `/tmp/cf11_rel02b.rb` | **Duplicate of F20-REL-02**, major/high/open. F20 owns the failed-effect return contract; CF11 carries the cross-gem consequence without a second count. |
| `CF11-REL-01` — healing repetition bound is absent while session owns one | `remediation.rb:63`; `session.rb:19,46,84,258`; `session_evidence.rb:124-151`; production caller sweep | **Duplicate of F20-REL-01**, major/high/open. The shipped session loop is bounded; the healing implementation remains unwired and unbounded if later called. |
| `CF11-MNT-01` — promotion authority artifact is a consumer-minted `human:` string | `evaluation_report.rb:220-235`; `promotion.rb:38-65`; improvement gemspec; approval policy sweep | **Duplicate of F23-SEC-01**, major/high/open after its critical-to-major challenge demotion. No production promotion caller exists and activation is pending by design. |

Carried findings remain visible at their owning seams: `F20-REL-01`,
`F20-REL-02`, `F20-SEC-01`, `F23-SEC-01`, `F23-COR-01`, `F23-COR-02`,
`F23-REL-01`, and `F23-MNT-01`. They are excluded from CF11's machine counts.

## Blind spots

- There is no production caller for the healing remediation or improvement
  promotion APIs, so reachability is established by exhaustive source search,
  not by a running worker trace.
- The public end-to-end probe did not force a failed dispatcher outcome; the
  direct branch probe proves the unconditional return-value path instead.
- No test drives healing `attempt:` beyond one or asserts a cross-run
  repetition stop. The session repair tests are a different implementation.
- The eval-side promotion producer and any future behavior-transition consumer
  were not exercised with a real provider or multi-process race.
- No sustained load, long-lived memory, or real approval-service measurement
  was run.

## Verdict

**IMPROVE.** All six lenses, the complete failure-to-promotion trace, the
existing challenges, and focused contracts are reviewed. CF11 contributes no
new machine-counted finding: the raw-array defect, missing healing-side bound,
and unbound promotion artifact are carried under F20-REL-02, F20-REL-01, and
F23-SEC-01 respectively. The row remains IMPROVE because those accepted major
findings are open, even though CF11's incremental counts are zero.
