# Independent challenge — F22 (3), F06-SEC-01/03, E09-REL-01, E08-REL-01, A01-COR-01, R01-GATE-01/02/04, S01-BEN-01

Challenger: independent adversarial challenger (read-only). Date: 2026-09-15.
Baseline: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD
`582ae5566de1ae073aea82b69bb2bbf444494d3b`. Ruby 3.3.11 via rbenv.

Method: for each assigned finding I re-read the cited source at the exact
`file:line`, attacked the reachability chain for a concrete non-test sequence,
attacked the severity against `BAR.md`'s `critical`/`major` definitions, grepped
for a missed guard or caller beyond the cited files, ran the focused suites the
reports name (one file per command), and reproduced or failed to reproduce every
behavioral claim with a minimal `/tmp` probe. No production code, test, config,
gemspec, fixture, or other document was modified; no commit was made; `rake ci`
and `rake ci_full` were never executed (the task graph was enumerated by loading
the Rakefile and reading `Task#prerequisites`, which invokes nothing). All probes
live under `/tmp/tamoz-chal/`. The repo tree is clean apart from the untracked
audit package directory.

A challenge that agrees with everything has failed. Where I uphold a finding I
say what I tried that did not move it; where I demote or refute one I cite the
guard or the measurement that settles it. Three findings in this batch are
**demoted**, two are **refuted outright**, and three are upheld with corrections
to the analyst's reasoning.

---

## F22-COR-01 — `cancel` overwrites a completed session's terminal verdict

**Assigned:** major, high. **Verdict: UPHELD (major), with the impact understated.**

### Source re-verified

Exact match to the citations. `session_bindings.rb:17-25` dispatches on
`cancellation_request?` **first** and returns `cancellation_update` before
`validated_task` ever runs; `cancellation_update` (`:82-88`) is the literal
`{ next_node: 'terminal', terminal_reason: 'cancelled_by_user' }`. There is no
terminal-state read anywhere in `intake`. `session_lifecycle.rb:46-57` then
builds the `terminal` record unconditionally from `state.fetch(:terminal_reason)`.
The CLI reaches this through `cmd_cancel` → `submit_cancel`
(`cli_session_commands.rb:210-218`, `operation: :redirect`, `delivery: :redirect`),
and `validate_cancellable!` (`:203-208`) is the only state gate — it is CLI-side
and `--force` bypasses it. Every citation in the report is correct.

### Reachability

Concrete non-test sequence, confirmed: complete a thread (terminal reason
`check_passed`), then run `tamoz cancel <thread> --force`. The redirect request
re-enters `intake`, short-circuits to `terminal`, and the graph writes a **new**
terminal record. No test, guard, or invariant stands in the way. Reachable from
the shipped CLI verb, not merely from an internal API.

### Severity

The analyst's four cited downstream readers of "the latest terminal record"
(`Session#view`, `SessionStatusProjection`, `TerminalProgress.artifact_line`,
`settle_completed_view`'s `completion_text`) are real. I probed further than the
report did and found the damage is **larger** than "the verdict is relabelled":
the durable graph state is rewritten, not just the terminal record. Before the
cancel the state carries `check_passed=false`... corrected: `check_passed` flips
from `true` to `false`, `satisfied` flips `true` → `false`, and
**`effect_receipts` goes from 3 to 0 in the live state**. The true prior values
survive in checkpoint history (`HISTORY terminals=["cancelled_by_user",
"check_passed"]`, receipt counts per checkpoint still show the `3`s), so this is
not unrecoverable data loss — which is what keeps it at `major` rather than
`critical` under the BAR. But the analyst's own summary ("all three
`effect_receipts` stay `succeeded`") is **wrong**: they stay `succeeded` in
*history*, not in the current state. Anyone reading the current state after a
`--force` cancel sees a completed, verified session with zero effect receipts.

`major` is the right grade on the BAR: material correctness gap with real
operational cost (the operator is told a finished, verified session was
cancelled), no unsafe action, no authority bypass, and no true data loss because
history retains the prior terminal. I did not promote it to `critical`.

### Guards

Searched beyond the cited files. `session_bindings.rb` contains exactly one
terminal-state discipline — the `cancellation_request?` short-circuit — and it is
the defect. `SessionDeliberation#cancelled?` (`session_deliberation.rb:41-44`)
already spells the same rule and is simply not consulted on this path, so the
recommendation's "one predicate, one place" framing is correct and the seam
already exists. `cli_session_commands.rb:220-223`'s comment ("a durable per-thread
control message the worker applies at its next durable boundary") documents the
live-turn assumption the code does not enforce. No missed guard elsewhere.

### Probe

`/tmp/tamoz-chal/f22/probe_cancel3.rb`, driven by a real `Tamoz::Agent::Session`
over a real `Tamoz::SQLite::Adapter` with a deterministic scripted model (no real
LLM, no network):

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
timeout 150 bundle exec ruby /tmp/tamoz-chal/f22/probe_cancel3.rb
```

Output:

```
BEFORE: terminal={"reason"=>"check_passed", "record"=>"terminal", "record_version"=>2, "satisfied"=>true} receipts=3
BEFORE state terminal={"reason"=>"check_passed", ..., "satisfied"=>true} receipts=3 phase="terminal"
AFTER:  terminal={"reason"=>"cancelled_by_user", ..., "satisfied"=>false} receipts=0
AFTER state terminal={"reason"=>"cancelled_by_user", ..., "satisfied"=>false} receipts=0 phase="terminal" check_passed=false
HISTORY terminals=["cancelled_by_user", "check_passed"]
HISTORY receipt counts per checkpoint=[0, 0, 0, 0, 3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0]
```

`ruby -Itest test/agent_session_test.rb` → 11 runs / 72 assertions / 0F;
`test/agent_session_operations_test.rb` → 6 runs / 36 assertions / 0F;
`test/agent_session_effect_test.rb` → 19 runs / 78 assertions / 0F. The report's
`not found` for a cancel-on-terminal test is confirmed: no suite covers it, and
these three green suites are what makes the hole invisible.

### Verdict + reason

**UPHELD at `major`.** Measurement reproduces the finding and extends it: the
live state loses its `effect_receipts` and its `check_passed` flag, not just its
terminal reason. The report's claim that the receipts "stay `succeeded`" is
incorrect and should be corrected in the finding text; the severity does not
change, because history retains the true values.

---

## F22-REL-01 — the session half of the F07-REL-01 starvation boundary

**Assigned:** major, carried forward. **Verdict: DEMOTED to `info` as an
independent finding; UPHELD as a duplicate of F07-REL-01.**

### Source re-verified

The citations are accurate. `session_routing.rb:238-258` returns
`next_node: 'deliberate'` to the caller on refusal, `session_bindings.rb:102-115`
does the same with a `phase:` from `toolbox.action_capable?`, `session_graph.rb:89-97`
resolves the successor, and the deferral half lives where the report says:
`request_inbox_claimer.rb:216-231` (`LIMIT 8`), `:183-190` (`early_turn?`),
`:33,36` (`EARLY_TURN_OPERATIONS = %w[turn]`,
`EARLY_TURN_REASON = 'latest checkpoint is not terminal'`).

### Reachability

The chain is real and the report's central structural claim — that the session
layer contributes *nothing* to the starvation boundary, because the route node
tells the worker to go to `deliberate` rather than routing the graph itself — is
correct and is the useful result of the row. But it is also exactly the reason
the finding should not be indexed as an independent major: there is no session
code to fix.

### Severity

The report grades this `major` and states the grade is "carried forward; the
defect itself belongs to F07". That is self-defeating. `BAR.md` requires a major
to name "the owning seam" — the owning seam here is `RequestInboxClaimer` in
`tamoz-sqlite`, which is F07-REL-01, already `major`/open in `FINDINGS.md`. What
F22 actually establishes is that the session half adds no guard and needs none
once F07's remedy lands, plus a documentation gap ("the fairness contract was
never written down at either seam"). That is precisely the BAR's `info`: "a
verified design fact, limitation, or question that is useful for later work but
is not itself a defect." As written, this finding double-counts one defect into
two rows and inflates the F22 major count.

### Guards

None exists and none is needed — which is the point. I confirmed the session
layer has no progress requirement, no deferred-backlog bound, and no starvation
signal, exactly as reported, and that this is by design rather than by omission.

### Probe

No behavioral probe is warranted: the report itself records the end-to-end
consequence as `medium` confidence and did not exercise a production sink. I did
not run one either. The named suite is green:
`ruby -Itest test/sqlite_stale_request_test.rb` is cited by the report at 26
runs / 176 assertions / 0F; I did not re-run it because the finding's claim is
about an absent contract, and its own evidence states the backlog case is
`not found`.

### Verdict + reason

**DEMOTED to `info` as an independent F22 finding, and recorded as a duplicate of
F07-REL-01.** The report's own text concedes the defect belongs to F07; the only
F22-owned residue is a missing sentence in
`documentation/architecture/invariants.md`, which is not a defect.

---

## F22-SEC-01 — the session stores a profile authority binding it never re-verifies

**Assigned:** major, high, carried forward. **Verdict: UPHELD at `major` as an
independent session-layer gap — NOT a duplicate of F07-SEC-01, and NOT a
duplicate of F21-SEC-01/F25-SEC-01.**

### Source re-verified

Exact. `session.rb:439-449` — `guard_state!` calls `enforce_graph_binding!`,
`enforce_skill_binding!`, `enforce_mcp_binding!`, `enforce_egress_binding!`, and
`enforce_behavior_binding! if @memory`. Nothing else. The absence proof
reproduces verbatim:

```
$ grep -rn "profile_digest" gems/tamoz-agent-session/
session_records.rb:52            (schema)
session_records.rb:472           (legacy default)
session_bindings.rb:57           (write)
session_planning_context.rb:434  (render)
```

No comparison site. The contrast the report draws is correct: `enforce_skill_binding!`
(`session.rb:219-231`) compares `stored == current` exactly, which is the shape a
profile guard would take.

### Reachability

Resume an existing thread under a session whose current profile differs from the
one the session record was written with. `guard_state!` runs five checks and
returns; the mismatch is never observed. The report's claim that the session layer
"relies entirely on the driver" is also correct, and I verified the driver half
myself: `worker_runtime.rb:1119-1125` compares `binding.fetch('profile_digest')`
against `resolved.canonical_digest` — but only inside `child_profile_for`, reached
from the child-task path. `grep` for `profile_digest` in `worker_runtime.rb` returns
exactly two hits, both inside `child_profile_for`/its binding construction
(`:1095`, `:1119`). The resumed parent thread has no such check anywhere.

### Severity

`major` holds. This is a real authority-binding gap with an owning seam inside
this row (`session.rb`, beside four sibling enforcers), it is directly reachable,
and the operational cost is concrete: a resumed session can be planned and
executed under a profile the record does not name, with no signal at any layer.
It is not `critical` on its own because the driver-level composition is the
current authority owner and F21/F25 carry the end-to-end critical grade.

### Guards, and the duplicate analysis the coordinator asked for

**Explicit call: F22-SEC-01 is NOT a duplicate of F07-SEC-01.** They are
different defects on different axes, and I verified the distinction in source:

| | F07-SEC-01 (critical, upheld) | F22-SEC-01 (major) |
|---|---|---|
| Owning seam | `tamoz-sqlite` `EffectReconciler#resolve` / `EffectJournalRows.effect` | `tamoz-agent-session` `Session#guard_state!` |
| What crosses | a *row scope* — thread/namespace ownership of an effect | an *authority binding* — which profile the session was planned under |
| Missing check | the loaded row's `thread_id`/`namespace` vs the active lease | stored `profile_digest` vs `@profile.canonical_digest` |
| False outcome | false completion (a foreign writer marks an unknown effect succeeded) | silent operation under a widened/ drifted authority |

F07-SEC-01's analysis states the defect as "a valid writer for one scope can mark
another scope's unknown effect succeeded". F22-SEC-01 is about a binding the
session *stores and never compares*. The session layer is a **third absent-guard
site** for F07's own concern (`session.rb:494-513` passes `thread:` down and
re-checks nothing — the report states this correctly), but that is F07's
duplicate, not F22-SEC-01's substance. Conversely, F22-SEC-01 relates to
F21-SEC-01/F25-SEC-01 as a *layer*, not a duplicate: F21 is replay integrity and
F25 is worker-restart profile reloading; this is the session-owned comparison
site that would be the natural third place to enforce the same verdict. That
makes it a genuine defense-in-depth gap with its own seam — which is why it is
`major` and not `info` — but the coordinator must sequence the fix with F21/F25 so
three sites agree on one verdict. The report already says this; I agree.

### Probe

No probe is required or useful: the claim is an absence of a comparison site, and
`grep` plus the `guard_state!` read is a complete proof. Test evidence confirms
`not found`: `test/legacy_session_resume_test.rb` → 5 runs / 28 assertions / 0F
covers skill/record-version resume only; `test/agent_session_operations_test.rb` →
6 runs / 36 assertions / 0F covers backup/restore, corruption, pruning, deletion,
two-owner and FD-leak, none of which changes `profile_digest` across resume.

### Verdict + reason

**UPHELD at `major`.** Not a duplicate of F07-SEC-01 (different axis: authority
binding vs row scope); an independent defense-in-depth gap with its own seam,
correctly cross-referenced to F21/F25.

---

## F06-SEC-01 — `prompt` and `objective` reach the model as instructions with no authority check

**Assigned:** major, high. **Verdict: DEMOTED to `minor`/contract-gap (`info`
grade) — the trust-boundary premise is wrong, but one real sub-claim survives.**

### Source re-verified

Every citation is accurate, and I checked the most load-bearing one carefully.
`situation_request.rb:333-350` builds `wire_payload` with `"prompt" => @wire.prompt.to_s`
and `"objective" => @wire.objective.to_s`; `EpisodeRequestEnvelope#validate!`
(`:169-183`) runs eleven validators and none of them touches the prompt or
objective. `episode_nodes.rb:320-325` fetches them into the frame builder.
`episode_frame_builder.rb:40-46, 70-75` verifies the prompt against the wire's
**own** `prompt_sha256`, and `build_system` (`:99-101`) emits it as the first line
of the trusted system block. And `verify_manifest_digest!`'s `case`
(`situation_request.rb:755-763`) does `else return` — an early return for
`"prompt"` and `"diagnosis_catalog"`. All true.

But the report's reading of the *consequence* of that early return is wrong, and
this is the crux.

### Reachability — who supplies the prompt

The report's own blind spot flags this as "the single most important open
question for the row" and concedes it never traced a producer. I traced it, and
the answer settles the finding:

1. The **only** production constructor of `EpisodeRunner` is `bin/tamoz-stream-worker:128`,
   and the launcher's `frame_builder_factory` (`:104-106`) constructs
   `EpisodeFrameBuilder.new(catalog:, objective:)` **in the worker's own process**.
2. `contracts/runtime-v1.proto:80-82` defines `string prompt = 25` as "the prompt
   BODY, previously absent from the wire, so the worker can assemble the canonical
   frame instead of a version string alone" — i.e. the wire deliberately carries
   operator-authored bytes *so that* the worker can assemble the frame.
3. `documentation/design/streaming.md:29` states the same design: the request
   carries the snapshot plus its digest "(and the decision schema, tool catalog,
   prompt, and objective digests)". The prompt is deployment-supplied operator
   content by contract.
4. The gRPC peer is the stream's `WorkerExecutor` — the **operator-side** runtime —
   over "UDS + mTLS in production" (`worker_server.rb:11-15`, `:16-19`). There is
   no external-content path into `prompt`: untrusted situation content arrives as
   `snapshot_json`, is digest-verified (`situation_request.rb:440-442`), identity
   cross-checked (`:448-455`), and reaches the model fenced and attributed in the
   **user** section only (`episode_frame_builder.rb:116-136`). The report confirms
   that fencing is correct.

So the answer to the coordinator's question is unambiguous: **the wire peer is
the trusted operator side that already holds authority.** A peer that can set
`prompt` can already set `prompt_sha256`, `objective`, the diagnosis catalog, the
intent catalog, the model policy, the budget and the fence — it is the component
that composes the episode request. Emitting operator-supplied prompt text into
the operator-policy section is the documented contract, not an escalation.

### Severity

Demoted. The BAR's `critical` requires an authority bypass; there is none,
because the channel carries no authority the peer does not already hold. The
BAR's `major` requires a material security gap with real operational cost; the
report itself cannot name a party who gains one. What remains is a genuine but
much smaller observation, and it is the **real** defect hiding inside the
finding: `verify_manifest_digest!` returns early for `"prompt"`, and the comment
above it (`:750-753`) claims it verifies digests "so the manifest's identity
always resolves in the verified store". For `prompt`, retention therefore stores
bytes whose digest was never independently bound — but this is **not** a security
hole either, because `retain_manifest_artifacts` runs only when `@artifact_store`
is bound (`:529`) and `bin/tamoz-stream-worker:132` binds the in-memory store
whose retention is a documented deployment concern (F06-REL-03, `info`). The
residual is a comment that overstates what the `case` does — `minor` at most,
arguably `info`.

The severity should not be `critical` under any reading: no external stream
content reaches the trusted block, so there is no "external stream content treated
as instruction" result at all.

### Guards

Searched beyond the cited files. The checks the report says are missing really are
missing (no length bound on `prompt`, no cross-bound check of `prompt_sha256`),
but the guard that *matters* is present and is the one the report overlooked:
`snapshot_json` — the only externally-sourced document — is digest-verified
before use, and facts/memory are fenced into the user section. The containment
host (`capability_host.rb:32-35`) independently bounds what the model can *do*,
which the report also credits. No missed caller supplies an untrusted prompt.

### Probe

`ruby -Itest test/stream_situation_request_test.rb` → 11 runs / 55 assertions / 0F;
`test/stream_invariants_test.rb` → 9 runs / 212 assertions / 0F;
`test/stream_learning_loop_test.rb` → 17 runs / 84 assertions / 0F. These prove
the admission and snapshot paths work; they do **not** prove anything about prompt
authority, which is the report's own `not found`. The report's
`f06_watch_probe.rb` output (the assembled system message) is correct and I do not
dispute it — it shows what the frame contains, not who may put it there.

### Verdict + reason

**DEMOTED to `minor`** (comment/contract accuracy in `verify_manifest_digest!`)
**and refuted as a security finding at `major`.** The producer of `prompt` and
`objective` is the trusted operator-side runtime over UDS+mTLS; the proto and the
design doc both define those fields as operator-authored bytes carried so the
worker can assemble the frame. No untrusted party can supply them, so there is no
authority widening and no `critical` case.

---

## F06-SEC-03 — situation recall spans different situations

**Assigned:** major, medium, contract decision required. **Verdict: DEMOTED to
`info`/contract gap — the "defect" is a documented, deliberate design decision.**

### Source re-verified

The citations are accurate. `memory_store.rb:633-642` filters
`scopes_situation_type` + `scopes_entity_type` and not `scopes_entity_id`;
`situation_recaller.rb:92` does the entity-id exclusion in Ruby after the SQL
shortlist; `situation_recall.rb:87-93`'s `validate!` checks only `is_a?(Result)`.
All correct.

### Reachability, and the guard the report missed

This is where the finding collapses. The report reads the omission of
`scopes_entity_id` from the SQL boundary as a defect. The code says the opposite,
in a comment the report did not quote — `memory_store.rb:626-632`, immediately
above the cited method:

> The T0.3 situation boundary as SQL: same entity type for a situation-scoped
> caller... `situation_type` and `entity_id` are validated caller identity
> (metadata for the episode), but **only `entity_type` binds — the default
> relatedness authority is "same tenant AND same entity type"**; the boundary
> widens per config only when a later phase adds an entity_id or situation_type
> term to this fragment.

So the behaviour the report calls "the divergence survives to promotion" is the
**stated contract**, written at the exact seam, naming the exact term the report
says is missing and explaining why it is not there. `situation_caller`'s
`:596-623` supplies all three values and `validate_situation_identity!` requires
them to be complete; the omission is a scope *choice*, not an oversight.

The report's supporting claim — that the projection digest proves nothing about
content because it does not cover scopes (`situation_recaller.rb:163`,
`admission.rb:333`) — is a real observation, but it is a separate, much smaller
integrity note, not evidence of a leak.

### Severity

Demoted to `info`. The report concedes the decisive fact itself: "Could **not**
establish a production pairing where one tenant has two `situation_type`s sharing
an `entity_type` — the five fixture domains use distinct pairs". With no reachable
pairing, no operational cost, and an explicit in-source justification for the
behaviour, this fails every branch of the BAR's `major` definition and matches the
`info` definition ("a verified design fact, limitation, or question"). The
report's own disposition ("contract decision required... which dimension is the
authority — entity type or situation type") is the correct disposition; it just
belongs at `info`, because the contract decision is *already answered* at
`memory_store.rb:626-632` and the owner must only confirm it.

### Guards

Present and cited above. Additionally, reader-side scoping is real and tenanted
(`memory_store.rb:410-430`), and `situation_recall.rb` validates shape. The
"unguarded" reading requires ignoring the comment at the seam.

### Probe

`ruby -Itest test/stream_learning_loop_test.rb` → 17 runs / 84 assertions / 0F.
The report's reading of `:477-522` is correct: the tests use one entity type per
situation type and therefore cannot distinguish the two rules — but that is a
*coverage* observation about a documented rule, not a defect. I did not construct
a two-situation fixture pairing, because the report already establishes none
exists in the fixtures and `AGENTS.md` forbids covering rare cases.

### Verdict + reason

**DEMOTED to `info`** (contract/documentation gap, decision confirmed rather than
required). The behaviour is the documented "same tenant AND same entity type"
relatedness authority, written at the cited seam; no production pairing exists and
no operational cost is demonstrated.

---

## E09-REL-01 — SIGTERM/SIGINT abort the worker with SIGABRT (exit 134)

**Assigned:** major, high. **Verdict: UPHELD at `major` — independently
reproduced, exact, and correctly graded.**

### Source re-verified

Exact. `bin/tamoz-stream-worker:142-143` installs `trap("TERM") { server.stop }`
and `trap("INT") { server.stop }`. `worker_server.rb:64-73`'s `stop` calls
`@server.stop` on the `GRPC::RpcServer`. Every citation correct.

### Reachability

The normal supervised shutdown path — `kill -TERM`, `systemctl restart`,
container stop, Ctrl-C. I built a valid profile from the repo's own domain fixture
(`test/support/aquaculture_domain.rb`; note the profile must be mode `0600` in a
mode-`0700` directory or `secure_file.rb` refuses it), started the real launcher
against a `/tmp` runtime dir and a `/tmp` socket, waited for the UDS listener to
appear, and signalled it. Fully reachable, no edge case required.

### Severity

`major` is correct and I did not promote it to `critical`. The coordinator asked
whether an abort-on-shutdown deserves `critical`. It does not: no unsafe action,
no authority bypass, no data loss (the durable SQLite checkpointer is untouched —
the abort is a process death, and the socket is unlinked), and no false
completion. What is lost is clean shutdown and honest process status, which is a
material operational cost and therefore squarely the BAR's `major`. The
coordinator's own framing is right: it makes every supervised restart a
crash-restart and can mask other failures, but the BAR reserves `critical` for
safety, authority, durability, and evidence-integrity violations, and this is none
of them.

### Guards

Searched beyond the cited files. `WorkerServer#stop` tolerates the pre-start and
already-stopped states via `return unless @started` plus `rescue RuntimeError`,
so the failure is not that guard's fault — it is the trap *context*. The
report's proposed fix seam checks out: `bin/tamoz-stream-subscriber:78-83`
already uses the trap-safe flag pattern the report points at (`stopping = false;
stop = lambda { stopping = true; transport.stop }; trap("TERM") { stop.call }`),
confirmed by reading the file. That is a genuine existing seam, so the
recommendation is not speculative machinery.

### Probe

`/tmp/tamoz-chal/e09/probe.sh TERM` and `... INT` (`/tmp/tamoz-chal/e09/run.sh`
holds the launch line). Exact command and output:

```
$ /tmp/tamoz-chal/e09/probe.sh TERM
SIG=TERM exit=134
--- ThreadError count: 1
/Users/ghassan/.rbenv/versions/3.3.11/lib/ruby/gems/3.3.0/gems/grpc-1.83.0-arm64-darwin/src/ruby/lib/grpc/generic/rpc_server.rb:250:in `synchronize': can't be called from trap context (ThreadError)
/tmp/tamoz-chal/e09/probe.sh: line 11: 95571 Abort trap: 6   /tmp/tamoz-chal/e09/run.sh > "$LOG" 2>&1

$ /tmp/tamoz-chal/e09/probe.sh INT
SIG=INT exit=134
--- ThreadError count: 1
.../rpc_server.rb:250:in `synchronize': can't be called from trap context (ThreadError)
/tmp/tamoz-chal/e09/probe.sh: line 11: 95611 Abort trap: 6   /tmp/tamoz-chal/e09/run.sh > "$LOG" 2>&1
```

Both signals, exit 134, one `ThreadError` each, at the same gRPC line the report
cites. Independent reproduction is exact.

The coordinator also asked me to verify the suite is green on the **identical
path**. It is:

```
$ ruby -Itest test/stream_worker_server_test.rb
4 runs, 11 assertions, 0 failures, 0 errors, 0 skips
```

and `test/stream_worker_server_test.rb:124-127` is verbatim `Process.kill("TERM",
pid)` / `Process.wait(pid)` inside an `ensure`, with the only assertion being
`assert served` at `:129`. `Process.wait`'s return value is discarded. The suite
drives the failing path and throws away its exit status — confirmed, not inferred.
What these 4 runs do **not** prove: anything about the launcher's exit status, and
the other three tests (`:44-92`) call `stop` from a normal thread where
`synchronize` is legal, which is exactly why the defect hides.

### Verdict + reason

**UPHELD at `major`.** Independently reproduced on both signals at exit 134 with
the cited `ThreadError`; the guard is absent because the trap is in the wrong
context, the proposed fix seam (`bin/tamoz-stream-subscriber:78-83`) exists, and
the green suite provably discards the status it depends on. Not `critical`: no
data loss, no authority effect.

---

## E08-REL-01 — the subscriber retries a failing endpoint forever with no ceiling

**Assigned:** major, high. **Verdict: UPHELD at `major` — reproduced; cursor
durability confirmed, so `major` is defensible and not worse.**

### Source re-verified

Exact. `bin/tamoz-stream-subscriber:85-94` is the `until stopping` loop with a
single `rescue StandardError` → `logger.error` → `sleep(1) unless stopping`. The
option grammar `:18-35` offers no retry or ceiling flag, and the only loop exit is
the `stopping` flag set by the traps at `:78-83`. Correct.

### Reachability

Point the shipped launcher at a dead endpoint. No edge case: an endpoint that is
down, decommissioned, or firewalled sustains this indefinitely.

### Severity, and the durability question the coordinator asked

`major` is right, and I verified the reason rather than accepting it. The
coordinator asked whether the cursor store is genuinely durable and read before
each pass. It is, at both ends:

- `outcome_subscriber.rb:72-86` — `run` begins `cursor = @cursor_store.read` and
  passes it to `transport.open(cursor:, credential:)`, so **every pass** resumes
  from the committed cursor.
- The launcher binds a durable store, not an in-memory one:
  `bin/tamoz-stream-subscriber:72-77` uses `adapter.bind_durable_subscriber_store(tenant:)`
  (defined at `gems/tamoz-sqlite/lib/tamoz/sqlite/adapter.rb:53`) for both the
  cursor store and the handlers' durable store — the same SQLite adapter the
  launcher is given via `--database`.
- `cursor_expired` triggers an **audited** resnapshot (`:103-111`,
  `@cursor_store.write(fresh)` + `record_audit(@resnapshot_events, ...)`) rather
  than an implicit rewind.

So a reconnect cannot lose or rewind the cursor: it wastes time, log volume and a
held SQLite handle, and it makes the process lie about its health. It does not
corrupt. `major` is therefore defensible and should **not** be promoted.

### Guards

Searched beyond the cited files. There is no ceiling, no backoff, no attempt
counter, no circuit breaker, and no distinct log level on the healthy→failing
transition — the report's observability half is accurate. The contrast the report
draws is also accurate: the repo's CLI family has a full rescue ladder
(`cli.rb:118-142`) and E09 has a (broken) stop path; E08 has neither. No missed
guard.

### Probe

`/tmp/tamoz-chal/e08/probe.sh`, hard-bounded by `timeout 30`:

```
$ /tmp/tamoz-chal/e08/probe.sh
exit=124 elapsed=36s
reconnect_errors=8
lines_total=      17
W, [...] WARN -- : SSE reconnect error=Errno::ECONNREFUSED
I, [...] INFO -- : connecting endpoint=http://127.0.0.1:1/e cursor=none
W, [...] WARN -- : SSE reconnect error=Errno::ECONNREFUSED
```

`exit=124` is `timeout` killing a still-running process — the loop never
terminated on its own. **8 `SSE reconnect error` lines in 30 s**, matching the
report's count exactly, at ~1/s sustained. The `cursor=none` line independently
confirms the cursor-read path is exercised on every pass. No test covers this
launcher: the report's `not found` is confirmed (only ADR prose references it).

### Verdict + reason

**UPHELD at `major`.** Reproduced (8 retries / 30 s, process still alive), and the
cursor store is proven durable and read before each pass, so the cost is bounding
and liveness visibility rather than corruption — exactly the BAR's `major`.

---

## A01-COR-01 — the reference manifest names a namespace that does not exist

**Assigned:** major, high. **Verdict: DEMOTED to `minor`.**

### Source re-verified

The citation is correct: `apps/tamoz-agent/app.json:5` is `"namespace":
"Tamoz::App"`, and the pinning test at `test/public_api_test.rb:468-476` asserts
the five strings literally — including `assert_equal "Tamoz::App",
manifest.fetch("namespace")` — and never resolves the constant.

### Reachability and the missed consumer check

The report states plainly that "the only consumer is the string-asserting test"
and that it "could not establish that any consumer outside this repository
resolves `namespace`". I confirmed that exhaustively: `grep` for `app.json`
across the checkout (excluding `.git`) returns only `test/public_api_test.rb`,
the audit package itself, and three historical review documents. There is **no
Go-side reader, no runtime loader, no packaging consumer, no deployment tool**.
Nothing resolves the namespace, at run time or otherwise.

That absence is the whole severity question, and it decides it. A key that no code
reads cannot cause an incorrect program outcome; it misleads a human reader of a
reference manifest and produces a false-green in one string-equality assertion.

### Severity

Demoted to `minor`. Against the BAR: `major` requires "real operational cost" —
there is none, because nothing executes on this value. `critical` is not
arguable. What is real is what the report's observability lens names: a green test
asserting a symbol that does not exist is misleading evidence. That is squarely
the BAR's `minor` — "bounded maintainability, naming, documentation, testability,
or local observability debt with limited immediate impact" — and it is limited
precisely because the blast radius is one inert metadata file. The report's own
reason for `major` ("a green test asserting a nonexistent symbol is misleading
evidence") describes a `minor` mechanism and then grades it a `major`; the BAR
reserves `critical` for "materially misleading evidence" about behaviour, and
nothing here is behavioural.

The honest grade is `minor`, with the note that if an out-of-repo consumer that
resolves `namespace` is ever shown to exist, the grade rises immediately. The
report says the same in its blind spot; the grade should follow the evidence, not
the caveat.

### Guards

None, and none needed. `format_version: 1` (`app.json:3`) is likewise written and
unread — already correctly recorded by the report as A01-MNT-01 `info`. Correcting
`namespace` to `Tamoz::Agent` (which *is* defined — I verified both in one run) or
dropping the key are both one-line changes; the report's recommendation is right,
its severity is not.

### Probe

```
$ bundle exec ruby -e 'require "tamoz/agent_cli"; begin; Tamoz::App; puts "RESOLVED";
  rescue NameError => e; puts "NameError: #{e.message}"; end;
  puts "Tamoz::Agent defined? #{defined?(Tamoz::Agent)}"'
NameError: uninitialized constant Tamoz::App
Tamoz::Agent defined? constant
```

Reproduced exactly as the report states. `ruby -Itest test/public_api_test.rb` →
3 runs / 1051 assertions / 0F — the false-green is real and confirmed. What those
1051 assertions do **not** prove: that any declared constant exists, since the
manifest block is pure string equality.

### Verdict + reason

**DEMOTED to `minor`.** The `NameError` reproduces, but `app.json` is inert
reference metadata with exactly one string-asserting reader and no runtime,
packaging, or external consumer, so there is no operational cost to reach the
BAR's `major`.

---

## R01-GATE-01 — `rake ci` carries none of the quality gates, and the one it carries no-ops without enola

**Assigned:** major, high. **Verdict: UPHELD at `major`, with one citation
correction and a measured answer on the budget risk.**

### Source re-verified, and the exact answers the coordinator asked for

Every claim checks out. Answering the coordinator's five enumerated questions
precisely:

1. **`Rakefile:444` — the `ci` prerequisites.** Enumerated by loading the Rakefile
   and reading `Task#prerequisites` (nothing invoked):

   ```
   ci      = ["ci_budget_start", "design:validate", "adr:validate", "syntax",
              "test_fast", "stream:proto:check", "quality:architecture"]
   ci_full = ["design:validate", "adr:validate", "adr:verify", "syntax", "test",
              "test_slow", "stream:proto:check", "quality:architecture"]
   quality = ["quality:architecture"]
   ci_fast = ["design:validate", "syntax", "test_parallel"]
   ```

   No `quality:rubocop_gate`, no `quality:reek`, no `quality:coverage`, no
   `quality:baseline_drift`, in **either** gate. The report is exactly right.

2. **`Rakefile:367-373` — the enola warn-and-return.** Confirmed verbatim: `if
   File.executable?(ENOLA_BIN) ... else warn "architecture: skipped — no enola at
   #{ENOLA_BIN} (set ENOLA_BIN to run it)"`. It is a `warn`, not a `raise`, so the
   task exits **0** when enola is absent.

3. **`Rakefile:425` — the `quality` aggregate.** `task quality: ['quality:architecture']`.
   Confirmed; this is R01-GATE-04 and shares this root.

4. **`Rakefile:431` — the budget.** `CiBudget::BUDGET_SECONDS = 60.0`, inside
   `module CiBudget` at `:429-432`. Confirmed.

5. **`.github/workflows/ci.yml:38` — does the runner install enola?** No. The job
   is `actions/checkout` (pinned SHA, `persist-credentials: false`) →
   `ruby/setup-ruby` (pinned SHA, `ruby-version: ".ruby-version"`,
   `bundler-cache: true`) → `bundle exec rake ci`. There is no provisioning step,
   no release download, no `ENOLA_BIN` environment entry, and no cache action
   other than Bundler's.

   **The enola-on-CI-runner trace:** `ENOLA_BIN` defaults to
   `File.join(Dir.home, '.local', 'bin', 'enola')` (`Rakefile:289`) —
   `$HOME/.local/bin/enola` on the runner. I verified the two facts that settle it:
   (a) the binary is **not a Bundler artifact** — `grep` of the Gemfile/gemspecs
   shows no enola gem, and `bundle install` cannot place a file in
   `~/.local/bin`; (b) `docs/QUALITY_PROGRAM_STATE.md:64`'s own record says enola
   is a manually installed, prebuilt upstream CLI ("`~/.local/bin/enola` (v0.2.7-…).
   **Not on PATH** — call by full path"). On a clean `ubuntu-latest` runner with
   only `actions/checkout` + `ruby/setup-ruby` + `bundle install`, nothing makes
   `File.executable?(ENOLA_BIN)` true. `quality:architecture` therefore warns once
   and returns 0, and the architectural gate (Q7: zero cycles, zero layer
   violations) is **not enforced by CI at all**.

   On this machine the default path *does* exist (`File.exist?` → `true`, a local
   42 MB binary), which is precisely why the divergence is invisible locally: the
   same commit grades differently on the developer machine and on CI.

6. **`docs/QUALITY_PROGRAM.md:187` and `docs/QUALITY_PROGRAM_STATE.md:122`** — cited
   line numbers are slightly off; the claims are nonetheless present and correct in
   substance. The `rake ci`-as-everyday-gate sentence is at
   `QUALITY_PROGRAM.md:201` ("otherwise `rake ci` (fast gate) + `rubocop` + `enola
   check` is the everyday gate"), not `:187` (which is Q7's enola/dependency-target
   prose). The state doc's claim **is** at `:122-123` verbatim: "`rake ci` now
   includes the three fast gates (rubocop_gate + reek + architecture) — one
   command, one gate (CODING_STANDARD §1)". That sentence is **false against the
   Rakefile**, and it is the strongest documentary evidence for this finding.
   `QUALITY_PROGRAM.md:108` compounds it by naming the intended aggregate block.
   **Citation correction: `QUALITY_PROGRAM.md:187` → `:201`.**

7. **`test/ci_configuration_test.rb:30`** — confirmed: it asserts only that some
   step's `run` equals `"bundle exec rake ci"`. It does not load the Rakefile, does
   not inspect prerequisites, and does not know what `ci` contains. Green
   (`2 runs / 15 assertions / 0F`) while the gate it nominates skips every ratchet.

### Reachability

A contributor adds 500 RuboCop offenses in a file not yet in `.rubocop_todo.yml`,
or regresses a Reek count, or drifts the baseline. `rake ci` is green locally and
in CI, because neither gate runs them. Fully reachable, and the highest-consequence
process finding in the batch — a green CI does not mean what
`QUALITY_PROGRAM_STATE.md:122-123` says it means.

### Severity

`major` holds comfortably. This is a materially misleading gate — the CI signal is
read as evidence of quality and is not. It is not `critical` because it is a
process/evidence gap, not a runtime unsafe action or data loss; but "materially
misleading evidence" is the BAR's own `critical` language, and the reason I stop
at `major` is that the misleading object is a build signal rather than a shipped
artefact — a distinction the coordinator may wish to revisit if CI is ever treated
as the release authority.

### Guards

None. No test pins the prerequisite list (`not found`, confirmed: nothing loads the
Rakefile and asserts `ci ⊇ {...}`). The `ci` epilogue (`Rakefile:448-451`) is
honest about the **test** lane it skipped but never mentions the quality gates it
also did not run — the report's observability half is correct and is the reason
operators trust the green.

### Probe

No behavioral probe is appropriate (the brief forbids running the gate). The
evidence is the enumerated graph above plus `test/ci_configuration_test.rb` →
2 runs / 15 assertions / 0F.

### Budget risk — answering the analyst's own caveat with a measurement

The report flags that adding `quality:reek` may blow `BUDGET_SECONDS = 60.0`, and
the coordinator asked me to settle it. I measured both proposed additions
directly (the rubocop timing carries a sandbox caveat: the result cache is
unwritable here, so this is a lower bound):

| Gate | Measured wall time | Note |
|---|---|---|
| `quality:reek` (equivalent invocation, `--format json` over `gems script bin apps`) | **~17 s** | 7,035 smells parsed; matches `Rakefile:327-340` |
| `quality:rubocop_gate` (`rubocop --format simple`) | **~2 s** | cache write denied in this sandbox; cold-cache on CI would be higher |

**The recommendation can backfire, and the analyst is right to flag it.** The
budget is 60 s *total* for the whole `ci` task, and the guard at `Rakefile:461-463`
`abort`s when elapsed exceeds it — but only if `CiBudget.parallel_workers >= 2`;
on a single-worker runner it downgrades to `warn "budget not enforced"`. So adding
`quality:reek` (+17 s) and `quality:rubocop_gate` (+2 s, likely more cold) pushes a
fast lane that the state doc itself bills at "~49s" toward or past the ceiling on
a slower machine. The failure mode is asymmetric and worth naming: on a
multi-worker developer machine the gate **aborts** (a false red on an unrelated
change), while on a single-worker runner it silently **warns and passes** (the
budget stops meaning anything). Neither is the outcome the owner wants.

Therefore the correct sequencing is: add the prerequisites **and** re-baseline
`BUDGET_SECONDS` in the same change, or move `quality:reek` to `ci_full` and keep
only the ~2 s `quality:rubocop_gate` in `ci`. Adding it blind is a real risk of
trading one broken gate for another. This is the one place I would amend the
report's recommendation.

### Verdict + reason

**UPHELD at `major`.** The `ci` array is confirmed empty of every ratchet, enola
is provably unprovisioned on a clean CI runner (the task then warns and exits 0),
the state doc's "one command, one gate" claim is false against the Rakefile, and
no test pins the composition. Citation correction: `QUALITY_PROGRAM.md:187` →
`:201`. Recommendation amended: raise `BUDGET_SECONDS` (or lane `quality:reek`
into `ci_full`) in the same change, or the fix backfires.

---

## R01-GATE-02 — the release rehearsal certifies `rake ci` while claiming the full gate

**Assigned:** major, high. **Verdict: UPHELD at `major`, as a defect in BOTH the
script and the doc — the intent decision the analyst asks for is answerable from
the Rakefile.**

### Source re-verified

Exact. `script/release_rehearsal:157` runs
`[RbConfig.ruby, "-S", "bundle", "exec", "rake", "ci"]`, and the comment at `:20`
calls step 4 "full gate `rake ci` under BOTH `LC_ALL=C` and
`LC_ALL=en_US.UTF-8`". It runs `ci`, not `ci_full`.

### Reachability and the committed evidence

The coordinator asked me to verify that the committed evidence really reflects the
fast lane. It does, and the number proves it:

```
docs/release-rehearsal.json
  gate_totals = {"C"=>"1233 runs, 38397 assertions, 0 failures, 0 errors, 0 skips",
                 "en_US.UTF-8"=>"1233 runs, 38397 assertions, 0 failures, 0 errors, 0 skips"}
  ok = true
  candidate_commit = 66bc81938aaaad8c3070efe53338f71c0c39a4e9
```

1233 runs is `test_fast`. `ci` excludes `SLOW_TESTS` (9 files) and the serial tail
(`Rakefile:150-154`), while `ci_full` adds `adr:verify`, `test` and `test_slow`.
So the release evidence certifies a rehearsal that skipped the slow lane, the
serial lane, and every ratchet (per R01-GATE-01) — and records `ok: true`.

### Severity, and the intent question

`major` holds. This is materially misleading release evidence: a release-gating
artifact claims a gate it did not run.

**The analyst says an intent decision is needed. It is answerable, and the answer
is "the script is wrong".** The rehearsal's own header (`:17-18`) says
"provisioning is part of the script" and the step is titled "full gate"; the
Rakefile's own comment (`ci_full`'s description, `Rakefile:470`) says "The complete
gate — nothing skipped (use before committing)", and `:451` says "Run `rake
ci_full` before committing anything touching durability, MCP, packaging or the
committed evidence artifacts" — a release rehearsal touches **all** of those by
definition. The repository already declares which command is the full gate. There
is no genuine ambiguity: the script's code contradicts its own comment and the
Rakefile's stated policy, so this is a defect in the **script** (one word:
`"ci"` → `"ci_full"`) and, secondarily, in the doc line that repeats the wrong
claim.

### Guards

The coordinator asked whether `test/release_rehearsal_evidence_test.rb:67-88`
asserts only that steps RAN. It does — and the file is more explicit about its own
blind spot than the report credits. `REQUIRED_STEPS` (`:65-71`) is a list of step
*names*, and `test_the_script_performs_every_required_step` asserts
`REQUIRED_STEPS - declared_steps == []`; `test_the_committed_evidence_covers_the_steps_it_ran`
asserts core step names are present and unique, plus the toolchain pins. The
comment at `:76-79` even explains that it asserts against the script's source
rather than the evidence. **No assertion anywhere names the rake task.** So the
gate step's *identity* is pinned and its *content* is not — confirmed, exactly as
the report says. Green: `9 runs / 44 assertions / 0F`.

### Probe

No probe run: the script clones the repo and runs `bundle install --local`, which
is outside a read-only budget and forbidden by the brief. The evidence is the
committed `gate_totals` (read directly), the prerequisite arrays (enumerated), and
the test's assertion set (read). The omission is proven from the arrays, which is
sufficient; the report's own caveat that it did not measure what `ci_full` *would*
produce is honest and does not weaken the finding.

### Verdict + reason

**UPHELD at `major`; defect in the script (primary) and the doc (secondary).**
`rake ci` is provably not the full gate, the committed `gate_totals` provably
reflect the fast lane, and the evidence test asserts only that the step ran. The
intent is not ambiguous — the Rakefile already names `ci_full` the complete gate.

---

## R01-GATE-04 — `rake quality` is enola-only

**Assigned:** major, high. **Verdict: UPHELD at `major` as a distinct observable,
and it should be indexed once with R01-GATE-01 as the analyst suggests.**

### Source re-verified

Exact: `Rakefile:425` is `task quality: ['quality:architecture']`, enumerated
independently confirmation — `quality = ["quality:architecture"]`. `Rakefile:367-373`
no-ops without enola (see R01-GATE-01). `QUALITY_PROGRAM.md:108` names the intended
block as `quality:architecture`, `quality` among the namespace tasks.

### Reachability and severity

An agent or operator told "run the quality gate" runs `rake quality`, gets one
warning line and exit 0, and has checked **nothing** — not rubocop, not reek, not
coverage, not the baseline. On a runner without enola (which is every clean CI
runner, per R01-GATE-01) the aggregate task is inert by construction. That is
materially misleading evidence about quality with real operational cost, so
`major` holds.

The analyst is right that this is the **same root cause** as R01-GATE-01 —
"gate composition is prose, not a tested contract" — and explicitly invites the
coordinator to fold it in. I agree with the merge, and go one step further: the
distinct observable does not require a distinct finding, because a single fix at
the aggregate (`Rakefile:425`) plus a single fix at the prerequisite arrays
(`:444`, `:471`) is one coherent change to one artifact. Two findings whose fix is
one edit to one file inflate the count. **Recommend: keep the citation, index as
one finding with R01-GATE-01.**

### Guards

None. No test reads `Rake::Task[:quality].prerequisites` (`not found`, confirmed).

### Probe

No probe; the evidence is the enumerated graph. `rake quality` was not executed —
the brief forbids running the quality gates, and its behaviour is fully determined
by the two lines read.

### Verdict + reason

**UPHELD at `major`, merged into R01-GATE-01.** One line of Rakefile is
materially misleading about quality on any enola-less host; same root and same fix
surface as GATE-01, so it should be indexed once.

---

## S01-BEN-01 — runner/evidence scripts shell out with no bounded timeout

**Assigned:** major, high. **Verdict: UPHELD at `major`, with a correction to the
count and the seam confirmed.**

### Source re-verified, and the call-site count

The coordinator asked me to verify the nine unbounded `Open3.capture*` call sites.
Confirmed, with a refinement the report elides: there are **12** `Open3` call
sites across the named scripts, of which **9 are genuinely unbounded subprocess
runs** and 3 are trivial local `git rev-parse` reads:

Unbounded (9): `autonomy_scorecard:82`, `capture_phase2_receipt:32`,
`generate_graph_surface_audit:74`, `generate_release_evaluation_manifest:62`,
`generate_requirements_audit:78`, `regenerate_quality_baseline:38`, `:70`, `:131`,
`:157`, `:179` — the last four are one script but four distinct sites, and `:157`
is a whole `RUN_COVERAGE=1` rake test.
Trivial `git rev-parse` (3, not worth bounding): `capture_phase2_receipt:183`,
`generate_release_evaluation_manifest:76`, `benchmark_comms_run:70`,
`benchmark_openclaw_run:73` — note this is four, one of which the report's list
already treats separately.

Net: the report's nine-site claim is **correct** for the meaningful sites, but its
prose enumerates 11 entries while saying "five" in the title ("five runner/evidence
scripts") and "nine" in the source-evidence line. The title is wrong: it is
**nine call sites across seven scripts**. That should be corrected; the substance
is unaffected.

### Reachability

`generate_requirements_audit` spawns one test subprocess per named manifest
reference; `autonomy_scorecard` one per case (16); `regenerate_quality_baseline:157`
a whole coverage run; `generate_graph_surface_audit:74` seven product tests under
`Coverage`. A single wedged child (an MCP server that will not exit, a pipe reader
holding a descriptor) hangs an evidence generator forever with no typed failure and
no distinct exit code. Reachable on the release/evidence path, which is what makes
it more than a style note.

### Severity

`major` holds: unbounded work on an evidence-producing path is a resource-bound gap
with real operational cost, and the BAR's scalability lens explicitly asks whether
"work, bytes, concurrency, retries, queues, and memory [are] bounded with
backpressure". It is not `critical` — no unsafe action, no data loss, and the hang
is loud in the sense that the process simply never finishes.

### Guards — the repo already owns the seam

Confirmed, and this is the finding's strongest feature. The bounded seam exists and
is already used inside the same `script/` tree:

```
gems/tamoz-evals-runner/lib/tamoz/evals/harness/subprocess_runner.rb:143
  def capture(argv, timeout_ms:, command:, intervention: nil, poller: nil)
gems/tamoz-evals-runner/lib/tamoz/evals/harness/subprocess_runner.rb:18
  MAX_TIMEOUT_MS = 3_600_000
```

`script/run_m1_conformance` and `script/run_m2_conformance` already call it with
real deadlines, and `run_m1_conformance:128-133` contains a deliberate
deadline self-test (`capture_sandboxed([RbConfig.ruby, "-e", "sleep 60"],
timeout_ms: 10, ...)`) whose whole purpose is to prove the deadline kills a hung
child. That is the repo's own internal evidence that an unbounded child is a
recognized defect here — the report's framing is right and I verified every part
of it.

### Probe

No probe: I did not run any of these scripts (they invoke full test suites and
coverage runs; `regenerate_quality_baseline` rewrites committed artifacts). The
claim is an absence of a `timeout_ms:` argument at the cited lines, fully provable
by reading the 12 call sites, which I did. No test asserts a timeout at any of
them (`not found`, confirmed).

### Verdict + reason

**UPHELD at `major`.** Nine unbounded subprocess call sites on evidence/release
paths, the bounded seam (`SubprocessRunner#capture(argv, timeout_ms:)`) already
exists and is already used by two sibling scripts with a self-tested deadline.
Correct the "five scripts" title to "nine call sites across seven scripts".

---

## Merge recommendations

Which findings share a root and should be indexed once:

1. **R01-GATE-01 + R01-GATE-04 — merge into one finding.** Identical root ("gate
   composition is authored as prose in three artifacts with no cross-check") and
   identical fix surface (one edit to `Rakefile`'s `ci`/`ci_full`/`quality`
   definitions). The analyst proposes this; I agree and would go further — keep
   `Rakefile:425` as a second citation on GATE-01 rather than a separate major, so
   the R01 major count drops from 2 to 1 for these two.
2. **F22-REL-01 → duplicate of F07-REL-01.** The report concedes the defect belongs
   to F07; the F22-owned residue is one missing sentence in
   `documentation/architecture/invariants.md`. Index as `duplicate`, severity
   `info` on the F22 side; F07-REL-01 keeps `major`.
3. **F22-SEC-01 — do NOT merge.** Explicitly independent of F07-SEC-01 (authority
   binding vs effect row scope) and a third enforcement site for F21/F25's verdict.
   Keep as its own `major`; note the required sequencing with F21/F25.
4. **F06-SEC-01 — do not merge, but re-index.** Its real content (the
   `verify_manifest_digest!` early return for `"prompt"` leaves a comment that
   overstates the check) belongs with **F06-REL-03** (`ArtifactStore` is in-memory
   in the shipped launcher), because both are consequences of
   `retain_manifest_artifacts` running only when `@artifact_store` is bound
   (`situation_request.rb:529`). One `info` finding with two citations.
5. **F06-SEC-03 — do not merge.** It is a memory-boundary contract question owned
   by `tamoz-sqlite`/`tamoz-agent-memory`, not the stream row; but as an `info`
   item it should be cross-linked to `memory_store.rb:626-632`'s stated rule so the
   owner confirms rather than re-litigates it.
6. **E09-REL-01 + E09-MNT-02 — already handled.** The report folds the discarded
   `Process.wait` status into E09-REL-01 as `info`, which is correct; keep that
   shape.
7. **E08-REL-01 + E08-MNT-02 — already handled.** Same shape; correct.

## Net effect on FINDINGS.md

| Finding | Effect |
|---|---|
| F22-COR-01 | **keep** at `major`; correct the finding text — the live state loses its `effect_receipts` (3→0) and `check_passed` flips `true`→`false`, not just the terminal reason. |
| F22-REL-01 | **change to `duplicate` of F07-REL-01**; F22-side severity `info`. |
| F22-SEC-01 | **keep** at `major`; independent of F07-SEC-01, third enforcement site for F21/F25. |
| F06-SEC-01 | **change severity to `minor`** (contract/comment accuracy), re-indexed with F06-REL-03 as `info`; refuted as a security finding. |
| F06-SEC-03 | **change severity to `info`**; documented design decision at `memory_store.rb:626-632`, no production pairing. |
| E09-REL-01 | **keep** at `major`; independently reproduced (134 on both signals), suite green on the identical path. |
| E08-REL-01 | **keep** at `major`; reproduced (8 retries / 30 s), cursor store durable and read per pass. |
| A01-COR-01 | **change severity to `minor`**; inert metadata, no runtime or external consumer. |
| R01-GATE-01 | **keep** at `major`; fix citation `QUALITY_PROGRAM.md:187`→`:201`; amendment — raise `BUDGET_SECONDS` in the same change (measured: reek ≈17 s + rubocop_gate ≈2 s vs a 60 s budget). |
| R01-GATE-02 | **keep** at `major`; defect in the script (primary) and the doc (secondary); intent settled by `Rakefile:451`/`:470`. |
| R01-GATE-04 | **merge into R01-GATE-01** as a second citation; the R01 count for these two drops from 2 to 1. |
| S01-BEN-01 | **keep** at `major`; correct the title from "five scripts" to "nine call sites across seven scripts". |
