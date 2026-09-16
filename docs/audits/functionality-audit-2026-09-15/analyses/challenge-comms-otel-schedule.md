# Independent challenge — F11 (6), F16 (3), F05-REL-04/05

- **Challenger:** independent adversarial challenger (read-only), lane C.
- **Date:** 2026-09-15.
- **Baseline:** repo `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD `582ae55` (verified `git log --oneline -1`).
- **Method:** for every finding I re-read the cited source at the exact `file:line`, re-derived the reachability chain, attacked the severity against `BAR.md`'s `critical`/`major` definitions, grepped beyond the cited files for missed guards and missed callers, re-ran the named focused suites (one file per command, `ruby -Itest`, `timeout 150`), and ran a minimal `/tmp` probe against the real classes. Probes that **failed** to reproduce are reported as such, not massaged.
- **Probe inventory (all under `/tmp`, none in the repo):**
  - `/tmp/chal/probe_admission.rb` — `Admission.decide` for F11-SEC-01/02/03 and `Rendering.plain` for F11-COR-01.
  - `/tmp/chal/probe_lease.rb` — real SQLite temp DB, `forbid` schedule, lost consumer (F05-REL-05).
  - `/tmp/chal/probe_misfire.rb` — `misfire_selection` growth for F05-REL-04.
  - `/tmp/chal/probe_otel.rb` — real `HTTPExporter#resource_spans` for F16-SEC-02 / F16-OBS-01.
  - `/tmp/chal/probe_err01.rb` — real `comms_store` for F11-ERR-01 / F11-ERR-02.
- No production code, test, config, gemspec, fixture, or other doc was modified. No commit. No `rake ci`/`ci_full`. No real LLM, Telegram, or provider was called.

---

## F11-SEC-02 — binding revocation does not take effect while the correspondent is also on the configured allowlist

### Source re-verified

The report's source citation is **correct as text but wrong as an inference**. `admission.rb:40` reads:

```ruby
return reject(:unbound, 'the correspondent is not bound') if binding && binding.fetch('status') != 'active'
```

The report quotes this line in its own Source evidence field and then describes it as "`:40` rejects only a *non-active* binding" — which is what the line says. The report's failure is that it does not follow the line to its consequence. Line 40 is evaluated **before** line 41 and therefore before both `command_admission` (`:67-80`) and `text_disposition` (`:89-113`). When a binding row exists and its status is `revoked`, line 40 returns `reject(:unbound, ...)` and control never reaches the allowlist `OR` at `:70-71` or `:97-99`. The `OR` the report calls the defect is only reachable when the binding is `nil` (no row at all) or `active` — never when it is `revoked`.

The report's claim that "`binding` is `nil` for a listed correspondent with no row, so the guard never fires" is true only for that sub-case, and that sub-case is **not** revocation — a correspondent with no binding row has nothing to revoke.

### Reachability

I could not construct any non-test sequence in which a revoked binding coexists with an admission. `revoke_binding` (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_routes.rb:51-71`) does not delete the row — it inserts a new higher-`version` row with `status = 'revoked'` — so after `tamoz comms pair revoke` a row **does** exist and **does** carry `revoked`. That is exactly the input line 40 rejects. There is no intermediate state: the store writes `active` or `revoked`, `Binding::STATUSES` is the closed pair `%w[active revoked]` (`binding.rb:24`), and the descriptor cannot carry a binding at all (bindings are store rows, not descriptor fields — `surface_descriptor.rb:44-60` has no binding member).

The gateway passes the binding unconditionally: `gateway_admission.rb:20` (`binding: latest_binding(envelope)`), so the production caller always supplies the store's latest row.

### Guards

The missed guard is **the cited line itself**. I grepped the whole gem and gateway for any other consumer of `binding` status that could restore the report's scenario and found none. There is also a second, independent revocation effect the report did not credit: `revoke_binding` deletes the correspondent's `inactive` approval prompts in the same transaction (`comms_routes.rb:68-71`), so revocation also withdraws pending approval surfaces — the "atomically invalidates unused approval prompts" half of `design/comms.md:66-67` is implemented too.

### Probe

```
$ export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
$ ruby /tmp/chal/probe_admission.rb
SEC-02 text  LISTED + revoked binding          => :rejected reason=:unbound         intent=nil
SEC-02 cmd   LISTED + revoked binding          => :rejected reason=:unbound         intent=nil
SEC-02 text  UNLISTED + revoked binding        => :rejected reason=:unbound         intent=nil
SEC-02 text  UNLISTED, no binding              => :ignored  reason=:unbound         intent=nil
```

The report's own probe result (`{listed_revoked: :rejected}`) is printed here unchanged; the report then reinterpreted `:rejected` as "only because the probe passed no allowlist match". My probe **does** pass a matching allowlist entry (`admission: { direct: 'allowlist', correspondents: [LISTED] }`, built through `SurfaceDescriptor.build` exactly as `test/comms_admission_test.rb:15-29` does) and still gets `:rejected`. **The defect does not reproduce.**

### Verdict

**REFUTED.** The guard is `admission.rb:40`, evaluated before the allowlist `OR`, and it rejects `revoked` unconditionally for both text and commands — reproduced with a listed correspondent holding a revoked binding. No operational cost: a revoked correspondent cannot cause a session to be constructed or a turn to run. The report's design question ("is the allowlist the actual authority and the binding only a routing hint?") is answered by the code: the binding is a **veto**, not a hint, and `design/comms.md:66-67`'s "revocation takes effect for future admissions" is satisfied for every correspondent the operator has listed or paired. Recommend closing.

---

## F11-SEC-03 — a channel callback reaches the decision path without any allowlist or pairing check

### Source re-verified

The citation is exact. `admission.rb:41` is `return callback_disposition if envelope.fetch('kind') == 'callback'`, and `callback_disposition` (`:124-126`) returns a bare `Decision.new(:decision, :callback, nil, nil, nil)` with no authority check. It sits before `:43-47`, so `command_admission` and `text_disposition` — the only functions that consult the allowlist or pairing mode — never run for a callback.

### Reachability

The admission-table fact is real and probed (see below): an unlisted correspondent sending `kind: 'callback'` under `allowlist` mode gets `:decision`, and under `pairing` mode with no binding also gets `:decision`. So on the **admission contract alone**, an unadmitted principal reaches `gateway_admission.rb:41-43` → `resolve_callback` + `acknowledge_callback`.

### Guards

This is where the report's `major` collapses. `resolve_callback` (`gateway_callbacks.rb:21-43`) applies three checks in order before any decision is recorded, and the *first two are independent of admission*:

1. `active_prompt?` (`:50-52`) — `prompt && prompt.fetch('status') == 'active'`. A missing prompt is falsy, so a callback naming an unknown reference is durably `ignored` as `unknown_reference` at `:26`. **Fail-closed on a missing prompt.**
2. `prompt_binding_matches?` (`:66-72`) — a five-way equality over `surface_id`, `surface_revision`, `correspondent_id`, `conversation_id`, and `prompt_receipt == callback_message_id`.
3. `approval_insufficient_evidence?` (`:35-38`) — deny-only evidence gate.

The coordinator's question was whether the binding compare is fail-closed on a missing/`None` binding. It is **not a nullable compare at all**: `prompt_binding_matches?` requires `prompt.fetch('correspondent_id') == envelope.fetch('correspondent_id')`. An unlisted sender cannot satisfy it, because the prompt's `correspondent_id` is the **admitted** correspondent's id — the id that was admitted when the prompt was created. There is no `nil` branch, no `||`, and no default that could pass: `fetch` raises on a missing key rather than returning falsy, so a malformed envelope raises rather than being admitted. The comparison is therefore strictly equality against the admitted identity, i.e. fail-closed.

To reach a decision the report asks about, an attacker must **already know the prompt receipt** (the Telegram message id of the approval card) and match five fields, one of which is the admitted correspondent id. That is not "defeating a second independent check" in the sense of a bypass; it is the check that *is* the authorization.

### Probe

```
$ ruby /tmp/chal/probe_admission.rb
SEC-03 cb    UNLISTED, no binding              => :decision reason=:callback        intent=nil
SEC-03 cb    UNLISTED + revoked binding        => :rejected reason=:unbound         intent=nil
SEC-03 cb    pairing mode, unbound             => :decision reason=:callback        intent=nil
```

Note the second line: with a **revoked** binding the callback is rejected at line 40 like everything else. The report's claim that no admission check applies is false in the revoked case, and the report's own probe did not test it.

### Severity against the BAR

`major` requires "a material ... gap with **real operational cost**". I can name no operational cost. The admission table is not the enforcement point for callbacks — `resolve_callback` is — and that enforcement is complete, fail-closed, and exercised by `test/comms_evidence_gated_approval_test.rb` (15 runs / 27 assertions / 0F, binding oracles at `:131-146,261-297`). The report itself concedes "**NOT a proven authority bypass**" and grades confidence `medium` for impact. Under the BAR that is a layout/defence-in-depth observation at a seam, not a defect with cost — the definition of `minor` ("local ... testability debt with limited immediate impact") or arguably `info`.

### Verdict

**DEMOTED to `minor`.** The admission table does exempt one inbound kind (confirmed by probe), but there is no reachable path where an unlisted sender's callback reaches a decision: `active_prompt?` refuses an unknown reference and `prompt_binding_matches?` requires exact equality with the *admitted* correspondent id, with no nullable branch. Real cost: none identified; the benefit of the finding is a defence-in-depth reordering plus one missing negative test, which is `minor` vocabulary.

---

## F11-SEC-01 — rendered channel text is never scrubbed or escaped, and the declared render format is validated but never read

### Source re-verified

Both halves of the citation are accurate. `Rendering.plain` (`rendering.rb:21-32`) and `split`/`take_part` (`:40-63`) perform no escaping, no scrubbing, and no sanitisation. `SurfaceDescriptor::RENDER_FORMATS = %w[plain restricted_html]` (`surface_descriptor.rb:37`) is validated at `:235-237` and, I confirm by repo-wide grep, read by **nothing else**:

```
$ grep -rn "restricted_html\|RENDER_FORMATS\|rendering.format\|render_format" --include=*.rb gems/ apps/ bin/ lib/
gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:37
gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:235
gems/tamoz-comms/lib/tamoz/comms/surface_descriptor.rb:236
```

The three `Rendering.plain` call sites (`outbox_delivery_sink.rb:116,254,330`) pass only `max_parts`/`part_characters`/`overflow`; none passes or reads `format`. The `restricted_html` member is dead configuration, and `F11-INFO-04` already says so.

### Reachability

The report's escape claim is about a format **nothing selects**. The only shipped transport sets no `parse_mode` (`telegram/transport.rb:52-56`, params are exactly `chat_id`, `text`, plus reply/markup), which the report reads as "Telegram parses the text as HTML". That inference is the whole security case and the report admits it "could not exercise a live bot". I did not exercise one either (prohibited), so I record the same gap — but I note the repo's own operational record states the opposite intent explicitly: `documentation/operations/ux-latency-investigation/iteration-02-telegram-message.md:98` lists as a known supported limitation "**No formatting (`format: plain` only; no parse_mode)**". The codebase's own position is that outbound text is unformatted.

The control-character half is real but its consumers are Telegram, which permits and normalises most control bytes in a text field.

### Guards

No escaper exists in `tamoz-comms`, and `gateway_delivery.rb:17` scrubs only gateway control replies — the report is right that model text is not covered. But that path is a *missing* feature for a format no caller selects, not a live exposure.

### Severity against the BAR

`major` needs real operational cost. Today there is **no endpoint** with `restricted_html` selected: the CLI default is `'format' => 'plain'` (`cli_comms_shared.rb:88-90`) and no code path or operator surface selects the other member. An accepted-but-unimplemented enum member plus a missing escaping helper is dead-contract debt — `minor` under the BAR ("bounded maintainability ... debt with limited immediate impact") — and its cleanup is a one-line removal or a one-escaper addition, exactly as the report's own recommendation allows.

### Probe

```
$ ruby /tmp/chal/probe_admission.rb
SEC-01 round-trip identical?  => true  bytes=[60, 98, 62, 38, 97, 109, 112, 59, 60, 97, 32, 104, 114, 101, 102, 61, 39, 120, 39, 62, 0, 7, 27, 91, 51, 49, 109, 13, 9]
```

The absence is confirmed (`<b>&amp;<a href='x'>` unescaped, `\x00 \x07 \x1b[31m \r \t` verbatim) — the *fact* is upheld, the *grade* is not.

### Verdict

**DEMOTED to `minor`.** The absence is real and reproduced, but `restricted_html` is selected by no caller (CLI default is `plain`), the shipped transport sets no `parse_mode`, and the repo's own ops note records "no parse_mode / plain only" as the supported limitation. There is no live endpoint with escaping promised and unfulfilled; the cost is a dead enum member, which is `minor`, not a `major` security gap.

---

## F11-ERR-01 — `mark_delivery` records any status from any claimed row, so the delivery state machine has no legal-transition guard

### Source re-verified

Exact. `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:235-246` writes `SET status = ?` from the caller's argument with `WHERE delivery_id = ? AND status = 'claimed' AND claim_owner = ? AND claim_fence = ?` — no `AND send_started_at_ms IS NOT NULL`. `reconcile_expired_deliveries` (`:146-163`) *does* distinguish the two cases (`send_started_at_ms IS NOT NULL` → `unknown`; `IS NULL` → back to `pending`), so the boundary marker is load-bearing everywhere except the terminal write.

### Reachability and the missed caller

This is where the report's `major` fails. The only two production callers of `mark_delivery` are in `delivery_drainer.rb`:

- `:95-102` — reached only after `:86-92` returns `send_started == :marked`, i.e. `mark_delivery_send_started` already succeeded. `return nil unless send_started == :marked` bars the external send *and* the terminal write together.
- `:107-114` — the `rescue Comms::AuthenticationError` branch. I traced the exception to its origin: `telegram/client.rb:67` and `:74` raise it from an HTTP response. `send_row` calls `mark_delivery_send_started` at `:86` **before** `send_delivery(row)` at `:93`, so reaching the rescue at all requires the boundary marker to be set.

So **no in-tree caller can mark an unstarted row**. The store's `mark_delivery` contract (`comms_store.rb:126-133`) already says "an outcome is recorded for a **CLAIMED** row" and that the marker makes an expired row resolve to `unknown`; the report is right that it does not *forbid* a caller from skipping the marker, but that is a contract-completeness observation with no reachable caller.

### Probe

I ran the report said it did not run:

```
$ ruby /tmp/chal/probe_err01.rb
append original       => appended
claim                 => claimed
ERR-01 mark succeeded w/o send_started => marked  (status-blind transition reachable)
ERR-01 row now status=succeeded send_started_at_ms=nil
```

The transition is **reachable through the public store API** — the fact is upheld. It is not reachable through the drainer.

### Severity against the BAR

The state machine is not actually unguarded in the shipped path; the guard is `delivery_drainer.rb:92`'s early return. A contract sentence plus one SQL clause is the fix, and it protects a future caller rather than correcting a present behavior. Under AGENTS.md's "do not cover rare cases" and the BAR's `minor` definition, this is bounded contract/testability debt with **no quantified operational cost** — no in-tree caller produces a false success.

### Verdict

**DEMOTED to `minor`.** The status-blind `UPDATE` reproduces through the store API, but both production callers are gated on `mark_delivery_send_started == :marked` (`delivery_drainer.rb:92`), so no false success is reachable in the shipped path. The defect is a missing precondition sentence + clause, not a live evidence failure.

---

## F11-ERR-02 — the store never verifies `content_digest` against the text it persists

### Source re-verified

Exact. `Delivery.build` folds the digest into the id (`delivery.rb:76-85`), `validate!` checks the digest's **shape only** (`:154`), and `comms_outbox.rb:35-38` returns `:duplicate` purely on `delivery_id` existence with no digest comparison. `:66-74` persists `text` and `content_digest` as independent columns.

### Reachability

The report is honest that "a live path that produces a mismatched digest is not proven". I confirm that: every production producer derives the digest through `Rendering.content_digest` (`outbox_delivery_sink.rb:201,364`) or `Comms::Rendering.content_digest(text)` (`gateway_delivery.rb:22`), so text and digest agree at every real call site. The mismatch exists in the report's own test helper and in my probe, not in production. The consequence the report describes — a repair silently discarded as `:duplicate` — requires a caller to deliberately pass a digest that does not describe its text.

### Guards and probe

```
$ ruby /tmp/chal/probe_err01.rb
ERR-02 same id?        => true
ERR-02 append repair   => duplicate
ERR-02 stored text     => "hello" digest still true
```

Confirmed exactly as the report describes. Note also that the store already has the *vocabulary* for the intended behavior — `admit_and_enqueue` returns `:integrity_conflict` for "the SAME identity under a DIFFERENT payload digest" (`comms_store.rb:46-49`). That pattern was simply never applied to `append_delivery`'s identity, which strengthens the report's root cause while leaving the reachability gap intact.

### Severity against the BAR

An unenforced identity invariant with no producing caller is a contract gap. The report's own confidence is `medium` and it names no operational cost beyond a hypothetical repair path. `minor`.

### Verdict

**DEMOTED to `minor`.** The absence reproduces, but every production producer derives the digest from the text it appends, so no corrected rendering is discarded today; the finding is an unenforced invariant worth one comparison, not a material gap with real operational cost.

---

## F11-COR-01 — truncate overflow discards the remainder with no marker

### Source re-verified

Exact. `rendering.rb:42-51` carves `text[0, ceiling * max_parts]` before splitting and appends nothing on the truncate branch. The contract at `design/comms.md:113` promises "bounded overflow with an explicit marker naming the thread and the `tamoz show` recovery command", and `rendering.rb:9-10` says "overflow beyond max_parts truncates explicitly".

### Reachability

Real and easily reached: any terminal answer longer than `max_parts × ceiling` characters. The default descriptor is `max_parts: 5, part_characters: 3500` (`cli_comms_shared.rb:88-90`), so a >17 500-character answer silently loses its tail.

### Guards

The report's guard analysis is correct: no marker parameter exists on `Rendering.plain` (`rendering.rb:21`), so **no caller can satisfy the contract** — `outbox_delivery_sink.rb:116-119` passes only the three limits. `F11-SCAL-01`'s related unbounded-read claim does not touch this.

### Probe

```
$ ruby /tmp/chal/probe_admission.rb
COR-01 parts=3 joined=300 marker_present=false
```

### Severity against the BAR

The operational cost is concrete and user-facing: a correspondent is shown a partial answer that is indistinguishable from a complete one, with no `tamoz show` pointer to recover the rest. That is a material correctness gap inside the written contract with a one-branch fix at the existing seam. `major` is correct.

### Verdict

**UPHELD as `major`.** Source, contract, guard, and probe all agree; the loss is undisclosed rather than merely bounded, which is the part the contract sells and the code does not deliver.

---

## F16-SEC-02 — the exporter applies no content/redaction policy to exported attributes and does not carry the governing policy digest

### Source re-verified

Exact. `http_exporter.rb:131` is `'attributes' => attributes` — the value is copied by reference, untransformed. `:113-123` reads only `correlation`, `attributes`, `observed_at_ms`, `name`, and the two timestamps. `recorder_journal.rb:147` merges `policy_digest` on every journal line; `resource_spans` does not.

### The analyst's two mitigating claims, verified independently

**(a) No enable path exists.** Confirmed, and stronger than the report states. A repo-wide grep for production construction returns only an unrelated comment (`drain.rb:5`) and a *different* `EgressPolicy` in `tamoz-mcp-websearch`; there is no `Tamoz::OTel::HTTPExporter.new`, no `AsyncExporter.new`, and no `Tamoz::OTel` reference outside `gems/tamoz-otel/`, `test/otel_test.rb`, and the single require at `test/test_helper.rb:61`. The gem is not merely off — it is unloadable in production.

**(b) `ContentPolicy` keeps prompt text in a separate field.** Confirmed from both directions:

- `Signal` carries `attributes` and `content` as **separate constructor fields** (`signal.rb:118-129`), and its real producers populate `attributes` from a closed catalog's `optional` keys (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:1258-1270`) or from identifiers and digests — `{provider:, model:}` (`runtime.rb:650`), `{tool:, argument_digest:}` (`step_execution.rb:266-271`), usage/cost numbers (`model_call.rb:33-43`). Content travels on the `content:` keyword, which is where `ContentPolicy::NONE` (the default, `worker.rb:59`) applies.
- `ContentPolicy` operates on the `content` hash only (`content_policy.rb:35-45`: `apply(content)` rejects `nil` and anything that is not a Hash keyed by content class; `describe` works per content class within `CLASSES`).

I also found a bound the report did not credit: `Signal` **rejects nested hashes outright** (`signal.rb:160`, `raise ValidationError, "#{path}: unsupported attribute value #{value.class}"` — my first probe attempt hit exactly this). A producer cannot smuggle a structured prompt into `attributes` even accidentally.

### Probe

```
$ ruby /tmp/chal/probe_otel.rb
span keys             = ["name", "trace_id", "span_id", "kind", "start_time_unix_nano", "end_time_unix_nano", "attributes"]
attributes on wire    = {"prompt"=>"SECRET-PROMPT-TEXT", "tool_arguments"=>"rm -rf /", "nested_deep"=>"a"}
policy_digest present = false
outcome present       = false
Signal fields         = [:kind, :name, :schema_version, :correlation, :timing, :started_at_ms, :ended_at_ms, :observed_at_ms, :attributes, :content, :policy_digest, :outcome, :error_class]
```

Verbatim egress of supplied attributes and total loss of `policy_digest` both reproduce. The report's P1/P12 are accurate. (Note: the report's P1 quotes a `"content"=>{...}` key and a `"nested"=>{...}` hash appearing in the span; those specific values **cannot** be constructed through the real `Signal` class — nested hashes raise. The conclusion is unaffected, but that probe appears to have bypassed the `Signal` constructor.)

### Severity against the BAR

The report asks me to confirm `major`-not-`critical`, and I do. `critical` requires "an active defect ... that can cause an unsafe action, authority bypass, data loss, false completion, ... or materially misleading evidence". Not met: the exporter is unreachable (no class is constructible in production), the `content`/`attributes` split holds at every real producer, and nested structures are rejected at the signal boundary. Nothing leaves the machine today.

But `major` **is** met, and by the report's second half rather than its first: dropping `policy_digest` means any exported span is not self-describing, so the property `observability-ops.md:78-81` claims ("A trace from last week states the content policy that produced it") would not survive export. That is a real evidence/ownership gap at a named seam with a one-line fix. I confirm `major`, not `critical`, and not lower.

### Verdict

**UPHELD as `major`, not `critical`.** Both of the analyst's mitigating claims verified independently (unreachable gem; `content`/`attributes` split at every real producer), so there is no live leak; the surviving `major` rests on the missing governing digest on the one egress path.

---

## F16-SEC-01 — the governed exporter has no enable path; its governance is unproven and its documented operational story is not implemented

### Source re-verified

`http_exporter.rb:11` is the only `include Tamoz::Observability::Exporter`. `exporter.rb:5-9` is a bare module of three `NotImplementedError` methods. `catalog.rb:176-177` declares `tamoz.telemetry.divergence` and `tamoz.telemetry.export`; a repo-wide grep finds these names **only** in `catalog.rb` and `test/observability_catalog_test.rb:36-37` — no producer exists, which is F16-OBS-01's half, and it is accurate.

### The documentation gap is real

- `documentation/design/observability.md:14` — "`tamoz-agent` loads it lazily when a runtime directory configures observability". No such call exists in `gems/tamoz-agent/lib` or `gems/tamoz-agent-cli/lib`.
- `documentation/operations/observability-ops.md:88-90` — describes `tamoz-otel` as usable and says installations without it "report a typed missing-adapter error for export". No such error class exists: `MissingAdapterError` is defined at `cli_comms_shared.rb:21` and used only by `cli_comms_doctor.rb:89,141` for **comms**, not export. The claim is stated in the design doc for `tamoz observe`/`tamoz trace` (`observability.md:14`) whose verbs do exist (`cli.rb:61-62`) — but the adapter story is unbacked.
- `documentation/limitations.md:119` — counts the "hardened optional OTLP/HTTP adapter" as **implemented** on code-presence grounds.

### Severity against the BAR

The report itself argues this is an "ownership/documentation gap, not a code defect", and I agree with its characterization while rejecting its grade. Every code claim inside it is accurate, but the *lens* is wrong: this is not a security or authority defect — the report explicitly confirms the "no untrusted enable path" property as a verified pass, and there is no caller to govern. The defect is that three documents describe a capability the repository does not wire and an error the repository does not raise. That is precisely the BAR's `minor` ("documentation ... debt with limited immediate impact") or `info` ("a verified design fact, limitation, or question that is useful for later work but is not itself a defect"). It is *not* a `major` security gap, because no authority can be bypassed on a path with no caller.

The report's own recommendation concedes the point: "state the missing contract rather than build the caller ... record in `documentation/limitations.md` that the adapter is present but **not wired**". A documentation correction is not a `major` security finding.

### Verdict

**DEMOTED to `minor`.** The absence and the doc divergence are verified and worth recording, but there is no code defect and no operational cost: the document is wrong, not the boundary. `minor` documentation/ownership debt (with the doc-correction recommendation retained as-is). Under the BAR a `minor` here does not by itself make the row `IMPROVE`, which matters for F16's verdict — `F16-SEC-02` and `F16-OBS-01` still carry that.

---

## F16-OBS-01 — Export outcome and divergence are unrecorded; the exported span loses `outcome`

### Source re-verified

Exact on all three legs: the two catalog names have no producer (grep above), export outcomes are produced at `http_exporter.rb:73-82` and consumed only into in-memory counters (`async_exporter.rb:85-96`, `health` `:49-58`), and `outcome` is in `signal.rb:70` but is not read by `resource_spans`. My probe printed `outcome present = false` for a signal explicitly constructed with `outcome: :error`.

### Severity against the BAR

Two independent consequences, both with real cost on a path an operator would use: a collector receives a failed turn's span with no error indicator (misleading evidence at the consumer), and the local journal records no attempt/delivery/drop history for export (an operator cannot distinguish a quiet plane from a broken one). The report's "doubly misleading" framing is fair, and `limitations.md:126` independently confirms "divergence accounting ... remain[s] outstanding".

The mitigating force is the same as F16-SEC-01's — no caller — but the difference is decisive: F16-SEC-01 is a documentation claim with no code behind it, whereas F16-OBS-01 is a code path that *builds and drops* evidence. The evidence gap survives as soon as anyone wires the gem, and the fix (emit from `delivery_result`, which already receives every outcome) is at an existing seam.

### Verdict

**UPHELD as `major`.** The dropped-field half reproduces directly, the declared-but-unproduced signal pair is confirmed by grep, and both have named operational cost. This finding, not F16-SEC-01, should carry F16's `IMPROVE`.

---

## F05-REL-04 — the `:latest` misfire ledger has no age or count bound

### Source re-verified, including the two doc lines

I re-read both cited doc lines myself rather than accepting the report's quotation.

- `documentation/design/scheduling.md:55`: "**There is no unbounded catch-up; `misfire_limit`, maximum age, and scan batch size are finite.**" The contradiction is **real and not a misreading**. `misfire_limit` is read only in the `:replay` branch (`schedule.rb:139-142`); for the **default** policy `:latest` (confirmed `schedule.rb:53` by probe: `default misfire_policy = :latest`) it is never consulted. "Maximum age" appears nowhere in the gem, the adapter, or the schema — grep for `max_age|maximum age|retention|prune` over `tamoz-scheduler/lib`, `sqlite/schedule_store.rb`, and `migrator.rb:405-427` returns nothing, and `tamoz_occurrences` has no age/expiry/TTL column (confirmed by `pragma_table_info` in my probe).
- `documentation/limitations.md:80-84`: "The misfire, overlap, backlog, jitter and catch-up policies the invariant also requires ARE implemented and tested." The report calls this "half true and half false" — that is exact. The misfire *policy* is implemented and tested; the **catch-up limit** the same sentence claims is not, for the default policy.

### Reachability and operational cost — the strongest attack

The report's growth claim survives, but its magnitude does not, and this is where I part company with `major`. The truth is between the report's two statements:

- **Per scan the ledger is bounded**, not unbounded: `due_occurrences(..., limit:)` truncates the window, so one scan appends at most `limit - 1` skipped rows. Probe: `limit=10 → skipped=9`, `limit=50 → skipped=49`, `limit=200 → skipped=199`.
- **Across scans it is unbounded**, because nothing retires a row: grep for a pruning job, reaper, or `DELETE` against `tamoz_occurrences` finds **none** in the scheduler, the adapter, or the migrator. `list_occurrences` clamps *reads* to 100 (`sqlite/schedule_store.rb:562`) but storage grows.

So the report's phrase "unbounded growth" is correct about history and wrong about per-poll cost; its own remediation ("do not add a pruning job or a retention column") silently concedes that growth is slow. And the growth rate is set by the **scan window**, which is the caller's `limit` — `worker.rb:155` passes `limit: @batch`. A schedule continuously behind by N cadences accumulates N rows **once**, not N per poll: the instants already materialized are deduped by `occurrence_exists?` (`sqlite/schedule_store.rb:373-379`) and the `PRIMARY KEY`/`UNIQUE` constraints. Repeated polling of an unchanged schedule adds nothing (my `probe_lease.rb` shows exactly this: 4 polls produced 4 terminal rows total, one per new cadence, not 9 per poll).

That is a real but **slow, self-limiting-by-dedup** growth on a table whose rows are small and read in bounded pages. The genuine aggravation is the F05-REL-05 wedge, where a dead consumer converts it into one permanent row per cadence forever — and that is F05-REL-05's cost, not this finding's.

### Severity against the BAR

`major` needs "a material ... scalability ... gap with **real operational cost**". The cost here is a slow, row-deduped append on a bounded-read table, with no measured magnitude, no pruning obligation in the design, and a recommended fix that is itself "cap the row count in `misfire_selection`" — a one-line policy change. Combined with the doc contradiction being a genuine finding, this reads as `minor`: bounded resource debt plus a documentation inaccuracy, immediately fixable, no durability risk. The report's confidence is `high`, which I do not dispute; its severity is the overreach.

### Verdict

**DEMOTED to `minor`.** The `scheduling.md:55` contradiction is real and confirmed (I re-read the line; `misfire_limit` genuinely does not bind `:latest`, and "maximum age" does not exist) and `limitations.md:80-84` is half false as the report says — but the operational cost is a slow, deduped, per-cadence row append on a table read in bounded pages, with no retention obligation in the design and a one-line fix. Documentation inaccuracy + bounded resource debt = `minor` under the BAR.

---

## F05-REL-05 — a lost consumer wedges a `forbid` schedule permanently: no occurrence expiry, reclaim, or recovery path exists

### Source re-verified

- `schedule_store.rb:61-64` accepts `lease_for:` in the contract; grep across `gems/`, `apps/`, `bin/` finds `lease_for` **only** at `worker.rb:154`, the contract declaration, and the adapter's `def` line (`sqlite/schedule_store.rb:168`) — it is never read in the body. Confirmed.
- `migrator.rb:405-427`: the schema has `fence`, `owner`, `reason`, `created_at_ms`, `updated_at_ms` and **no expiry column**. Confirmed by `pragma_table_info` in my probe.
- `schedule.rb:156-165`: `:forbid` skips while `non_terminal.positive?`, and `occurrence_state` counts `enqueued` (`sqlite/schedule_store.rb:355-371`).
- `errors.rb:21-26` advertises a "poller reclaims with a higher fence" path that does not exist; `ClockRollbackError` (`:35-41`) is never raised anywhere.

### Re-run of the experiment (temp SQLite DB in `/tmp`)

```
$ ruby /tmp/chal/probe_lease.rb
store responds to reap?                false
store responds to recover_occurrence?  false
store responds to renew_occurrence_lease? false
store responds to claim_due?           false
poll1@1700000000 claimed=1 states=[:enqueued]
poll2@1700003600 claimed=0
poll3@1700007200 claimed=0
poll4@1700010800 claimed=0
ledger states (4): [:skipped, :enqueued, :skipped, :skipped]
enqueued count=1 skipped count=3
after operator edit (revision 2) claimed=0
final ledger (10): [:skipped, :enqueued, :skipped, :skipped, :skipped, :skipped, :skipped, :skipped, :skipped, :skipped]
occurrence columns: ["occurrence_id", "schedule_id", "schedule_revision", "nominal_fire_at_utc", "not_before", "request_id", "state", "fence", "owner", "reason", "payload_digest", "created_at_ms", "updated_at_ms"]
```

Reproduced exactly as the report describes, on a real temp file DB: poll 1 claims 1 and leaves it `:enqueued`; later polls at successive cadences claim **0** while the ledger grows; an operator `put_schedule` edit to revision 2 does not unblock it; the `enqueued` row never leaves; no expiry column exists; and the store exposes no reclaim/reap/renew verb. **The wedge is real.**

### Attacking the severity — is there a documented recovery path?

The report's recommendation (a) proposes deleting the lease fiction and adding a worker-side guard. The coordinator asked specifically whether an operator command can clear the wedged occurrence, because a documented recovery path would materially change the severity. I searched the CLI for one:

- `tamoz schedule` verbs are `add|list|show|pause|resume|remove|run-now|occurrences` (`cli_schedule_commands.rb:25-28`). `occurrences`/`history` is **read-only** (`:244-266`).
- `remove` is a tombstone: it calls `disable_schedule` and `tombstone_schedule` and explicitly retains occurrence history (`:182-204`). It stops the bleeding (no further `skipped` rows) but leaves the `enqueued` row and the retained ledger.
- `run-now` **deliberately does not fabricate an occurrence** — the code says inventing one "would corrupt the history that misfire and catch-up decisions are made from" (`:209-215`). So it does not clear the wedge either.
- `tamoz resolve` (`cli.rb:45`) exists, but the occurrence rows are not effects: `resolve` targets `cli_comms_ops.rb:193` (`tamoz comms delivery resolve`) and the effect journal. Nothing routes it to `tamoz_occurrences`.
- `disable_schedule`/`enable_schedule` are the only lifecycle levers (`:136-140`) and neither touches occurrence state.

**No operator command clears the wedged occurrence.** The report's claim is upheld, and I checked a path it did not enumerate (`run-now`, `remove`). The only escape is out-of-band SQL against `tamoz_occurrences`, which no documented procedure names.

### Severity against the BAR

`major` is correct and I would not lower it. The cost is concrete and compounding: a `:forbid` schedule is permanently dead after any lost consumer, the operator's documented levers (`pause`/`resume`/`remove`/`run-now`) cannot revive it, the projection renders the stuck row as ordinary queued work (`worker_runtime.rb:975-993`), and the wedge emits one durable row per cadence forever — which is the *real* driver behind F05-REL-04's growth. A public `lease_for:` keyword, a `LeaseLostError` that promises reclaim, and a design diagram (`SCHEDULER_DESIGN.md:107-124`) all describe machinery that does not exist. That is a reliability and ownership gap with real operational cost.

### Verdict

**UPHELD as `major`.** Independently reproduced on a temp DB (poll 1 → `:enqueued`; polls 2-4 → 0 claimed; operator edit → still 0; no expiry column; no reclaim verb), and I confirmed no CLI path — including `run-now` and `remove`, which the report did not check — can clear the wedged occurrence.

---

## Ownership calls

**F11-ERR-01 and F11-ERR-02 belong to F07, not F11 — and should be recorded against F07's row with F11 as the contract witness.**

The reasoning is in the two sides of the seam:

- The **contract** side (`gems/tamoz-comms/lib/tamoz/comms/comms_store.rb:126-133` for `mark_delivery`, `:63-70` for `append_delivery`) is where the report says the sentence is missing. Both interfaces return a **closed result set** that already names the honest vocabulary: `mark_delivery` returns `[:marked, :not_claimable]`, and `admit_and_enqueue` returns `:integrity_conflict` for exactly the "same identity, different payload digest" case ERR-02 wants. The contract is thin, not wrong.
- The **implementation** side (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:235-246`, `:35-38`) is where both defects actually live: the missing `AND send_started_at_ms IS NOT NULL` clause and the digest-blind existence check are SQL in the adapter. `gems/tamoz-comms` ships **no** store implementation (`comms_store.rb:26-199` is structural; every body raises), so no F11 code change can fix either one.

Both reports flagged the overlap themselves. The correct disposition: **owner F07** (the adapter that fails to enforce the transition and the digest invariant), **witness F11** (the contract that should state the precondition). Do not double-count them into F11's tally — they are F07 defects whose repair happens in `comms_outbox.rb`.

---

## Net effect on FINDINGS.md

| Finding | Effect |
|---|---|
| F11-SEC-02 | **close** — refuted; `admission.rb:40` rejects a revoked binding before the allowlist `OR`, reproduced with a listed correspondent |
| F11-SEC-03 | **change severity to `minor`** — admission table does exempt callbacks, but no reachable path: `active_prompt?` fails closed and `prompt_binding_matches?` compares the *admitted* id with no nullable branch |
| F11-SEC-01 | **change severity to `minor`** — absence reproduced, but no caller selects `restricted_html` and no `parse_mode` is set; dead-contract debt, not a live exposure |
| F11-ERR-01 | **change severity to `minor`** and **reassign owner to F07** (contract witness F11) — transition reachable via the store API but gated in both production callers |
| F11-ERR-02 | **change severity to `minor`** and **reassign owner to F07** (contract witness F11) — absence reproduced, but every producer derives the digest from its text |
| F11-COR-01 | **keep** — `major` upheld; undisclosed truncation against a written marker contract |
| F16-SEC-02 | **keep** — `major` confirmed (not `critical`); both mitigating claims verified independently |
| F16-SEC-01 | **change severity to `minor`** — documentation/ownership debt, no code defect and no caller |
| F16-OBS-01 | **keep** — `major` upheld; dropped `outcome` reproduced, declared-but-unproduced signals confirmed |
| F05-REL-04 | **change severity to `minor`** — the `scheduling.md:55` contradiction is real, but growth is deduped per cadence, bounded per scan, and fixable in one policy line |
| F05-REL-05 | **keep** — `major` upheld; independently reproduced, and no CLI path (including `run-now`/`remove`) clears the wedge |

Row-level consequence: **F11** loses all six majors (one closed, five demoted) — its accepted set becomes `F11-COR-01` as the single `major` plus the demoted ones, so the row still reaches `IMPROVE` on `F11-COR-01` alone but with a far thinner basis than reported. **F16** should keep `IMPROVE` on `F16-SEC-02` and `F16-OBS-01`, not on `F16-SEC-01`. **F05** keeps `IMPROVE` on `F05-REL-05` and the carried `F05-REL-02`, not on `F05-REL-04`.

## Test pass counts (re-run at `582ae55`, one file per command, `timeout 150`)

| Command | Result |
|---|---|
| `ruby -Itest test/comms_admission_test.rb` | 15 runs, 51 assertions, 0F/0E/0S |
| `ruby -Itest test/comms_rendering_test.rb` | 6 runs, 35 assertions, 0F/0E/0S |
| `ruby -Itest test/comms_values_test.rb` | 20 runs, 78 assertions, 0F/0E/0S |
| `ruby -Itest test/comms_evidence_gated_approval_test.rb` | 15 runs, 27 assertions, 0F/0E/0S |
| `ruby -Itest test/comms_gateway_test.rb` | 39 runs, 242 assertions, 0F/0E/0S |
| `ruby -Itest test/otel_test.rb` | 6 runs, 17 assertions, 0F/0E/0S |
| `ruby -Itest test/observability_catalog_test.rb` | 10 runs, 26 assertions, 0F/0E/0S |
| `ruby -Itest test/public_api_test.rb` | 3 runs, 1051 assertions, 0F/0E/0S |
| `ruby -Itest test/scheduler_values_test.rb` | 17 runs, 112 assertions, 0F/0E/0S |
| `ruby -Itest test/scheduler_contract_test.rb` | 3 runs, 21 assertions, 0F/0E/0S |
| `ruby -Itest test/sqlite_schedule_store_test.rb` | 21 runs, 73 assertions, 0F/0E/0S |

Every count matches the three reports byte-for-byte. What they do **not** prove: none of these suites asserts an overflow marker, an escape/scrub boundary, a callback from an unlisted sender, a ledger ceiling under a long outage, or an expiry/reclaim path — so their green state is consistent with all eleven findings, upheld and refuted alike, and is evidence about regression safety rather than about any claim above. `rake ci` / `rake ci_full` were **not run** (excluded).

## Blind spots

- I did not exercise a live Telegram bot, so F11-SEC-01's `parse_mode` premise rests on the same unproven external fact the analyst flagged. My demotion rests on the *in-repo* fact that no caller selects `restricted_html` plus the repo's own ops note recording "no parse_mode / plain only" as the supported state — not on Telegram's parser behavior.
- F16-SEC-02's grade depends on the gem staying unreachable. If any later change constructs `HTTPExporter` or attaches content-bearing values to `attributes`, the `major` should be revisited upward; I recorded the exact grep so the next reviewer can re-run it.
- `gems/tamoz-agent` is row F25 and `gems/tamoz-sqlite` is row F07. I read `worker.rb`, `worker_runtime.rb`, and `sqlite/schedule_store.rb` only as far as the caller/implementation trace required and do not claim coverage of those rows.
- F05-REL-04's magnitude is unmeasured in absolute terms: I established the growth *shape* (deduped, per cadence, bounded per scan, unbounded in history) but did not run a long-outage soak to put numbers on rows-per-day. That missing magnitude is why I demoted rather than upheld, and it is the one piece of evidence that could reverse the call.
- Multi-process SQLite contention and the invariant-39 50-owner race were not run; `sqlite_schedule_determinism_test.rb` (4 runs) was not re-run by me.
