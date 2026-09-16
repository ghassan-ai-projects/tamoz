# F21-SEC-01 and F25-SEC-01 — profile authority is not integrity-bound across replay and worker restart

| Finding | Functionality | Severity | Confidence | Status |
|---|---|---|---|---|
| F21-SEC-01 | F21 `tamoz-agent-profile`; affected F24 CLI and CF05 authority/replay | **Critical** conditional local authority bypass | **High** | **Open, confirmed** |
| F25-SEC-01 | F25 `tamoz-agent` worker; affected F21/F22 and CF05/CF06 | **Critical** restart-time authority change | **High** | **Open, confirmed** |

## F21-SEC-01 — replay accepts a widened snapshot with the old digest

### Finding and exact trigger

Loading a profile file computes `canonical_digest` from the normalized document
(`gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:401-421,574-575`). The durable
`authority_snapshot` carries that digest together with the authority surface
(`.../profile.rb:176-203`). Replay treats the snapshot as untrusted, but
`from_authority` passes the caller's `canonical_digest` through
`enforce_authority_shape!`; that method checks only the `sha256:` syntax and returns
the supplied value. It never recomputes or compares a digest over the validated
snapshot (`.../profile.rb:266-303`).

The CLI gate therefore becomes tautological: it compares the replay object's copied
digest with the separately stored `profile_digest` (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_authority.rb:166-179`). A caller able to alter the stored snapshot can retain the old digest, add valid action tools, change `allow_changes`, or change other validated authority fields, and pass the gate. The accepted profile is then used wholesale to build the toolbox, including `allowed_tools` and mutation policy (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:675-684`). Existing-session commands do reach this path: `cmd_resume` resolves authority before `run_durable` constructs the session (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:43-50; gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:579-605`).

The storage threat is local. Runtime directories are `0700` operator authority and
SQLite files require current-user ownership and `0600`
(`gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:25-28,61-67,232-238`;
`gems/tamoz-sqlite/lib/tamoz/sqlite/database_file.rb:13-15,105-124`). No untrusted
workspace path to edit the checkpoint was found. A same-user process, damaged or
restored storage, or mutable embedding can reach replay. That limits the attacker
model but does not remove the violated content-addressing contract.

### Impact across the six lenses

| Lens | Assessment |
|---|---|
| Correctness | The digest claims one authority while the replayed fields describe another. The session may execute a surface that was never the content producing the recorded digest. |
| Security/authority | A coherent snapshot can widen `tools.allowed`, mutation policy, checks, model roles, root, or egress within the validator vocabulary. The existing invariant requires content-addressed capability authority (`docs/design-v0.1/INVARIANTS.md:82-88`). |
| Reliability/durability | Checkpoint replay is no longer deterministic from durable bytes plus a verified digest. A later resume can produce different capability behavior while reporting the old profile epoch. |
| Observability/evidence | The CLI prints/retains the old digest and emits the normal pinned-authority path; there is no integrity mismatch or transition receipt for the changed fields. |
| Scalability/resource bounds | No resource exhaustion was found; the defect is authority integrity. |
| Maintainability/architecture | The comment promises tampering can only narrow or fail (`profile.rb:260-265`), while the gate relies on a value the same input controls. |

### Evidence and test gap

A temporary profile/toolbox probe retained the original digest while widening the
allowed tools to `read_file`, `list_directory`, `search_text`, `apply_patch`, and
`create_file`, and recomputed the matching toolbox catalog digest. `Profile.from_authority`
succeeded and the actual private CLI `pinned_authority` gate returned the widened
profile with `cli_gate_accepts => true`; output is in
`/tmp/tamoz-agents/analyze_profile_binding.log`.

The focused suites pass: `ruby -Itest test/agent_profile_transition_test.rb` (11
runs, 72 assertions) and `ruby -Itest test/agent_cli_profile_test.rb` (10 runs, 84
assertions). The replay test covers an unchanged snapshot
(`test/agent_profile_transition_test.rb:71-87`); its tamper cases cover malformed,
unknown, or obviously unsafe values (`:89-123`), not a valid widened snapshot that
retains the digest. The changed-profile CLI test only proves that the current file's
narrowed surface does not replace an intact snapshot (`test/agent_cli_profile_test.rb:80-110`).
### Five whys

1. A widened replay passes because `from_authority` returns the snapshot's caller-supplied digest.
2. The shape gate validates digest format, not digest equality to the rebuilt authority.
3. `pinned_authority` compares that copied value to `profile_digest`, so both sides can agree on a false claim.
4. The checkpoint is treated as untrusted structurally, but its content is not cryptographically or canonically bound to the stored profile digest.
5. Tests encode malformed-input rejection and unchanged replay, while the design assertion that validators alone prevent widening was never tested against a coherent valid mutation.

### Recommendation and disposition

Use the existing `Profile.from_authority` seam to compute the digest from the exact
validated authority representation and reject any mismatch before constructing
`Fields`; do not compare against the current profile file, because old-digest replay
is intentional. The snapshot and digest definition must cover the same fields: either
include every digest-covered document field or define a versioned digest over the
complete pinned projection at initial binding. Add a regression with widened tools,
policy, check, root, and role fields that preserves the old digest, and assert both
`from_authority` and `pinned_authority` fail before toolbox/model execution.

Prior P8/DR5 material requires candidate transitions and snapshot replay rather than
the current file (`docs/reviews/P8_TRUSTED_PROFILES_PLAN_REVIEW.md:49-56`;
`docs/DR5_PROFILE_MACHINERY_PLAN.md:85-98`). It does not establish snapshot
integrity: DR5 treats the existing equality check as the stop, and tests omit this
coherent mutation. This is separate from credential-ref replay handling.

## F25-SEC-01 — worker restart reloads the current profile for an old thread

### Finding and exact trigger

The worker's durable thread binding stores only a profile ID and says that the
profile's content comes from the runtime directory (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:107-139`). On every fresh runtime, `session_for` reads that ID
(`.../worker_runtime.rb:690-706`), `profile` loads the current `profiles/<id>.yaml`
(`.../worker_runtime.rb:750-842`), and `build_session` injects that current profile
and its budgets (`.../worker_runtime.rb:1030-1055`). There is no read of the existing
session's `profile_digest` or `profile_authority` in this path.

The normal worker command creates a new `WorkerRuntime` and resolves sessions through
this builder (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:273-283`).
Queued and recovery paths call the durable runner directly
(`gems/tamoz-agent/lib/tamoz/agent/worker.rb:509-541`). `Session#guard_state!` checks
graph, skill, MCP, egress, and behavior, but not profile authority
(`gems/tamoz-agent-session/lib/tamoz/agent/session.rb:434-449`). Intake then records
the newly constructed profile's ID, digest, snapshot, roles, and budgets
(`gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:51-61,155-172`),
overwriting old evidence.

An operator can trigger this with supported `profile import`, which writes the target
and activates its digest (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_profile_commands.rb:229-247,277-295`), followed by a worker restart processing an existing queued or recoverable thread. No per-thread `ProfileTransition` is consumed. The operator-only limitation applies, but the ordinary restart path still violates in-flight pinning.

### Impact across the six lenses

| Lens | Assessment |
|---|---|
| Correctness | Behavior depends on worker process lifetime. The same queued request can run under old authority before restart and current authority after restart. |
| Security/authority | A profile edit can widen old-thread tools, mutation policy, root, model roles, budgets, or egress without an explicit transition. This violates the in-flight pinning contract (`docs/design-v0.1/AGENT_DESIGN.md:115-127`; `docs/PROJECT_HANDOVER_PLAN.md:278-296`). |
| Reliability/durability | Crash/restart is a semantic authority change, so durable recovery is not replay of the original execution context. The stored digest is replaced, erasing the prior boundary evidence. |
| Observability/evidence | Worker events show claim/completion, but no transition or profile-change event explains why the session record changed digest. A post-restart audit sees the new authority as if it were the original intake. |
| Scalability/resource bounds | Per-profile memoization is bounded; restart timing can change several threads sharing one ID. |
| Maintainability/architecture | CLI has a transition resolver; worker has an ID-to-current-file resolver. Direct runner calls bypass the session guard. |

### Evidence and test gap

A temporary runtime probe created an old thread, queued work, edited the operator
profile to add mutation tools and `allow_changes`, then used a fresh `WorkerRuntime`
and `Worker#poll_once`. It progressed with
`request.claimed`/`request.completed`; the old session digest was
`sha256:2166721917e2c9785cd7a22761590a8bbf7c04a0e42f28ce76033f5a7ee9db7b`, while the
final record held `sha256:7a78c97bcc384689c13237bc6e4a3d6221e960ab79087cd3081b1c89aa339c1c`
and the final toolbox exposed `apply_patch` and `create_file`. The full output is in
`/tmp/tamoz-agents/analyze_profile_binding.log`.

`ruby -Itest test/agent_worker_test.rb` passes (25 runs, 122 assertions), but its
profile tests cover unknown IDs/path safety and normal queue execution, not edit plus
restart. The CLI changed-profile tests use the separate resolver. No worker-level
transition or digest-preservation test was found.

### Five whys

1. An old thread runs under the edited profile because the restarted worker resolves only its profile ID.
2. The thread binding stores no digest or authority snapshot, and `session_for` never consults the existing session record before loading YAML.
3. Worker claim/recovery calls the durable runner directly, so the CLI authority resolver and `Session#guard_state!` do not enforce the boundary.
4. `guard_state!` has explicit checks for other epoch bindings but no profile-binding check, despite `SessionBindings` persisting profile identity and authority.
5. Authority semantics were implemented as a CLI concern while unattended execution received a simpler current-file loader; tests covered the interactive path and left restart as a process-lifetime assumption.

### Recommendation and disposition

Make `WorkerRuntime#session_for` the worker authority seam: for an existing thread,
load the stored profile binding, reconstruct it through `Profile.from_authority`, and
retain it when the current file differs. Only an explicit durable transition at the
turn boundary may replace it; reuse CLI adoption/transition rules. Use the resolved
profile for budgets and toolbox, model, approval, and egress construction. Add a
profile guard before queued execution and recovery as defense against direct runner
entry points.

Add a temp-runtime regression that edits a profile between enqueue and a fresh worker,
asserts the old digest/tool surface remains, then records a transition and asserts
adoption only at the declared boundary. Include restart during recovery. F21-SEC-01
remains independent: replay integrity does not fix worker reload, or vice versa.

**Disposition: accept both as critical, confirmed, open findings.** The confidence is
high for source reachability and the bounded probes; blind spots are a separate
multi-process deployment and a real model/tool side effect. The normal operator-only
storage boundary was verified and is an exploitability qualifier, not evidence that
the two authority contracts hold.
