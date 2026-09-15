# Functionality audit — synthesized findings

Baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15. This index is the
coordinator's disposition of every accepted finding. It reconciles three inputs:
the independent analyst record in `analyses/<row>.md`, the adversarial challenge
record in `analyses/challenge-*.md`, and the coordinator's own reading of the cited
source. A finding's severity and status here are the audit's decision, not the
analyst's proposal — where a challenge changed a grade, the challenge governs and
the disagreement is recorded in `## Challenge outcomes`.

Read [BAR.md](BAR.md) for the severity, confidence, and closure rules, and
[COVERAGE.md](COVERAGE.md) for which rows have met the closure bar. Open findings
remain open; challenged, refuted, duplicate, and closed leads retain their
disposition below. This is a read-only audit and writing a report closes
nothing in production.

## Critical findings

| ID | Row | Severity | Confidence | Status | Owning seam | Challenge |
|---|---|---|---|---|---|---|
| F07-SEC-01 | F07 | critical | high | open, confirmed | `tamoz-sqlite` `EffectReconciler#resolve` row-scope guard | UPHELD — reproduced; reachability stronger than reported |
| F08-SEC-01 | F08 | critical | high | open, confirmed | `tamoz-tools` `check_runner.rb#credential_free_env` | UPHELD — live production path |
| F09-SEC-02 | F09 | critical | high | open, confirmed | `tamoz-agent-session` `session_effects.rb#mcp_payload` | UPHELD — corrected: terminal interrupt and misleading scorecard evidence |
| F25-SEC-01 | F25 | critical | high | open, confirmed | `tamoz-agent` `WorkerRuntime#session_for` thread profile binding | UPHELD — widened thread reached the model |

Four coordinator-confirmed critical findings survive independent challenge.
The raw analyst records still contain five critical proposals; `F09-SEC-02`
survived at critical after its consequence was corrected, while `F23-SEC-01`
and `F20-REL-01` were demoted to major for lack of a production caller.

## Dispositioned findings

The table preserves accepted findings after challenge, including demoted
minor/info items and closed leads. Severity reflects the current coordinator
disposition. `Challenge` is `pending` where a critical/major challenge is still
owed.

| ID | Row | Severity | Confidence | Owning seam | Challenge |
|---|---|---|---|---|---|
| A01-COR-01 | A01 | minor | high | `apps/tamoz-agent/app.json` namespace | DEMOTED — inert metadata, no consumer |
| E08-REL-01 | E08 | major | high | `bin/tamoz-stream-subscriber` reconnect loop | UPHELD — bounded cursor does not prevent retry waste |
| E09-REL-01 | E09 | major | high | `bin/tamoz-stream-worker` trap context | UPHELD — exit 134 is not asserted |
| F01-COR-01 | F01 | info | high | `tamoz-core` `jcs.rb#integer_to_s` | DEMOTED — exemption is pinned as intended |
| F01-SEC-01 | F01 | minor | high | `tamoz-core` `error.rb#DisclosableMessage` | REFUTED — no reachable leak; test gap remains |
| F02-SEC-01 | F02 | minor | high | `tamoz-cancellation` `process_group.rb#signal` | DEMOTED — no reachable unsafe caller |
| F02-OBS-01 | F02 | minor | high | `tamoz-agent` `Executor#cancelled` durable terminal fact | REFUTED as written — see replacement note |
| F03-REL-01 | F03 | major | high | `tamoz-concurrency` `stream_sink.rb#finish` | UPHELD — fix order verified deadlock-free |
| F03-REL-02 | F03 | major | high | `tamoz-concurrency` `drain.rb#close` | UPHELD — production consumers confirmed |
| F05-REL-04 | F05 | minor | high | `tamoz-scheduler` misfire ledger bound | DEMOTED — bounded per scan, deduped per cadence |
| F05-REL-05 | F05 | major | high | `tamoz-scheduler` `schedule_store.rb#materialize_due` | UPHELD — no CLI path clears the wedge |
| F05-REL-01 | F05 | minor | high | `tamoz-scheduler` `Schedule#definition_digest` validation | OPEN — forged digest metadata is durable but not an authority input |
| CF07-ARCH-01 | CF07 | major | high | scheduler store contract versus worker settlement methods | OPEN — a conforming non-SQLite store can remain enqueued forever |
| CF07-REL-02 | CF07 | major | high | SQLite occurrence completion execution-id fence | OPEN — wrong execution identity can complete a running occurrence |
| F06-SEC-01 | F06 | minor | high | `tamoz-stream` `situation_request.rb#wire_payload` | DEMOTED — contract/comment accuracy |
| F06-SEC-03 | F06 | info | medium | `tamoz-sqlite` `memory_store.rb#situation_boundary` | DEMOTED — documented design decision, no production pairing |
| F07-REL-01 | F07 | major | high | `tamoz-sqlite` `request_inbox_claimer.rb#candidate_rows` | UPHELD — threshold corrected to 8 |
| F08-REL-01 | F08 | major | high | `tamoz-tools` `staging_reaper.rb#collect` | UPHELD — reserved-prefix deletion |
| F09-COR-01 | F09 | minor | medium | `tamoz-mcp` descriptor effect/read-only contract | DEMOTED — no production reachability |
| F09-SEC-01 | F09 | major | high | `tamoz-agent-session` `session_effects.rb#mcp_planning_surface` | UPHELD — citation corrected |
| F10-SEC-01 | F10 | major | high | `script/websearch_adapter#load_provider` | UPHELD — exact-host contract applies |
| F10-SEC-03 | F10 | info | medium | `tamoz-agent-capabilities` MCP/websearch configuration | MERGED into CF05-SEC-01 — documentation/contract axis |
| F10-SEC-04 | F10 | closed | high | `tamoz-agent-capabilities` `mcp_source_builder.rb#build_validator` | REFUTED — production controls are present |
| F11-COR-01 | F11 | major | high | `tamoz-comms` `rendering.rb#split` | UPHELD — truncation marker absent |
| F11-SEC-01 | F11 | minor | high | `tamoz-comms` `rendering.rb#plain` | DEMOTED — no caller selects `restricted_html` |
| F11-SEC-02 | F11 | closed | high | `tamoz-comms` `admission.rb#decide` | REFUTED — revoked binding IS rejected |
| F11-SEC-03 | F11 | minor | high | `tamoz-comms` `admission.rb` callback branch | DEMOTED — second guard fails closed |
| F11-ERR-01 | F11→F07 | minor | high | `tamoz-sqlite` `comms_outbox.rb#mark_delivery` | DEMOTED — callers gated on the marker |
| F11-ERR-02 | F11→F07 | minor | medium | `tamoz-sqlite` `comms_outbox.rb#append_delivery` | DEMOTED — no producer makes a mismatch |
| F12-REL-01 | F12 | major | high | `tamoz-comms-gateway` delivery ordering | UPHELD — irreversible, contract violated verbatim |
| F13-COR-01 | F13 | major | high | schedule approval profile → approval-session binding | UPHELD — persisted profile is ignored at execution |
| F13-COR-02 | F13 | major | high | active-policy reload → `WorkerRuntime#sync_approval_policy` | UPHELD — profile overlay is dropped |
| F13-SEC-01 | F13 | major | high | `PolicyDocument#validate_tool_tiers!` no-session guard | UPHELD — tool override can mint reusable authority |
| F13-SEC-02 | F13 | minor | high | policy scope normalization/validation | DEMOTED — unsupported scope is currently inert |
| F13-REL-01 | F13 | major | high | `Approval::Engine#resolve` decision/grant handoff | UPHELD — resolution can outlive the grant row |
| F13-REL-02 | F13 | major | high | `Approval::Engine#rebind_session` durable mode-switch audit | UPHELD — memory changes before durable audit |
| F13-SEC-03 | F13 | major | medium | durable approval session grant lifecycle | QUALIFIED — supported session scope can survive a crash |
| F13-SCA-01 | F13 | info | high | SQLite approval decision retention | CLOSED — append-only retention is an accepted design |
| F14-COR-01 | F14 | major | high | `tamoz-telegram` `client.rb#call` 409 classification | UPHELD — bounded stall, not a lost row |
| F14-REL-01 | F14 | minor | high | `tamoz-telegram` `transport.rb#poll` | DEMOTED — rescued per thread, cost is exit 1 |
| F15-SEC-01 | F15 | major | medium | `tamoz-observability` `reason` attribute | UPHELD — retargeted to the live default path |
| F16-OBS-01 | F16 | major | high | `tamoz-otel` `async_exporter.rb#delivery_result` | UPHELD — `outcome` dropped |
| F16-SEC-01 | F16 | minor | high | `tamoz-otel` exporter has no enable path | DEMOTED — docs/ownership debt |
| F16-SEC-02 | F16 | major | high | `tamoz-otel` `http_exporter.rb#resource_spans` | UPHELD — not critical, gem unreachable |
| F17-COR-01 | F17 | info | high | `tamoz-agent-kernel` `session_steps.rb#journaled_verdict` | DEMOTED — `deep_freeze` closes the exploit |
| F17-REL-01 | F17 | major | high | same defect as CF04-REL-01 — do not double-count | UPHELD |
| F17-B9-01 | F17 | minor | high | `episode_nodes.rb` RISK_RANK duplication | DEMOTED + merged with B9-02 |
| F18-SEC-01 | F18 | major | high | MCP builder sidecar policy → session source digest | UPHELD — policy drift bypasses the resume pin |
| F18-COR-01 | F18 | minor | high | Core capability registry source identity | UPHELD — duplicate source IDs misalign dispatch |
| F18-SCL-01 | F18 | minor | high | MCP builder aggregate server/descriptor admission | UPHELD — no global resource bound |
| F18-OBS-01 | F18 | info | medium | caller-supplied MCP source provenance map | UNCONFIRMED — optional public contract |
| F18-MNT-01 | F18 | info | high | governed browser adapter reachability | CLOSED — injected-only phase boundary is documented |
| F19-DEL-01 | F19 | major | high | `tamoz-agent-memory` retention pass has no caller | UPHELD — mechanism corrected |
| F19-REL-01 | F19 | major | high | `transition_registry.rb#release_or_finalize` | UPHELD — fix larger than reported |
| F19-SEC-01 | F19 | major | high | admission → planning-context injection path | UPHELD — subject changed |
| F20-REL-01 | F20 | major | high | `remediation/session.rb` repetition bound | DEMOTED — no production caller |
| F20-REL-02 | F20 | major | high | `attempt_evidence.rb` raw Array instead of Outcome | pending — new challenger finding needs analyst re-review |
| F20-SEC-01 | F20 | major | high | `rule_registry.rb#assert_reviewed_diff!` | UPHELD — second unaudited verdict source |
| F21-SEC-01 | F21 | major | high | `Profile.from_authority` pinned snapshot digest | UPHELD — challenge retained major grade |
| F21-REL-01 | F21 | minor | high | `Profile::AdoptionRegistry#activate` shared-file update | OPEN — concurrent activation can be lost |
| F21-SEC-02 | F21 | info | high | secure profile load and authority validators | INFO — fail-closed trust boundary |
| F21-REL-02 | F21 | info | high | transition registry consume fence | INFO — identity-bound and flocked |
| F21-SCL-01 | F21 | info | medium | adoption/transition history size | UNCONFIRMED — no measured bound |
| F22-COR-01 | F22 | major | high | `session_bindings.rb#intake` cancel precondition | UPHELD — live state also loses receipts and check status |
| F22-REL-01 | F22 | major | high | same defect as F07-REL-01 — do not double-count | UPHELD (via F07) |
| F22-SEC-01 | F22 | major | high | `session.rb#guard_state!` never reads profile digest | UPHELD — independent downstream enforcement site |
| F23-COR-01 | F23 | major | high | `promotion.rb#assert_evidence_resolves!` | UPHELD — unkeyed seal |
| F23-COR-02 | F23 | major | high | `promotion.rb#rollback` | UPHELD — ledger claim, not served bytes |
| F23-MNT-01 | F23 | major | high | docs contradiction on the improvement pipeline | UPHELD |
| F23-REL-01 | F23 | major | medium | `candidate_lifecycle.rb#stage_result_phase` | UPHELD — weaker reproduction, recorded |
| F23-SEC-01 | F23 | major | high | `evaluation_report.rb#assert_human_gate!` | DEMOTED — no production caller |
| F24-ERR-01 | F24 | major | high | `cli.rb#run_durable` read-only `show` | UPHELD — fix precedent exists in-repo |
| F24-ERR-02 | F24 | minor | high | `cli.rb#parse_resume_options` `exit()` | DEMOTED — under-scoped, third victim found |
| F25-COR-01 | F25 | major | high | `worker.rb#settle_view` cancelled shown completed | UPHELD — worker-to-outbox probe |
| F25-SEC-02 | F25 | major | high | `worker.rb#exhausted_budget` inert budgets | UPHELD — four accepted budgets have no usage evidence |
| F26-ERR-01 | F26 | major | high | `verifier.rb#read_stable_file` zero-byte file | UPHELD — zero-byte probe raises `NoMethodError` |
| F26-EVD-01 | F26 | major | high | `docs/requirements-audit.json` is stale | UPHELD — stale artifact provenance; S01/R01 owner |
| F26-EVD-02 | F26 | minor | high | `script/generate_requirements_audit#run_case` assertion-count gate | OPEN — mechanism confirmed; no committed zero-assertion row |
| F27-COR-01 | F27 | minor | high | `scoreboard.rb#validate_run!` | DEMOTED — doc splits the responsibility |
| R01-GATE-01 | R01 | major | high | `Rakefile:444` `ci` omits the quality gates | UPHELD — add budget evidence to the fix |
| R01-GATE-02 | R01 | major | high | `script/release_rehearsal:157` runs `ci` not `ci_full` | UPHELD — script and plan disagree |
| R01-GATE-04 | R01 | major | high | `Rakefile:425` `quality` aggregate is enola-only | MERGED into R01-GATE-01 — same gate composition root cause |
| S01-BEN-01 | S01 | major | high | nine unbounded `Open3.capture*` call sites | UPHELD — seven scripts, nine call sites |

## Coordinator dispositions

- **Four criticals stand.** `F07-SEC-01` (a thread-B lease resolves a thread-A
  effect), `F08-SEC-01` (the `run_check` child inherits operator credentials the
  deny-list does not name, on a live production path, against a written
  `SECURITY.md` guarantee), `F09-SEC-02` (durable MCP interruption is destroyed
  and a scorecard counter is misleading), and `F25-SEC-01` (a thread restarted
  under a widened profile reaches the model). Each survived an adversarial
  challenge that attempted reproduction and severity attack.
- **Two other critical proposals did not survive.** `F23-SEC-01` was demoted
  because the promotion gate has no production caller and the gem activates
  nothing. `F20-REL-01` was demoted to major for the same reachability reason.
- **Findings refuted or closed.** `F11-SEC-02` is `closed`: a revoked binding IS
  rejected before the allowlist. `F01-SEC-01` is refuted as a leak (the residual is
  a test-coverage gap). `F02-OBS-01` is refuted as written — the cited method does
  not exist and a token cancel writes *nothing* durable; the surviving fact is a
  narrower finding at `Executor#cancelled`, recorded as `minor`.
- **Duplicates collapsed.** `F17-REL-01` = `CF04-REL-01`; `F22-REL-01` = `F07-REL-01`;
  `F17-B9-02` merged into `F17-B9-01`; `F17-B9-01` merged into `F01-MNT-01`'s family
  by the challenger's ruling. These are indexed once, under their owning row.
- **Ownership moves.** `F11-ERR-01` and `F11-ERR-02` are owned by **F07**: `tamoz-comms`
  ships no store implementation. `F14-COR-01` stays on F14 with F12 as co-owner of
  the handling half.
- **The single systemic theme.** Three independent gates decide approval from an
  unbound `"human:"`-prefixed String rather than from the policy data seam
  (`F20-SEC-01`, `F23-SEC-01`, and the healing/improvement family). AGENTS.md makes
  `gems/tamoz-approval/policy/*.yaml` the only legitimate source of a verdict. This
  is the highest-value architectural finding in the audit even though each instance
  is graded `major` rather than `critical` for want of a reachable unsafe caller.
- **Evidence-quality theme.** Several rows have correct mechanisms with unreached
  or unwired callers (`F19-DEL-01`, `F20-REL-01`, `F16-SEC-01`). The pattern is a
  shared one: a capability is implemented, tested in isolation, and documented,
  but nothing in the shipped system calls it. F26-EVD-01 is a separate generated-
  artifact freshness gap: the committed evidence no longer matches its manifest.
- **F13 approval disposition.** The independent challenge upheld six major
  findings: schedule approval profiles are not carried into execution, reload
  drops the selected overlay, tool overrides bypass no-session tiers, resolution
  and grant persistence can split, mode rebinding can publish before its audit,
  and a supported durable session grant can survive a crash. `F13-SEC-02` is
  demoted to minor because unsupported scopes are currently inert; `F13-SCA-01`
  is closed as an explicitly accepted append-only retention design.
- **F18 capability disposition.** `F18-SEC-01` remains major: MCP sidecar policy
  changes are absent from the resume source pin. Duplicate source IDs and the
  missing aggregate MCP bound remain minor. The optional provenance map is an
  unconfirmed info contract, and the browser item is closed as a documented
  injected-only phase boundary.
- **F21 profile disposition.** `F21-SEC-01` remains major after the existing
  profile challenge qualified the threat model to the local operator trust root.
  `F21-REL-01` records the concurrent adoption-write race as minor; the secure
  loader, transition fence, and history-bound notes are recorded as info.
- **F25 runtime disposition.** The independent challenge upheld `F25-COR-01`: a
  cancellation redirect can be emitted as `request.completed`/`Verified` while
  its terminal reason and body say cancellation and unsatisfied verification.
  It also upheld `F25-SEC-02`: four accepted profile budget keys are carried and
  pinned but never compared with runtime usage. Both remain major/open at the
  worker seams; the existing target-request race control is not a duplicate.
- **F26 evidence disposition.** The independent challenge upheld `F26-ERR-01`:
  a zero-byte artifact escapes the typed verifier/CLI error contract. It upheld
  `F26-EVD-01` with a narrower stale-manifest/audit provenance scope owned by
  S01/R01, and confirmed `F26-EVD-02` as a minor generator contract gap with no
  current zero-assertion occupant. All remain open; no artifact was regenerated.
- **Cross-flow disposition.** `CF07-ARCH-01` and `CF07-REL-02` are accepted as
  open major boundary findings after the schedule challenge. The separate
  `flows-CF09-CF11.md` report remains an analyst lead set awaiting explicit
  coordinator challenge and indexing; it does not close CF09–CF11 rows.

## Challenge outcomes

Sixteen challenge records are indexed under `analyses/challenge-*.md`. The
current waves added independent challenges for F13, F18, F25, and F26; F21 uses
the existing `challenge-profile-authority.md` record. Each challenge states
whether the finding reproduced, the control case, ownership, and the resulting
severity. F13's challenge demoted one major to minor and closed one design lead;
F18's challenge closed the browser reachability lead while retaining its major
and minor dispositions; F25 upheld both pending majors; and F26 upheld both
pending majors while narrowing their ownership.

A challenge record is required for every critical/major finding per [BAR.md](BAR.md).
Rows marked `pending` above are owed one; see [CHECKPOINT.md](CHECKPOINT.md).
