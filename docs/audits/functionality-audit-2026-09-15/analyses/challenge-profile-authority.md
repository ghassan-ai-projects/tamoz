# Independent challenge — F21-SEC-01, F25-SEC-01, CF05-SEC-01

Challenger: independent adversarial reviewer (separate agent from both analysts).
Date: 2026-09-15.
Baseline commit: `582ae55` on `audit-15-09` (`git rev-parse HEAD` verified at start).
Method: re-read every cited `file:line`; ran the named focused suites one file per
command; wrote three read-only `/tmp` probes against the real classes and the real
runtime directory (no production code, test, config, or doc edited; nothing committed).
All probes live under `/tmp/tamoz-challenge/` and are reproduced below with exact output.

## F21-SEC-01

### Source re-verified

Read in full, not trusted from the report:

- `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:184-203` (`authority_snapshot`) —
  the report's citation is **exact**. The snapshot carries `canonical_digest` as a
  member of the same hash as the authority fields.
- `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:266-282` (`from_authority`) —
  **exact**. It calls `enforce_authority_shape!`, builds a synthetic document, re-runs
  `validate_profile_fields!/validate_roots!/validate_model_roles!/validate_checks!/
  validate_tools!/validate_policy!/validate_egress!`, then
  `new(build_fields(synthetic, digest: digest, ...))`. No digest recomputation appears.
- `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:287-304`
  (`enforce_authority_shape!`) — **exact**. It checks unknown keys, missing keys, and
  `Tamoz::Core.valid_digest?(digest)` (syntax only), then `return digest`.
- `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:574-575`
  (`canonical_digest(hash)`) — **exact**. `Tamoz::Core.digest(DIGEST_DOMAIN, hash)`.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli_authority.rb:166-180` (`pinned_authority`)
  — **exact**. `Profile.from_authority(snapshot)` then
  `pinned.canonical_digest == stored_digest`; on mismatch a `ValidationError`.

Two things the report did **not** say, which I verified and which matter:

1. The digest is over the **whole profile document** (`canonical_digest(hash)` at
   `profile.rb:418` during load), but the snapshot is only an 8-key projection of it
   (`AUTHORITY_KEYS`, `profile.rb:256-258`). Even a recompute-over-snapshot check would
   have to define a second, versioned digest domain — the report's recommendation says
   this, so the analyst saw it; but it means the asymmetry is **by construction**, not a
   forgotten `==`.
2. `cli_authority.rb:132-137` adds a **second** comparison,
   `AdoptionRegistry#activated?(stored_id, stored_digest)`
   (`profile/adoption_registry.rb:28-30`). The report does not mention it. I checked it:
   it tests membership of the *same retained* `stored_digest` in the operator's
   `activated` list, so it is not an independent guard over the snapshot content — it
   only proves the claimed digest was once activated. It adds nothing against a retained
   digest. That is a genuine gap in the report's guard enumeration, but it does not
   change the outcome.

### Reachability chain

Concrete steps to reach the defect, with no test-only machinery:

1. Operator runs a durable session under a trusted profile. `cmd_ask`
   (`cli_session_commands.rb:29-41`) → `run_durable` (`cli.rb:579-605`) → `Session.new`
   with `profile:` (`cli.rb:621-635`) → `SessionBindings#session_record`
   (`session_bindings.rb:155-172`) writes `profile_digest` **and** `profile_authority`
   into `<session_dir>/<thread>.sqlite3`.
2. Something with write access to that SQLite file rewrites the `profile_authority` JSON
   blob — widening `tools.allowed` to `apply_patch`/`create_file`, setting
   `policy.allow_changes: true`, updating `policy.tool_catalog_digest` to the widened
   toolbox's real digest — while leaving `canonical_digest` and the row's
   `profile_digest` at the old value.
3. Operator runs `tamoz resume <thread> --profile <same profile>`
   (`cli_session_commands.rb:43-52`). `resolve_session_authority` takes the
   `stored_digest == loaded_digest` fast path at `cli_authority.rb:113-114` and returns
   the **current file's** profile, so the tampered snapshot is not even consulted in
   that branch.

**Where the chain is weaker than the report implies.** Step 2 requires write access to
the session database. I verified the guards the report cites and they hold:

- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:606-614` (`provision_private_session_dir!`)
  refuses a session directory with any group/other bit.
- `gems/tamoz-sqlite/lib/tamoz/sqlite/database_file.rb:13-15,105-124` — `FILE_MODE 0o600`,
  `verify_identity!` refuses symlinks/non-regular files and any file not owned by the
  current uid.

So the attacker in step 2 is **the same uid as the operator**. There is no untrusted
path: the workspace cannot write there, a remote MCP catalog cannot, and a Telegram
channel cannot. This is the local-operator threat the coordinator already qualified.

**Also note the branch that actually matters is step 3's fast path**, not the replay:
when the operator edits the *profile file* the digest differs and the CLI replays the
snapshot through `pinned_authority` (that is the F21 path the report demonstrates). Both
branches land on the same conclusion, so the finding does not depend on which one the
attacker takes.

### Trust-model evidence

The repository's own language, quoted exactly:

- `SECURITY.md`: *"**Authority is local, intersected, and content-addressed.** A
  capability's effective authority is the intersection of the current profile, agent and
  task limits."* — the phrase "content-addressed" is the clause F21 violates: the
  replayed snapshot's content no longer addresses its digest.
- `documentation/architecture/security-model.md`: the same sentence, and the diagram
  label `PROFILE["trusted profile<br/>pinned sha256 digest"]`. The profile is *described*
  as pinned by a sha256 digest. That is a claim about the artifact.
- `docs/design-v0.1/INVARIANTS.md:82-88` (clause 35), which the report cites: *"Every
  local, MCP, skill, delegated, or scheduled capability has a source-qualified immutable
  descriptor; effective authority is the intersection of current application/agent/task/
  parent limits."*
- `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:9-11,24-27`: *"the operator-owned
  runtime directory: one place a worker is pointed at, and the only place its authority
  comes from… **Everything here is operator authority.** Nothing in the WORKSPACE … is
  ever consulted for configuration. That separation is the whole point: a checkout the
  agent can write to must never be able to widen what the agent may do."*
- `gems/tamoz-agent-profile/lib/tamoz/agent/profile/fields.rb:12-16`: *"The digest is a
  DURABLE contract. It is what a session pins itself to … its bytes are part of the
  on-disk format."*

**What this settles.** The repository's stated threat model is workspace-vs-operator, not
operator-vs-operator. The runtime directory, the profile file (`0600`, owned by the
effective uid, parent walk at `secure_file.rb:95-135`), and the session database
(`0600`, current-uid-owned) are **one trust root: the local operator's uid**. Nothing in
`SECURITY.md`, `security-model.md`, `invariants.md`, `AGENT_DESIGN.md`, the ADR corpus, or
`runtime_directory.rb` claims to defend against a same-uid writer. `profile.rb:260-265`
states the *intended* property — *"the snapshot is treated as untrusted input and re-runs
every validator, so a corrupted or tampered checkpoint can only narrow or fail, never
widen"* — and that sentence is **false as written** against a coherent valid widening, so
it is a real defect in the claim, not merely in the code.

**What it does not settle.** No document says "an integrity check over the checkpoint is
out of scope". The content-addressing claim is unconditional and appears in the top-level
policy. So the report's framing is defensible; the question is severity, not existence.

### Guards searched

```
grep -rn "profile_digest" gems/ test/ --include=*.rb   # 51 hits, all read
grep -rn "from_authority" gems/ test/ --include=*.rb   # 13 hits, all read
grep -rn "resolve_session_authority" gems/ test/       # 6 hits (1 def + 5 callers)
grep -rn "verify_profile_binding!" gems/ test/         # 6 hits
grep -rn "activated?" gems/tamoz-agent-profile/lib/tamoz/agent/profile/adoption_registry.rb
```

Every non-test hit read. Result:

- `from_authority` callers are exactly three: `CLIAuthority#pinned_authority`
  (`cli_authority.rb:172`), `Improvement::CandidatePolicy` (`candidate_policy.rb:51`, a
  candidate-proposal path with no stored digest to compare against), and tests.
- The only digest comparison in the whole repo over a replayed authority is
  `pinned_authority` (`cli_authority.rb:173`) plus the redundant
  `AdoptionRegistry#activated?` at `:133`. **Neither recomputes anything.**
- `session_options.rb:142-176` `verify_profile_binding!` checks the *toolbox catalog
  digest* and the *root*, not the profile's own canonical digest. It is not a second
  guard for this defect.
- `Session#guard_state!` (`session.rb:439-449`) has **no** profile check at all — it
  enforces graph, skill, MCP, egress, behavior. Confirmed by reading all five
  `enforce_*_binding!` bodies (`session.rb:206-285`).
- No DB constraint, registry, or session-level validation compares the replayed snapshot
  to its digest.

**No missed guard.** The report's guard enumeration is correct in substance.

### Probe

Path: `/tmp/tamoz-challenge/f21/probe.rb` (output: `/tmp/tamoz-challenge/f21/probe.out`).
Command: `ruby /tmp/tamoz-challenge/f21/probe.rb` from the repo root (read-only; probe
lives outside the repo). It builds a real narrow profile through `Profile.preview` with a
`0600` file and a real `Toolbox#catalog_digest`, takes its `authority_snapshot`, then
widens `tools.allowed` to `apply_patch`/`create_file`, flips `policy.allow_changes` to
true, and recomputes `policy.tool_catalog_digest` to the widened toolbox's true digest.

Exact output (representative run):

```
narrow canonical_digest=sha256:8f94d9a24903e78b8f3850bd78c9fff6a8a551647f1df6ada4a7ee2fa5b035e7
narrow tools_allowed=["read_file", "list_directory", "search_text"] allow_changes=false
unchanged_replay=OK tools=["read_file", "list_directory", "search_text"] digest_preserved=true
widened_replay=ACCEPTED
  tools_allowed=["read_file", "list_directory", "apply_patch", "create_file"]
  allow_changes=true
  digest_retained=true
  cli_pinned_authority_gate_accepts=true
  true_digest_of_widened_doc=sha256:c6321ec531ff58fe5ef48b1f38fe7cee2f07fd7a3bf8be43086d5040293105ad
composite_widened_replay=ACCEPTED tools=4 roles=["primary"] checks=["answer"] digest_retained=true
unknown_tool_control=REJECTED Tamoz::Agent::Profile::ValidationError
bad_digest_control=REJECTED Tamoz::Agent::Profile::ValidationError
narrowed_with_stale_digest=ACCEPTED digest_retained=true
guard_check: retained=sha256:8f94d9a24903e78b8f3850bd78c9fff6a8a551647f1df6ada4a7ee2fa5b035e7
guard_check: recomputed_over_snapshot=sha256:c6321ec531ff58fe5ef48b1f38fe7cee2f07fd7a3bf8be43086d5040293105ad
guard_check: recomputed_over_authority_snapshot_of_w3=sha256:c6321ec531ff58fe5ef48b1f38fe7cee2f07fd7a3bf8be43086d5040293105ad
guard_check: any_equality_asserted=false
guard_check: tool_catalog_digest_matches_rebuilt_toolbox=true
```

**I reproduced the claimed behavior.** Every validator control still fails closed
(unknown tool, malformed digest); the coherent widening with a retained digest does not.
The composite case shows tools, policy, checks, and model roles can all move together.

### Test evidence

`ruby -Itest test/agent_profile_transition_test.rb` → **11 runs, 72 assertions, 0
failures, 0 errors, 0 skips**.
`ruby -Itest test/agent_cli_profile_test.rb` → **10 runs, 84 assertions, 0 failures, 0
errors, 0 skips**.
`ruby -Itest test/agent_profile_machinery_test.rb` → **24 runs, 232 assertions, 0
failures, 0 errors, 0 skips** (not named by the report; I ran it because it holds the
resume-replay cases).

Pass counts match the report exactly.

**What these do not prove.** They prove malformed-input rejection and unchanged replay.
`agent_profile_transition_test.rb:91-123` tampers only with values the *validator
vocabulary* refuses (`execute_shell`, `harmless`, relative root, injected credential
name). `agent_profile_machinery_test.rb:887-918` proves the pinned snapshot beats a
*changed current file* while the snapshot is intact, and `:921-948` proves a digest
mismatch with no candidate stops. **No test constructs a coherent, structurally valid,
widened snapshot that retains its digest** — the only shape that exercises the defect.
The gap is exactly as the report describes.

### Verdict + reason

**DEMOTED — real defect, wrong severity; I assign `major`, not `critical`.**

The defect is real and I reproduced it. The challenge to the *severity* succeeds on
three independent grounds, none of which the report rebuts:

1. **The trust root is the attacker.** Every reachable path to step 2 requires the
   operator's own uid to write a `0600`, current-uid-owned file inside a `077`-checked
   directory. The operator who can do that can also just edit
   `profiles/<id>.yaml` directly and widen the profile outright — which is *not* a
   defect at all, because the profile file is authority by design
   (`runtime_directory.rb:24-27`). The F21 defect therefore buys an attacker who already
   holds the trust root **nothing they could not do more simply**. It is not an authority
   *bypass*; it is a *mislabeled* authority, and the label is only consumed by the same
   trust root.
2. **The BAR's `critical` definition is not met.** The BAR requires "an active defect or
   invariant/boundary violation that can cause an unsafe action, authority bypass, data
   loss, false completion, broken durability/effect semantics, or materially misleading
   evidence". The invariant-35/36 violation is real (I quote it above), but "can cause an
   unsafe action" is not reachable without the operator's own credentials. Severity is
   about reachable impact, and the reachable impact is bounded by the trust boundary the
   repo states.
3. **It is materially misleading evidence, which is a `major` adjective, not a
   `critical` one.** The concrete harm is that a session record asserts
   `profile_digest X` while its `profile_authority` describes a wider surface than X.
   An auditor reading that record sees a false claim. That is real operational cost —
   it breaks the content-addressing contract the top-level `SECURITY.md` states — which
   is exactly the BAR's `major` band: "material … security … gap with real operational
   cost".

Why the report's own reasoning does not save `critical`: it argues *"that limits the
attacker model but does not remove the violated content-addressing contract."* True — and
a violated contract with no reachable unsafe action is an integrity/hygiene gap. The
report never names an action the attacker gains, because there is none.

What would move it back to `critical`: any path where the checkpoint is written by
something *other* than the operator's uid — a multi-tenant worker, a restored backup from
an untrusted source, a shared session directory, or an embedding that accepts a
checkpoint. I searched for one (`database_file.rb` uid check, `provision_private_session_dir!`)
and found none. If such a deployment exists, the grade changes.

## F25-SEC-01

### Source re-verified

- `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:107-140` — **exact**. The comment
  says *"The binding names a profile; the profile's CONTENT always comes from the runtime
  directory. Work can say "run me as `trusted`", and can never say what `trusted`
  permits."* `bind_thread_profile` stores `{"profile" => profile_id}` and nothing else.
- `:690-706` (`thread_profile` / `session_for` / `session_for_profile`) — **exact**.
  `session_for` resolves to `session_for_profile(thread_profile(thread_id))`, i.e. an ID.
- `:820-842` (`profile` / `load_profile`) — **exact**. `@profiles[profile_id] ||=
  load_profile(profile_id)`, and `load_profile` reads `profiles/<id>.yaml` from the
  runtime directory. It reads the **current file**, and the auto-adoption lambda
  `->(_document) { true }` activates whatever digest it finds.
- `:1030-1057` (`build_session`) — **exact**. `resolved = resolved_profile ||
  profile(profile_id)`, then `profile: resolved`, `profile_budgets: resolved&.budgets`,
  `toolbox = session_toolbox(resolved, ...)`.
- `:1195-1209` (`session_toolbox`) — **exact**. `allow_changes: resolved.allow_changes?`,
  `allowed_tools: enforce_narrowed_tools(resolved, allowed_tools)`, root and checks from
  the current profile.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:273-283` — **exact**.
  `session_builder: ->(thread_id) { runtime.session_for(thread_id) }`.
- `gems/tamoz-agent-session/lib/tamoz/agent/session.rb:439-449` (`guard_state!`) —
  **exact**. Five `enforce_*` calls, none for profile.
- `gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:51-61,155-172` — the
  report cites `51-61` for the profile binding; the actual `profile_binding` body is at
  `:51-61` and `session_record` is at `:155-172`. **Both citations are correct**; the
  binding is `profile_id` + `profile_digest` + `profile_authority` + `profile_roles` +
  `profile_budgets`.

**One citation is imprecise and worth recording.** The report says *"Queued and recovery
paths call the durable runner directly (`worker.rb:509-541`)."* Read at the cited lines:
`claim_and_run` (`:509-520`) and `recover` (`:533-541`) call `session.app.durable_runner
.run_next` / `.recover`. **Neither call goes through `Session#start`/`#resume`/`#continue`**,
so `guard_state!` is never invoked on these paths — only `Session#recover` (`session.rb:330-337`)
calls `guard_state!`, and the worker does not use it. That makes the report's claim
*stronger* than stated, not weaker.

I also verified a **second** direct-runner path the report does not mention:
`run_queued_resume` (`worker.rb:327-331`) also calls `session.app.durable_runner.run_next`
directly. Same conclusion.

### Reachability chain

1. Operator writes a narrow trusted profile at `<runtime>/profiles/trusted.yaml`
   (`0600`, inside a `0700` runtime dir) — `RuntimeDirectory.create!`
   (`runtime_directory.rb:233-238`).
2. Operator enqueues work bound to it: `tamoz queue add --profile trusted …`, which calls
   `bind_thread_profile` (`worker_runtime.rb:126-140`, storing only the ID) and
   `enqueue_request`. Verified: the stored row is `{"profile"=>"trusted"}`.
3. Operator edits `profiles/trusted.yaml` — with a **supported command**
   (`tamoz profile import`, `cli_profile_commands.rb:229-247,277-295`), which writes the
   target and activates its digest. This is an ordinary operator action, not a hack.
4. Worker restarts, or a second worker process starts. `cmd_worker`
   (`cli_worker_commands.rb:273-283`) builds a **fresh** `WorkerRuntime` whose `@profiles`
   memo is empty.
5. The worker claims the queued thread. `poll_once` → `advance_pending_threads` →
   `advance_thread` (`worker.rb:263`) → `@session_builder.call(thread_id)` → the fresh
   `session_for` reads the **edited** file → `session_toolbox` derives a wider toolbox →
   `claim_and_run` (`worker.rb:509-520`) executes through the widened surface.

**No step requires a state the system cannot be in.** Every step is a supported operator
command plus a process restart. Nothing is test-only.

### Trust-model evidence

Honest reading — this is the one where the trust model partly *cuts the other way*:

- `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:107-123` is explicit and *intended*:
  *"The binding names a profile; the profile's CONTENT always comes from the runtime
  directory."* Read alone, that sentence **sanctions** the observed behavior: content
  comes from the current runtime directory by design.
- `worker_runtime.rb:20-27`: *"Everything here is operator authority."*
- `worker_runtime.rb:832-839`: the same file states the auto-adoption rationale —
  *"this file is inside a 0700 runtime directory that only the operator can write."*
- `docs/PROJECT_HANDOVER_PLAN.md:288-296` (P8-B), which the report cites: *"Bind profiles
  to session/checkpoint/cache epochs; changes create candidate transitions and never
  mutate **in-flight authority**."* This is the clause F25 violates.
- `docs/design-v0.1/AGENT_DESIGN.md:395-398`: *"An in-flight execution remains pinned to
  its checkpointed `behavior_version`. A later external turn may adopt the current
  promoted version only through an explicit `BehaviorTransition` at the turn boundary."*
  The mechanism is spelled out for **behavior versions**; the P8 plan extends the same
  shape to profiles.
- `gems/tamoz-agent-cli/lib/tamoz/agent/cli_authority.rb:16-20`: *"an existing one replays
  what it was pinned to, so editing a profile file cannot silently widen a session
  already in flight."* — the CLI asserts this as a system property. F25 shows it is only
  true on the CLI path.
- `SECURITY.md`: authority is "local, intersected, and content-addressed" — the worker's
  reload satisfies "local" and "content-addressed" for *each* version, but not
  "intersected with the pinned epoch".

**What this settles.** Unlike F21, F25 is a **contract inconsistency inside the codebase**,
not merely a violated top-level claim. Two seams resolve an existing thread's authority:
`CLIAuthority#resolve_session_authority` replays the pinned snapshot and refuses to widen
(`cli_authority.rb:132-146`), while `WorkerRuntime#session_for` reloads the current file.
The CLI's own comment claims the system-wide property; the worker contradicts it. That is
a genuine defect *regardless* of threat model, because it is a divergence between two
implementations of one stated contract.

**What it does not settle.** Who the attacker is. Step 3 is the operator's own action on
the operator's own `0600` file in the operator's own `0700` directory.

### Guards searched

```
grep -rn "session_for\b" gems/ test/          # 4 non-test: worker_runtime.rb:701,705;
                                              # cli_worker_commands.rb:277,279
grep -rn "guard_state!" gems/                 # session.rb:321,326,331,443;
                                              # session_context_controls.rb:149,249
grep -rn "verify_.*_binding!" gems/           # all six read
grep -rn "profile_digest" gems/ test/         # 51 hits, all read
```

Result — **the report missed one guard, and it is a meaningful miss:**

`WorkerRuntime#child_profile_for` (`worker_runtime.rb:1116-1123`) does exactly the check
F25 says is absent, for **child tasks**:

```ruby
resolved = load_profile(profile_id)
expected_digest = binding.fetch('profile_digest', nil)
return resolved if expected_digest && resolved.canonical_digest == expected_digest
raise ToolPolicyError, "child authority profile changed after enqueue"
```

`persist_child_authority_binding` (`:1087-1105`) writes `profile_digest` into the child
binding precisely so this comparison is possible. So the codebase **already has** the
guard pattern, applied to delegated child tasks, and simply does not apply it to the
top-level `THREAD_BINDINGS` row. The report's five-whys says *"tests covered the
interactive path and left restart as a process-lifetime assumption"* — the more accurate
root cause is that the digest guard was written for children and never lifted to threads.
This **strengthens** the finding's credibility (it is an inconsistency with in-repo
precedent, not a design choice) while making the report's root-cause chain slightly wrong.

Also confirmed: `Session#guard_state!` has **no** profile enforcement —
`session.rb:206-285` contains only graph, skill, MCP, egress, behavior. The report is
right that no session guard catches this. And because `claim_and_run`/`recover`/
`run_queued_resume` bypass `Session#start`/`#resume`/`#continue`, `guard_state!` is not on
the worker's path at all.

### Probe

Two probes, both under `/tmp/tamoz-challenge/f25/`:

**Part 1** — `probe.rb`, command `ruby /tmp/tamoz-challenge/f25/probe.rb`. Builds a real
runtime directory, writes a narrow `trusted.yaml` (`0600`) by hand, binds a thread,
enqueues a real request, rewrites the profile wider, then opens a **fresh**
`WorkerRuntime` and asks what session the queued thread gets. It reports only capability
surface facts (no model, no effect).

```
step1 narrow_profile_digest=sha256:4344901f2da07a1fc610d904894bca2dbe1c74bc48ed644ab259531cbd6aa91a
step2 stored_thread_binding={"profile"=>"trusted"}
step3 enqueued=OK
step4 pre_restart tools=["list_directory", "read_file", "search_text"] allow_changes=false digest=sha256:557071a5577d548d4c23529bd046be7d1a05f03c8d3bed1763a3c65ad9eef874
step5 edited_profile_digest=sha256:6a81d5ef1c9192769edcf58f430b5c2c3a1493601f97690d48a3d297a6ea1470
step6 post_restart tools=["list_directory", "read_file", "search_text", "apply_patch", "create_file"]
  allow_changes=true
  worker_sees_digest=sha256:902084f66b79fbab0574cfd704f51ebe9437f5ccd05390aa44b674d5b3db5f81
  digest_is_WIDENED=false
  digest_is_OLD_NARROW=false
  widened_tools_reached_queued_thread=true
```

`step2` is the crux: the stored binding is the ID and only the ID. `step6` is the
widening: `apply_patch` and `create_file` reached a thread bound before the edit.

(Note: `worker_sees_digest` differs from both file digests because `Profile#canonical_digest`
is the digest of the *loaded document*, while `step1`/`step5` print the toolbox
`catalog_digest`; `load_profile` also injects `unattended_catalog_digest`. The comparison
that matters is the tool surface, which changed.)

**Part 2** — `probe2.rb`, command `ruby /tmp/tamoz-challenge/f25/probe2.rb`. This is the
stronger result: it runs the **real `Worker#poll_once`** with a model factory that raises
before any provider is contacted, so it proves whether execution was *reached*, not what a
model said. **No real LLM is called.**

```
pre_restart_session_record_profile_digest=
narrow=sha256:4344901f2da07a1fc610d904894bca2dbe1c74bc48ed644ab259531cbd6aa91a
wide=sha256:6a81d5ef1c9192769edcf58f430b5c2c3a1493601f97690d48a3d297a6ea1470
event=request.claimed {"thread"=>"th", "request_id"=>"req-1"}
event=request.failed {"thread"=>"th", "request_id"=>"req-1", "duration_ms"=>824, "reason"=>"no_check", ...}
poll_once=returned
model_was_reached=true
post_restart_session_record_profile_digest=
post_restart_tool_catalog_digest=
```

**I reproduced the claimed behavior, and went further than the report**: the widened
thread was *claimed and executed*. `request.claimed` then a terminal failure at the model
step — with `model_was_reached=true` — means the runner got all the way to the model call
under the reloaded profile. The `request.failed`/`no_check` is my probe's raising factory
(the plan had no configured check to call), not a guard firing. **No guard stopped it.**

I also note honestly: the report claims the session record's `profile_digest` is
*overwritten* with the new value (`session_bindings.rb:51-61,155-172`). I could not
observe that, because the request failed before intake committed a record
(`pre_restart_session_record_profile_digest=` is empty). The overwrite claim is plausible
from the code — `session_record` writes `profile_binding` unconditionally — but **I did
not verify it**, and the report should mark that sub-claim as source-inferred rather than
probe-observed.

### Test evidence

`ruby -Itest test/agent_worker_test.rb` → **25 runs, 122 assertions, 0 failures, 0
errors, 0 skips**. Matches the report exactly.

**What this does not prove.** The suite covers unknown profile IDs and path safety
(`profile_path` traversal), and normal queue execution. It contains no
edit-then-restart case. I grepped the whole suite for `profile` + restart combinations
and found none. The gap is as described.

### Verdict + reason

**UPHELD — the defect is real and the severity stands.**

Why the challenge failed, in one sentence: **unlike F21, F25 is a divergence between two
seams that implement the same in-repo contract, and the repository already contains the
correct guard for the structurally identical case** — `child_profile_for`
(`worker_runtime.rb:1116-1123`) refuses a child whose profile digest drifted after
enqueue, while the top-level thread binding stores no digest at all and is never
compared. That is not "the operator is the trust root, so nothing is wrong"; it is the
same codebase applying a guard on one path and omitting it on another, with the CLI
(`cli_authority.rb:16-20`) explicitly asserting the property the worker violates. Plus
I demonstrated the widened session actually reaching the model.

I considered demoting on the same local-operator reasoning as F21 and rejected it: the
operator here acts through a **supported command** (`profile import`) and an ordinary
**process restart**, and the harm is that work already accepted under one authority
executes under another — which is precisely the "in-flight authority" clause
(`PROJECT_HANDOVER_PLAN.md:288-296`) in `critical` territory. The BAR's "authority bypass"
is met because the *session's own recorded boundary* is bypassed, not the operator's.

## CF05-SEC-01

### Source re-verified

- `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:665-684` (`build_toolbox` /
  `build_profile_toolbox`) — **exact**. The local toolbox derives `allowed_tools:
  profile.tools_allowed`.
- `cli.rb:579-598,621-635` (`run_durable` / `build_durable_session`) — **exact**. `mcp =
  build_mcp_source(options, profile:)` and both `toolbox:` and `mcp:` are passed to
  `Session.new`.
- `cli.rb:650-662` (`build_mcp_source`) — **exact**. It compares
  `directory.workspace_root` against `profile.canonical_root` and then returns
  `McpSourceBuilder.new(directory).build`. **The profile is consulted for the root only,
  never for admission.** Verified line by line.
- `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1030-1055,1195-1208` — **exact**.
  `build_session(profile_id, allowed_tools: nil, mcp: mcp_source, ...)` defaults `mcp` to
  the complete source while `session_toolbox` derives from the profile.
- `gems/tamoz-agent-session/lib/tamoz/agent/session_options.rb:129-175` — **exact**.
  `validate_mcp_source!` duck-types only; `verify_profile_binding!` checks
  `policy.tool_catalog_digest` and root. **No profile check on MCP admission.**
- `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:64-89` and
  `.../profile/authority_validator.rb:44-55` — **exact**. `tools.allowed` accepts only the
  six local names (`read_file list_directory search_text apply_patch create_file
  run_check`); `run_check` is only available when configured as a check. There is no
  source-qualified MCP field in the profile schema.
- `gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:161-169`
  (`admission_set`) — **exact**:

  ```ruby
  def admission_set
    @toolbox.allowed_tools +
      (@child_enabled ? [ChildTaskDispatcher::TOOL_NAME] : []) +
      (@mcp ? @mcp.names : [])
  end
  ```

  The comment above it reads: *"Invariant 35: the admission set is policy-derived,
  computed BEFORE the host exists. `Toolbox#allowed_tools` is the already-intersected
  profile surface; **the MCP ids are the caller's pinned catalog descriptors**, which
  `Session#verify_mcp_binding!` pins across resume."* The comment is candid: MCP ids are
  admitted from the caller's catalog, and the only pinning is a *snapshot* pin, not an
  authority intersection.
- `capability_binding.rb:301-305` (`build_host`) — **exact**.
- `session_nodes.rb:98` — where `CapabilityBinding.build(toolbox:, mcp:, ...)` is called.
  The report cites `session_effects.rb:337-352`; the actual `allowed_tool_names(phase)` is
  at `session_effects.rb:350-352`. **Slightly off but directionally right.**

One correction to the report: it cites `capability_binding.rb:201-205,362-368` for the
approval/effect-class behavior. `:201-205` is inside `grouped_mcp_descriptors` and
`:362-368` is `mcp_retry_policy`/`mcp_reconciliation_policy`. The substantive claim —
unknown-effect MCP tools become `:bounded` and approval-required — is at
`closed_effect_class` (`:207-211`) and `mcp_approval_policy` (`:361`). **The behavior is
as described; the line numbers are wrong.**

### Reachability chain

1. Operator writes a trusted profile whose `tools.allowed` is `["read_file"]`.
2. Operator writes `<runtime>/config.yaml` enabling an MCP server
   (`McpSourceBuilder`, `mcp_source_builder.rb:5-27`).
3. Operator starts a durable session with `--profile`, or a worker runs a thread bound to
   it. `run_durable` builds the profile toolbox (narrow) and `build_mcp_source` (all
   enabled servers), and passes both to `Session`.
4. `CapabilityBinding#admission_set` returns `["read_file"] + all_mcp_names`.
5. The MCP names are in the sealed registry, appear in `names(:discovery)` /
   `names(:action)`, are rendered into the planning prompt, and dispatch through the MCP
   dispatcher.

**This chain is fully reachable — but it is not an attack.** Steps 1–3 are all deliberate
operator configuration of the operator's own `0700` runtime directory. There is no
workspace-controlled path to it (`runtime_directory.rb:24-27`), and the report says so.

### Trust-model evidence

This is where the finding is weakest, and the report half-admits it. Both models are
documented **in the same checkout**:

*Independent runtime authority (favors downgrade):*
- `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:9-11,24-27`: *"The operator-owned
  runtime directory: one place a worker is pointed at, and **the only place its authority
  comes from**… Everything here is operator authority."*
- `capability_binding.rb:163-165`: MCP ids are *"the caller's pinned catalog descriptors"*.
- `docs/P10_MCP_PLAN.md:146-152`: *"`effect_class` from **local** policy (default
  `:unknown_effects` → approval required…)"* and *"List-change notifications, TTL expiry,
  reconnects, or config edits produce a candidate catalog; the in-flight epoch never
  changes."* P10 is the phase that shipped MCP and it frames MCP admission as
  configuration-driven.
- `test/support/autonomy_case.rb:269-297`: the harness writes the trusted profile with
  `tools.allowed` being exactly the local tools. It never mixes a restrictive profile with
  MCP.

*Profile as session-wide ceiling (favors the finding):*
- `docs/P18_CAPABILITY_HOST_PLAN.md:60-72`: MCP/websearch register *"if profiles admit"*,
  and the admission set is *"the already-intersected surface from `build_profile_toolbox`
  + `verify_profile_binding!`"*.
- `docs/design-v0.1/INVARIANTS.md:82-88` (clause 35): *"effective authority is the
  intersection of current application/agent/task/parent limits"*.
- `SECURITY.md`: *"A capability's effective authority is the intersection of the current
  profile, agent and task limits."* — the profile is named as an intersected input.
- `documentation/architecture/security-model.md`: the Mermaid diagram feeds `PROFILE` and
  `AGENT_LIMITS` and `TASK_LIMITS` into `INTERSECT`; MCP is one of the four sealed sources.

**What this settles — and it settles it against `major`.** The repository does not state
which authority wins for a profile-bound session with configured MCP. The report is honest
about this ("contract decision required"). But a finding whose *existence as a defect*
depends on which of two equally-documented readings the owner ratifies is **not a
`major` "material gap with real operational cost"** — a `major` finding needs an actual
material gap, and here the gap is between two documents, not between a document and the
code. P18 says "if profiles admit" but **never defines the data path** (the report says
this too, and I confirmed the profile schema at `profile.rb:64-89` has no such field).
A contract that cannot be implemented because it names no field is a documentation gap.

`SECURITY.md`'s intersection sentence is the strongest pro-finding evidence, and it is a
real inconsistency. But it is one sentence against `runtime_directory.rb`'s explicit and
repeated "the only place its authority comes from", plus P10's shipped framing. I cannot
call the code wrong on that split.

### Guards searched

```
grep -rn "admission_set" gems/                          # capability_binding.rb:161,304
grep -rn "build_mcp_source\|McpSourceBuilder" gems/     # cli.rb:650; worker_runtime uses @directory
grep -rn "mcp" gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb  # no MCP field at all
grep -rn "egress_policy_ref" gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb
```

Result: **there is no missed guard.** The profile schema genuinely has no MCP surface,
`session_options.rb` genuinely validates only the duck-type, and `admission_set` genuinely
appends every MCP name. The behavior is confirmed; only its *classification* is in
question.

I did verify one thing the report claims in passing and it holds: unknown-effect MCP tools
are **not** silently admitted as read-only. `closed_effect_class`
(`capability_binding.rb:207-211`) maps anything outside `%i[read_only bounded reconcilable]`
to `:bounded`, and `mcp_approval_policy` (`:361`) makes non-read-only approval-required.
So the model cannot use an unconfigured MCP tool without an approval — the exposure is
bounded by the approval engine, which the report correctly notes.

### Probe

Path: `/tmp/tamoz-challenge/cf05/probe.rb` (output `probe.out`). Command:
`ruby /tmp/tamoz-challenge/cf05/probe.rb`. Uses a real `Toolbox` restricted to
`["read_file"]`, a fake in-process MCP source implementing the documented duck-type, and
a non-nil `profile`. **No network, no subprocess, no real server.**

```
profile_local_allowlist=["read_file"]
model_surface=["read_file", "mcp:probe/set_answer"]
mcp_descriptor_visible=true
profile_intersection_present=true
mcp_dispatch=RAISED ArgumentError: wrong number of arguments (given 3, expected 2)
admission_set_includes_mcp=true
```

**I reproduced the claimed behavior.** A profile-restricted toolbox of one local tool
yields a model-visible surface of two names, with the MCP descriptor registered in the
sealed host. The `ArgumentError` on `execute` is my fake's own `execute` arity, not a
guard — the call **reached** the MCP dispatcher, which is the point being tested.

Caveat, matching the report's own blind spot: my probe also stops at the binding seam. It
does not run the full CLI with a YAML profile, does not start a real MCP server, and does
not call a provider.

### Test evidence

`ruby -Itest test/capability_host_test.rb` → **21 runs, 91 assertions, 0 failures, 0
errors, 0 skips** (`:403-416` proves a withheld *local* tool is absent; `:418-439` proves
MCP dispatch routing — both as cited).
`ruby -Itest test/agent_cli_mcp_test.rb` → **6 runs, 28 assertions, 0 failures, 0 errors,
0 skips** (all without `--profile`, as cited).
`ruby -Itest test/agent_worker_mcp_test.rb` → **11 runs, 35 assertions, 0 failures, 0
errors, 0 skips** (no restrictive profile, as cited).
`ruby -Itest test/agent_profile_test.rb` → **44 runs, 130 assertions, 0 failures, 0
errors, 0 skips** (local names only, as cited).

**What these do not prove.** No test combines a restrictive trusted profile with
configured MCP and asserts either absence or intentional independent admission. The
report's test-gap claim is accurate — I grepped the suite for that combination and found
none.

### Verdict + reason

**DEMOTED — real, confirmed behavior; I assign `info`/documentation gap, not `major`.**

The challenge succeeds because the finding's severity rests on an unresolved contract
question, and the BAR grades *behavior*, not ambiguity. Three reasons:

1. **The `major` definition is not met.** A `major` is a "material correctness, security,
   reliability, observability, scalability, dependency, or ownership gap with real
   operational cost." Here the behavior is deliberate, reachable only by the operator
   configuring both artifacts, matched by explicit contemporary documentation
   (`runtime_directory.rb:9-11,24-27`; `P10_MCP_PLAN.md:146-152`), and bounded by the
   approval engine for every non-read-only capability. There is no operational cost that
   is not also the documented design.
2. **The conflicting contract names no data path.** P18 says MCP registers "if profiles
   admit", but the profile schema (`profile.rb:64-89`, `authority_validator.rb:44-55`) has
   no field to admit it with. A requirement that cannot be expressed in the data is not an
   implemented contract that the code violates; it is an unfinished specification. The
   BAR's `info` band is *"a verified design fact, limitation, or question that is useful
   for later work but is not itself a defect"* — that is exactly this.
3. **The report's own conclusion agrees.** It says: *"If independent runtime authority is
   ratified, the code finding should be downgraded to an information/documentation
   gap."* My reading of `runtime_directory.rb` is that independent runtime authority **is**
   the ratified model — it is stated in the owning file, in the present tense, as the
   whole point of the directory. The one contrary sentence in `SECURITY.md` is a summary
   line that P18 did not implement.

The behavior is real and I confirmed it; I am not disputing the observation. I am
disputing that an undecided contract, with the owner's own code commenting the observed
behavior as intended, is a `major` defect. It should be recorded as an **`info` finding
plus a documentation correction** — fix `P18_CAPABILITY_HOST_PLAN.md:60-72` and reconcile
the `SECURITY.md` intersection sentence with `runtime_directory.rb`, and add the
combined-path regression either way.

## Net effect on FINDINGS.md

- **F21-SEC-01**: change severity to **major** (integrity-hygiene / misleading-evidence
  gap; the same-uid writer is already the trust root, so no unsafe action or authority
  bypass is reachable). Keep open and confirmed; keep the recommendation.
- **F25-SEC-01**: **keep** as `critical`, open, confirmed. Strengthen the root cause to
  cite the missing generalization of `child_profile_for` (`worker_runtime.rb:1116-1123`),
  and mark the "session record digest is overwritten" sub-claim as source-inferred, not
  probe-observed.
- **CF05-SEC-01**: change to **info / documentation gap** (not `major`), and resolve the
  contract toward independent runtime authority — correct `P18_CAPABILITY_HOST_PLAN.md:60-72`
  and reconcile `SECURITY.md`'s intersection sentence with `runtime_directory.rb:9-11,24-27`.
  Keep the combined-path regression recommendation regardless of which contract is chosen.
