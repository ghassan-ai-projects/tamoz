# Independent challenge — F15-SEC-01 (+ the F15 minors)

**Challenger**: independent adversarial challenge lane (no scanner lane, no analyst lane; read-only).
**Date**: 2026-09-15.
**Baseline**: branch `audit-15-09`, commit `582ae55` (`582ae5566de1ae073aea82b69bb2bbf444494d3b`), worktree clean of production edits.
**Method**: re-read every cited `file:line` in `analyses/F15-observability.md`; traced the reachability chain from real callers; grepped for missed guards in `tamoz-observability`, `tamoz-agent`, `tamoz-agent-cli`, `tamoz-otel`, `tamoz-core`; ran the five focused observability suites plus `sqlite_trace_recorder_test.rb`; wrote positive-and-control probes against the real classes under `/tmp/tamoz-agents/`. No production file, test, fixture, gemspec, or config was modified; no commit was made. Liveness log: `/tmp/tamoz-agents/challenge_observability.log`.

**Instruction to myself, honoured**: this report tries to kill the finding. Where it fails to kill it, it says so plainly. It also reports the two things a rubber-stamp challenge would have missed — two wrong citations inside the finding block.

---

## F15-SEC-01

### Source re-verified

Every citation was opened at `582ae55`. What I read, and what differed from the report:

| Citation | Verified? | What the source actually says |
|---|---|---|
| `content_policy.rb:36-42` | correct | `describe` = `canonical_bytes` → `described_result` → `attach_capture!` if enabled. No scan, no redact, no detect. Confirmed by reading the whole 230-line file; the private method list is `build_limits … safe_truncate` with no matching step. |
| `content_policy.rb:80-95` | correct | `described_result` emits `*_digest`/`*_bytes`; `attach_capture!` writes `safe_truncate(bytes, limit)` — the raw canonical bytes — under the content-class key. |
| `content_policy.rb:169-172` | correct | `guard_value!` refuses exactly `value.is_a?(Tamoz::Secret)` plus depth > 64. Class identity only. |
| `content_policy.rb:201-206` | correct | `canonicalize_string` = `encode(UTF_8)` + 1 MiB bound. It is genuinely the single choke point for every captured string. |
| `signal.rb:195-198` | correct | `validate_content_entry!` refuses nesting > 64 and `Tamoz::Secret` by class. |
| `metrics.rb:142-149` | correct | `validate_label_value!` = label-key blacklist against `IDENTIFIER_LABELS` + `LOW_CARDINALITY_RE` on the value. No value policy. |
| `signal_catalog.rb:11`, `:236-245` | correct | `LOW_CARDINALITY_PATTERN = /\A[a-zA-Z0-9_.:-]{1,128}\z/`; `:low_cardinality` and `:enum` share one `type_matches?` charset branch. `:enum` is therefore *identical to* `:low_cardinality` — the catalog declares a closed set it never enumerates. |
| `worker.rb:137` | correct | `emit('worker.error', reason: error.message)` inside `reconcile_child_requests`. |
| `worker.rb:1032` | correct | `emit('worker.error', reason: "mode switch #{request.request_id}: #{error.message}")`. |
| `limitations.md:125` | correct | "full all-surface secret property test … remain outstanding". |

**Two citation errors found inside the F15-SEC-01 block — both immaterial to the finding, both real:**

1. **`recorder_drop_ledger.rb#DropLedger#validate!` is named as an enforcement point in `seam` and in the recommendation, but it validates only attribute *names*, not values.** `DropLedger#validate!` (`recorder_drop_ledger.rb:35-39`) delegates wholesale to `@catalog.validate_signal(signal)` (`signal_catalog.rb:64-71`). It reaches value validation only through `validate_attribute_values!` (`:211-217`) → `validate_attribute_type!` → `type_matches?` — i.e. the same charset test, never `validate_label_value!` and never any label logic. The analyst's sentence "the same predicate belongs in `DropLedger#validate!`'s catalog check **and** `Metrics#validate_label_value!`, which are already **the two enforcement points**" implies a label check already lives in the ledger. It does not; there is exactly one label enforcement point, in `Metrics`.
2. **`design/observability.md:47` is cited as the hidden premise, but the sentence is at `:47` only in part.** The quoted phrase "`Tamoz::Secret` is never admissible, above every policy decision" is the *last sentence of §"Content and secret policy"*, which begins at `documentation/design/observability.md:45`; `:47` is the body paragraph containing it. The citation resolves, so this is a precision note, not an error.

**Not verified as cited — and this one matters (minor, not fatal):** the report attributes probe **P5** to placing `sk-live-…` in a `reason` attribute. My own reproduction of that path (POSITIVE2 below) genuinely records the secret, so the *claim* is sound, but the report never states which producer emits `reason`. I traced it: there is no caller in this repo that passes a raw credential into `reason` — the two real callers pass `error.message` and an interpolated `request_id` (`worker.rb:137`, `:1032`). The secret reaches `reason` only if an exception message *contains* one.

**Additional finding the report missed, which strengthens its own recommendation but changes its shape:** `Tamoz::Secret` is refused in `content` (`content_policy.rb:170` → `Tamoz::SensitiveValueError`) but **not** in `attributes`, where it is refused only incidentally, by `freeze_value`'s `else raise ValidationError, "unsupported attribute value"` (`signal.rb:155-162`). A `Secret` in an attribute is dropped for being an unsupported *class*, not for being secret. The `guard_value!`-style refusal has no attribute-side counterpart. My CONTROL_B shows both refuse, so the operational outcome is the same today; the asymmetry is that adding any new supported attribute class would silently admit `Tamoz::Secret`.

### Reachability

The finding is real on a reachable path, but reachability is **narrower than the report implies**, and three of the four sub-claims are operator-enablement-gated rather than untrusted-content-driven. Concretely:

**The only in-repo producer that sets `reason` at all is `Tamoz::Agent::Worker#emit` → `#observable_attributes` (`worker.rb:1223-1271`), and it does not apply a content policy.** The worker's `content_policy:` keyword defaults to `ContentPolicy::NONE` (`worker.rb:59`) and **nothing in the repository ever passes anything else** — grep for `content_policy` across all non-test Ruby returns only `worker.rb:59` (the default), `worker.rb:69` (its use), and `tamoz-evals`' unrelated verifier field. No CLI flag, no config key, no app wiring constructs a capture-enabled policy. `apps/tamoz-agent` does not reference `ContentPolicy` at all.

That splits the finding into four claims with different reachability:

| # | Claim | Who supplies the offending value | Gate |
|---|---|---|---|
| a | captured `error_detail` / `tool_results` / `input_messages` writes a secret-shaped plain string verbatim | model reply, tool result, MCP/stream content **or** exception message | **requires an operator to construct a capture-enabled `ContentPolicy`** — no such construction exists in the repo |
| b | `reason` (a `:low_cardinality` catalog attribute) accepts a secret-shaped string verbatim | exception message (`worker.rb:137`) or an interpolated `request_id` (`:1032`) | **no gate — default `NONE` policy, live path, reachable today** |
| c | metric label values accept a secret-shaped string verbatim | the producer passing the label; no non-test `Metrics#increment/#observe/#set` caller exists in the repo | ungated by policy but **no live producer** calls it |
| d | loss of `trace_id` continuity when `thread_id` is absent | the caller's correlation hash | ungated, but attribution is a *reading* of `:ordering_only`, not a stated contract |

Claim (b) is the one that carries the finding: it is on the default, live path with no operator action, which is exactly what the BAR's "real operational cost" requires. Claim (a) is the one the report leans on and is the *weakest* of the four on reachability — it needs a policy the repo never builds. Claims (c) and (d) have no live producer.

**On who controls the value (the severity lever the brief asks about):** for (b), the offender is `error.message`. That is not attacker-authored text in the classic sense — but it is *external-content-adjacent*: a raised message can embed a URL, a header value, an MCP/stream payload fragment, or a provider error body. For (a) and (c) the value would be model/tool/MCP content, i.e. genuinely untrusted — but the path is unbuilt. I read this as: **untrusted-content reachability is real in the code's design, not yet real in the code's wiring.** That is a real deduction from the analyst's stated confidence, and I apply it below.

**Control case that *is* refused, verified:** `Tamoz::Secret` in content → `Tamoz::SensitiveValueError` (CONTROL_A); `Tamoz::Secret` in an attribute → `ValidationError` (CONTROL_B); an arbitrary signal name → `:dropped`, 0 recorded (E1); a name outside the permitted prefixes → refused; a correlation identifier as a label key → `:rejected` + violation (CONTROL_D).

### Severity

Mapped against the BAR verbatim.

- `critical` (`BAR.md:70-72`) requires "an unsafe action, authority bypass, data loss, false completion, broken durability/effect semantics, or materially misleading evidence". **Not met.** There is no authority change: `tamoz-observability` has no egress, no filesystem capability, no approval surface, and `Exporter` is contract-only (`exporter.rb:11`). Writing a credential into a local journal does not widen any capability.
- `major` (`BAR.md:73-74`) requires "a material correctness, security, reliability, observability, scalability, dependency, or ownership gap with **real operational cost**".

**The report does not name the operational cost. I went looking for it and it is real, though smaller than "a secret reaches the journal" suggests:**

1. **Nothing ever leaves the machine.** The journal is local, mode `0600` under a `0700` directory (`recorder_journal.rb:203-204`, `:238-239`), and is never written to the runtime DB (design `:51`).
2. **The exporter is dead code.** `tamoz-otel`'s `AsyncExporter#record` and `#deliver_batch` exist (`async_exporter.rb:37-44`, `:92`) but nothing in the repo constructs one; `tamoz-agent-cli` never builds an exporter. So the "then it gets shipped to OTLP" amplification is latent, not active — consuming the attribute hash verbatim, which I verified at `http_exporter.rb:126-134` (`'attributes' => attributes`, no redaction anywhere in `gems/tamoz-otel/lib`).
3. **The one piece of *decision-relevant* content inside a record has no policy at all, and no output runs it through a redactor.** `reason` is emitted by the live worker on the default policy; it lands in the NDJSON journal and in the `.health.json` sidecar via `persist_health`; and both my grep and the source confirm **nothing** redacts journal content on any read path — `observe tail` renders `observed_at_ms`/`name`/`correlation` only (`cli_worker_commands.rb:190-193`), `observe metrics` projects duration metrics only, `cmd_trace` builds spans. `observe doctor` is the only redaction check in the system (`:160-179`). So claim (b) is reachable today with no operator action and no downstream filter.

**My judgment: `major` is defensible, but for the `reason`/label sub-claim, not for the captured-content sub-claim the report leads with.** On the report's own lead argument (`error_detail` capture) I would have demoted to `minor`: it requires an operator to build machinery the repo never builds and the value never leaves the box. On claim (b) — default policy, live path, no downstream redactor, an on-disk durable artifact — the gap survives as `major` on the narrowest reading of the BAR: a security gap *with* real operational cost.

**Deduction I apply: confidence `high` → `medium`.** The BAR (`:81-87`) requires "the relevant source path **and boundary** are directly verified, and a test, contract, deterministic source proof, or reproducible runtime result supports the conclusion" for `high`. The source path and the runtime result are verified — my probes reproduce all four sub-claims. The *boundary* is not: the reachable end of the chain stops at a local `0600` file with no egress and no live capture policy. `medium` is the honest grade: "source evidence is real but a caller … or runtime condition remains unverified."

### Guards searched

Commands run (all from the repo root; every hit read):

```
grep -rn "ContentPolicy\|Observability::" --include=*.rb gems/ apps/ bin/ lib/ | grep -v gems/tamoz-observability/ | grep -v ^test/
grep -rn "content_policy" --include=*.rb . | grep -v /test/
grep -rn "redact\|REDACT\|SENSITIVE\|secret" --include=*.rb gems/tamoz-otel/lib
grep -rn "backtrace" gems/tamoz-observability/lib
grep -rn "Recorder::Journal.new\|:recorder" --include=*.rb gems/tamoz-agent/lib gems/tamoz-agent-cli/lib apps/
grep -rn "drops\b\|drops_hash\|:dropped" --include=*.rb gems/tamoz-otel/lib gems/tamoz-agent-cli/lib
grep -rn "content:" --include=*.rb gems/tamoz-agent/lib gems/tamoz-agent-cli/lib examples/ apps/
grep -n "class DurableRecorder" -r .
```

**The missed-guard question, answered field by field.** I traced every field that reaches a record:

| Field that reaches a record | Guard found | Verdict |
|---|---|---|
| `detail` hashes / nested content | `guard_value!` class check + 64-entry/64-depth/1 MiB bounds (`content_policy.rb:169-206`) | **no shape guard** |
| exception messages → `reason` | `LOW_CARDINALITY_PATTERN` charset only (`signal_catalog.rb:242`) | **no shape guard** |
| exception messages → captured `error_detail` | none beyond `canonicalize_string` | **no shape guard** |
| backtraces | **no reference to `backtrace` anywhere in the gem** | not a vector — nothing collects one |
| tool arguments / tool results | same as content: class guard + bounds only | **no shape guard** |
| model prompts / replies | same; only admissible when a capture class is enabled | **no shape guard**, and no in-repo policy enables it |
| metric labels | key blacklist + charset (`metrics.rb:142-149`) | **no shape guard** |
| `correlation` values | `validate_signal_correlation!` checks *keys* only (`signal_catalog.rb:180-187`) | values unguarded, but correlation values are durable identities |
| `error_class` | `error_class&.to_s` (`signal.rb:132`) | a class name; not a credential vector |

**Conclusion of the guard search: the analyst did not miss a guard.** The one candidate that could have refuted the finding — a downstream redaction layer — does not exist. `grep -rn "redact"` over `tamoz-observability` and `tamoz-otel` returns **zero hits**. `Tamoz::Core::Immutable.copy(reject_sensitive: true)` was considered; it rejects by class too, so it cannot close a shape gap, and the notifier path does not even route content through it.

**The closed-catalog question (see also the explicit section below): genuinely closed at every entry point, verified.** `Catalog::CATALOG` is a frozen `SignalCatalog` (`catalog.rb:185-188`), `Producer#build_signal` resolves through `Catalog.fetch` (`producer.rb:46-48`), `Notifier#instrument` short-circuits on `Catalog.registered?` (`notifier.rb:11`). I could not emit an arbitrary name.

**One weakening of the "closed" claim the analyst logged as a blind spot and I confirmed as a fact:** `SignalCatalog#event`/`#measurement` are public, and `validate_name` only enforces the *prefix* allowlist (`signal_catalog.rb:111-113`). E5: a caller can construct a fresh `SignalCatalog.new` and register `mcp.my.new.signal` without error. `Catalog::CATALOG` itself is already seeded and frozen, so an unknown name still cannot reach `Producer#emit` — but "closed" is closed **per registry instance**, not by construction of the type. This is `info`, not a defect, and it does not refute F15-SEC-01.

### Probe

All probes live under `/tmp/tamoz-agents/`; **zero scratch files were created in the repo**. Runner:

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
cd /Users/ghassan/my-projects/tamoz
timeout 150 ruby /tmp/tamoz-agents/probe_sec01.rb
```

**`/tmp/tamoz-agents/probe_sec01.rb` — exact output:**

```
RUBY 3.3.11
CONTROL_A refused: Tamoz::SensitiveValueError: Tamoz::Secret is not permitted in content
CONTROL_B refused: Tamoz::Observability::ValidationError: attributes.secret_token: unsupported attribute value Tamoz::Secret
POSITIVE1 emit=:recorded journal_contains_secret=true
POSITIVE1 journal_line={"kind":"event","name":"tamoz.worker.error","schema_version":1,"correlation":{},"timing":"point","observed_at_ms":1789464033791,"attributes":{"reason":"boom"},"content":{"error_detail_digest":"sha256:3ff7d819241bec5fcdd1563adee49c1a5a76fee064ea895fcf99d19791f47dab","error_detail_bytes":46,"error_detail":"Authorization: Bearer sk-live-ABCDEF0123456789"},"policy_digest":"sha256:d4fae64158fe982010f2b
POSITIVE2 emit=:recorded journal_contains_secret=true
POSITIVE3 histograms=[{"count"=>1, "sum"=>12.0, "max"=>12.0, "p99"=>12.0, "name"=>"tamoz.model.call.duration_ms", "labels"=>{"model"=>"m1", "outcome"=>"ok", "provider"=>"sk-live-ABCDEF0123456789"}}] violations={}
CONTROL_C series=4096 violations=904
CONTROL_D (via increment on measurement) = :rejected violations={"tamoz.model.call.duration_ms"=>2}
CONTROL_E newline_rejected=true secret_matches=true
```

- **POSITIVE1** (captured content): the secret is written **verbatim** into the journal line, beside its own digest — the digest does not protect the value when capture is on.
- **POSITIVE2** (`reason` attribute, **default `NONE` policy**): `journal_contains_secret=true`. This is the ungated, live-path case and the strongest evidence in the finding.
- **POSITIVE3** (metric label): the secret lands in `labels.provider` with `violations={}` — accepted silently.

**Controls, all of which behaved correctly** (this is why the finding is a real gap and not a false positive):

- **CONTROL_A** — `Tamoz::Secret` in content with capture enabled → refused. The class guard is real.
- **CONTROL_B** — `Tamoz::Secret` in an attribute → refused.
- **CONTROL_C** — 5 000 distinct label values → exactly 4 096 series, 904 violations. The series cap is real and counted.
- **CONTROL_D** — correlation identifier as a label key → `:rejected`.
- **CONTROL_E** — the charset genuinely refuses a newline and genuinely accepts the secret-shaped string. The pattern is doing exactly what it says; the *declaration* is what over-promises.
- **`/tmp/tamoz-agents/probe_sec01e.rb`** — E1/E2 arbitrary and bad-prefix names → `:dropped`, 0 recorded; E3 registered name → `:recorded`; E4 `rogue.thing` registration refused; E5 `mcp.my.new.signal` registration **accepted**; E6 `CATALOG.frozen? #=> true`; E7 68 names.

**Additional attacks that FAILED to refute or escalate the finding — reported plainly:**

- **`/tmp/tamoz-agents/probe_sec01b.rb`** tried newline-injection into a `:low_cardinality` attribute to forge a journal line. Result: `B newline_emit=:dropped`. The charset refuses `\n`, and `JSON.generate` escapes it anyway. A first attempt (`A emit=:dropped`) looked like a refutation of the attribute vector until I read my own probe: I had omitted `tamoz.model.call`'s required `outcome`, so the drop was for a missing required attribute, not for secrecy. **A probe that fails to reproduce for the wrong reason is not a refutation** — I re-ran it correctly (`probe_sec01d.rb`):
  - `B2` (forged JSON in `reason`) → refused at the charset, 0 journal lines.
  - `B3` (`:string`-typed attribute with a newline) → `:recorded`, **1 line, and it parses**. So a `:string` attribute *can* carry a newline, but `JSON.generate` escapes it and the NDJSON framing holds. **No journal forgery is possible here.** This is a genuine negative result and it *narrows* the finding: the `:string` attribute type is a policy-free hole, but not a framing hole.
- **`/tmp/tamoz-agents/probe_sec01c.rb`** — I tried to show a `:string`-typed attribute on a live worker path accepting a secret. The declared `:string` attributes are `cost_value`, `cost_currency`, `pricing_source`, `pricing_version` (`tamoz.model.call`), `execution_id` (request events), and the schedule ids. All are machine-generated. **No live producer passes a credential into one**, so this vector is permitted-but-unexercised. It is a latent hole, not an active one — a point in favour of demotion that I record against my own verdict.

### Verdict + reason

**UPHELD at `major` — with one deduction the analyst should carry: confidence `high` → `medium`, and the finding's *lead* argument (`error_detail` capture) is the weakest of its four sub-claims while its *second* argument (`reason` on the default policy) is the strongest.**

Reason, in BAR terms: a security gap exists at a real seam with a real, if bounded, operational cost. On the live default policy, with no operator action and no downstream redactor, an exception message containing a credential-shaped string is written verbatim into a durable `0600` NDJSON journal and its `.health.json` sidecar — `probe_sec01.rb` POSITIVE2 proves it end to end. The catalog's own `:low_cardinality` declaration (`catalog.rb:13`, `:80`, `:99`, `:111`, `:122`) promises a value discipline the runtime never enforces (`signal_catalog.rb:242`), and metric label values have no policy at all (`metrics.rb:142-149`). That is a material security gap with operational cost, so `major` holds.

**What I could not sustain at the analyst's stated confidence:** the capture path (`POSITIVE1`) needs a `ContentPolicy` that **no code in this repository constructs**, the value never leaves the host, and the exporter that would carry it is dead code. The label path (`POSITIVE3`) has **no non-test caller**. On those two alone the correct grade would be `minor`. The finding survives as `major` only on the `reason` sub-claim, and the report should say so explicitly rather than leading with the capture path.

**Not `critical`:** no capability widens, no authority is bypassed, no durability semantics break, and the affected artifact is local and never exported.

---

## Minor findings

- **F15-OBS-01 — UPHELD (minor).** `DURATION_METRICS` names exactly two signals (`metrics.rb:13-16`), `duration_metric_for` returns `nil` for everything else (`:162-164`), and `add_document` returns `:recorded` unconditionally on the non-raising path (`:68-75`), so an unprojectable document is silently lost. `design/observability.md:58`'s "Never lossy" is false as written. Minor is right: `limitations.md:121-126` discloses the pending telemetry adapter, and no decision is taken on this output.
- **F15-COR-01 — UPHELD (minor), and I reproduced it independently.** `count_drop` stores the pre-joined String (`recorder_drop_ledger.rb:46`), `drops_hash` destructures it as a 3-tuple and re-joins (`:53-55`). My `probe_flush.rb` run shows it live in the real class, not just in isolation: `"drops"=>{"invalid:validation:bulk::"=>13}`. Every consumer sums values (`recorder_journal.rb:325-329`; `cli_worker_commands.rb:633`, `:720`), so counts are intact — minor is correct.
- **F15-SCAL-01 — UPHELD (minor), and I share the analyst's deliberate restraint.** `validate_label_value!` (`metrics.rb:142-149`) checks key-blacklist plus the same charset as `signal_catalog.rb:11`; `:enum` and `:low_cardinality` are the same branch (`:241-242`), so `:enum` is never actually enumerated. I verified the series cap independently: `CONTROL_C series=4096 violations=904`. The memory bound the brief asked about holds; the "reject high-cardinality values" reading does not. No live `Metrics#increment/#observe/#set` caller exists, which keeps it minor.
- **F15-SCAL-02 — UPHELD (minor), but the factual half is now measured — and the measurement cuts against the analyst's `medium`-confidence framing.** `route` does wrap the decision in `synchronize` (`recorder_journal.rb:83`) and a saturated reserved lane does run `write_signal` → `append_line` → `open_io`/`write`/`flush`/`rotate_files` inside that block (`:94`, `:117-122`, `:150-168`), while `take_batch` needs the same mutex (`drain.rb:145-160`). I saturated a 1-deep reserved lane with the real `Producer` and **2 000 safety-bearing emits recorded 2 000/2 000 with `drops={}`, 2 001 lines on disk, and `flush -> 0` in 0.1 ms** (`/tmp/tamoz-agents/probe_scal02.rb`). The never-drop guarantee is exactly as strong as the analyst says. The *stall* is not: `flush_after_flood` did not contend materially at this scale. Keep it minor, and record that the operational cost is still unproven rather than merely unmeasured by the analyst.
- **F15-OBS-02 — UPHELD (minor).** `build_trace` hardcodes `divergence: []` (`trace.rb:78-81`), and `parent_span_id`/`span_anchor` are read from attributes (`:145-149`, `:156`) that nothing in the repo writes (only `tamoz-otel/http_exporter.rb:118` *reads* `span_anchor`). Both are disclosed at `limitations.md:121-126`, which is what keeps it minor.
- **F15-INFO-01 — UPHELD.** `limitations.md:115-129` is accurate claim by claim; its only over-statements are in `design/observability.md:47` and `:58`.

---

## Catalog closure / flush-isolation answers

**Q1 — Is the signal catalog genuinely CLOSED (unknown signal refused by construction), or can a caller emit an arbitrary name?**

**Closed at every real entry point; closed per-registry-instance rather than by construction of the type.** The exact mechanism: `Catalog::CATALOG` is one seeded `SignalCatalog` frozen at load (`catalog.rb:185-188`), and all three doors resolve against it — `Producer#build_signal` → `Catalog.fetch(name)` (`producer.rb:46-48`), which raises `UnregisteredSignalError` for an unknown key (`signal_catalog.rb:46-50`) that `Producer#emit`'s `rescue StandardError` converts to `:dropped` (`producer.rb:22-23`); `Notifier#instrument` short-circuits with `return handle_unregistered(&) unless Catalog.registered?(name)` (`notifier.rb:11`); and `Worker#emit_observability` pre-filters with `Catalog.registered?(name)` (`worker.rb:1240`). Verified: `probe_sec01e.rb` E1/E2 → `:dropped`, 0 recorded; E7 → 68 registered names. **The caveat:** `SignalCatalog#event`/`#measurement` are public and `validate_name` enforces only a prefix allowlist (`signal_catalog.rb:108-116`), so a caller holding or creating a `SignalCatalog` can register any name under `tamoz.`/`comms.`/`stream.`/`scheduler.`/`mcp.` (E5 accepted `mcp.my.new.signal`, E4 refused `rogue.thing`). That does not reach `Producer#emit`, because `Catalog` is the only registry `Producer` consults — so the runtime guarantee holds and this is `info`, not a defect.

**Q2 — Can `flush` raise into the caller's work path, i.e. can observation break the observed?**

**No. It cannot raise and it cannot hang.** Two independent guards: `Concurrency::Drain#flush` computes a deadline and `break if remaining <= 0` before waiting, so a zero or negative deadline returns the outstanding count instead of raising or blocking (`drain.rb:53-62`, `:56-58`); and `Fanout#flush` maps each child through `guarded(0)` so a raising child contributes `0` (`recorders.rb:108-110`, `:119-123`). `Journal` and `Memory` inherit the drain guard and add none that can raise. Verified in `/tmp/tamoz-agents/probe_flush.rb`: `1 zero_deadline -> 0`; `2 raising_deliver flush -> 0 (no raise)` with the writer singleton-replaced by a raising `deliver_batch`; `2 record_after_writer_failure -> :dropped`; `3 record_after_close -> :dropped`; `4 fanout.flush -> 0` and `4 fanout.record -> :dropped` against a child that raises in every public method. `Producer#around` re-raises the caller's own exception (`5 around re-raised: ArgumentError`) and `Notifier#instrument` likewise (`6 instrument re-raised: ArgumentError`) — observation never swallows the observed failure. Note for the flow analysis: `Recorder#flush` itself carries **no rescue** (`recorder.rb:16`); the isolation lives in the `Drain` skeleton and in `Fanout#guarded`, not at the contract seam.

---

## Net effect on FINDINGS.md

| Finding | Effect |
|---|---|
| **F15-SEC-01** | **keep `major`**, but change confidence **`high` → `medium`**, retarget the finding's lead argument from captured content to the `reason` attribute on the default policy, drop `recorder_drop_ledger.rb#DropLedger#validate!` as a claimed label-enforcement point, and name the operational cost (durable local `0600` journal + unreleased `.health.json` sidecar, with no redacting read path). |
| **F15-OBS-01** | keep `minor`, no change. |
| **F15-COR-01** | keep `minor`, no change; independently reproduced in the real class. |
| **F15-SCAL-01** | keep `minor`, no change. |
| **F15-SCAL-02** | keep `minor`; add that 2 000/2 000 saturated reserved-lane emits recorded with 0 drops and a 0.1 ms flush, so the throughput cost remains **unproven** rather than merely unmeasured. |
| **F15-OBS-02** | keep `minor`, no change. |
| **F15-INFO-01** | keep `info`/closed, no change. |
| **Row verdict F15** | **`IMPROVE` stands** — 0 critical, 1 major, 4 minor, 1 info is unchanged; only F15-SEC-01's confidence and its stated basis move. |
