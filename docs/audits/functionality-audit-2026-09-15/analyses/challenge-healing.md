# Independent challenge — F20-REL-01 (critical), F20-SEC-01 (major)

Challenger: independent challenger lane (adversarial) · Date: 2026-09-15 · Baseline: branch
`audit-15-09`, HEAD `582ae55` · Method: re-read every cited `file:line` in the primary source,
exhaustive caller sweep across `gems/ apps/ bin/ script/ lib/`, focused-suite re-run, and
re-execution of the analyst's probes plus three control probes written for this challenge.
Read-only: no production file, test, config, gemspec, fixture, or doc other than this one was
touched; all probes live under `/tmp`.

Liveness log: `/tmp/tamoz-agents/challenge_healing.log`.

## F20-REL-01

### Source re-verified

Every citation in the analyst's source-evidence field was opened and checked against the code.
**All of them are accurate. No citation error to report.** Detail:

| Claim | Verified at | Result |
|---|---|---|
| `Remediation.run` accepts `attempt:` and never validates it | `remediation.rb:63` (keyword default `attempt: 1`), `remediation.rb:67` calls only `validate_records!` | Confirmed. `validate_records!` (`remediation.rb:78-85`) checks `record.is_a?(FailureRecord)` and `rule.is_a?(HealingRule)` and nothing else. `build_session` (`remediation.rb:88-107`) forwards `attempt:` untouched. |
| `@attempt` appears four times in `Session`, never compared | `session.rb:19, 46, 84, 258` | Confirmed exactly. `19` → `AttemptEvidence`; `46` → unused on that line (the value flows through `@attempt` from the ivar capture at `session.rb:16`); `84` → `PreflightCheck.new(attempt: @attempt)`; `258` → `EscalationPayload.new(attempt: @attempt)`. `grep -n "@attempt" session.rb` returns those four and **zero** comparison operators. |
| the "budget" is a static rule field compared to a caller-supplied value | `preflight.rb:118-124` | Confirmed. `within_attempt_scope_magnitude_cost_time` is `context.attempt <= budgets.fetch("max_attempts") && …`. The left operand is the caller's `attempt:`; the right is the rule's immutable field. |
| `max_attempts` is capped at `EffectDispatcher::MAX_ATTEMPTS` | `rule.rb:510-520` | Confirmed. `validate_attempt_budget` raises `HealingPolicyError` when `max_attempts > EffectDispatcher::MAX_ATTEMPTS`. |
| circuit increments a bare counter, opens at threshold, resets on success | `seams.rb:56-63`, `65-73` | Confirmed. `record_failure` does `@failures += 1`, appends `{"kind" =>, "context" =>}` — **no fingerprint key** — then `@state = @failures >= @threshold ? :open : :degraded`. `record_success` zeroes the counter when not already open. |
| default session builds a fresh in-memory circuit per run | `remediation.rb:93` | Confirmed: `circuit ||= Seams::MemoryCircuitStore.new(scope: "rule:#{rule.rule_id}")`. |
| the implemented bound lives one gem over | `session_nodes.rb:26`, `session_evidence.rb:128-151` | Confirmed — see Reachability. |

One nuance the report states but does not emphasise, and which the challenge makes load-bearing:
`session.rb:46` is *not* a use of `@attempt` at all — it is the `classification.mutating?` branch
line. The count "four" is right, but only three are real reads. This does not weaken the finding
(the conclusion "zero comparisons" is unchanged); it is recorded so the coordinator does not
propagate a slightly imprecise count into a rollup.

### Reachability — the crux

**Verdict on the crux: `Tamoz::Agent::Healing::Remediation.run` has NO production caller. The
analyst is correct, and I could not refute it despite trying.**

The sweep, and every hit read:

```
# A — Remediation / remediation, everything outside the gem
grep -rn "Remediation\b\|Remediation\.run\|healing_remediation\|remediation" gems/ apps/ bin/ script/ lib/ \
  | grep -v "gems/tamoz-agent-healing/"

# B — Agent::Healing or Healing::
grep -rn "Agent::Healing\|Healing::" gems/ apps/ bin/ script/ | grep -v "gems/tamoz-agent-healing/"

# C — RuleRegistry outside the gem
grep -rn "RuleRegistry" gems/ apps/ bin/ script/ test/ | grep -v "gems/tamoz-agent-healing/"

# D — lowercase 'healing' in every production .rb
grep -rn "healing" gems/ apps/ bin/ script/ lib/ --include=*.rb | grep -v "gems/tamoz-agent-healing/" | grep -v "^gems/tamoz-evals/suites/"
```

Hits and their disposition:

- **Sweep A** — zero production hits. The hits are: two `tamoz-evals` `*.case.json` fixtures
  (`m0/golden/08_healing-unknown-effect.case.json`, `agent/smoke/20_self_healing_observation.case.json`),
  four `script/generate_requirements_manifest` entries that are *test-name strings*
  (`"test/healing_remediation_test.rb#…"`), one `script/generate_m0_fixtures` string, and two
  `gems/tamoz-core/lib/tamoz/circuit/registry.rb:217,224` hits that are the **circuit scope label**
  `consecutive_remediation_failures` and a comment — a *name*, not a call site. None invokes the
  gem.
- **Sweep B** — exactly **one** hit, and it is a **comment**:
  `gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb:41` reads
  "(`Healing::Seams::MemoryCircuitStore` and `Tamoz::Mcp::MemoryCircuitStore` contract, DR-2 §8)".
  It documents that the durable store satisfies the *interface*; it does not reference the constant
  in code. This is the closest thing in the repo to a production link and it is inert.
- **Sweep C** — only `test/` files (`test/support/agent_smoke_corpus.rb:2286` and five sites in
  `test/healing_failure_contract_test.rb`). No production constructor.
- **Sweep D** — three real production references, **none of which calls `Remediation.run`**:
  1. `gems/tamoz-agent/lib/tamoz/agent.rb:18` — `require "tamoz/agent_healing"`. This *loads* the
     gem (so the constants exist at runtime) but does not call it.
  2. `gems/tamoz-agent-session/lib/tamoz/agent/session_records.rb:99-106` — the schema entry
     `"healing_pin" => HASH`, persisted via `Healing.pin_for`. This is the *pin* a session stores
     so a rule set can be identified later; it is evidence plumbing, not protocol invocation.
  3. `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/errors.rb:5` and
     `gems/tamoz-core/lib/tamoz/circuit/record.rb:308` — comments using "healing" as an English
     word.

**The production path that actually bounds repairs** is confirmed to be the one the analyst named,
and it lives entirely in `tamoz-agent-session`:

- `gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb:26` —
  `MAX_REPAIR_ATTEMPTS = 2`, surfaced as the `max_repair_attempts:` option
  (`session_options.rb:18`, validated to `0..10` at `session_options.rb:103-105`).
- `gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb:128-151` — `bounded_repair`
  performs **identity-keyed** repetition detection
  (`state.fetch(:seen_failure_signatures).include?(signature)` →
  `terminal_reason: 'repeated_failure'`) *and* a counter bound
  (`repair_attempt >= @configuration.max_repair_attempts` → `'repair_attempts_exhausted'`).
- That loop is driven by `failed_check` (`session_evidence.rb:124-126`) from the ordinary
  tool-repair graph; `grep -rn "Healing" gems/tamoz-agent-session/lib/` returns **only** the
  `healing_pin` schema comment block. The two verticals do not touch.

So `tamoz-agent-healing` is **a library surface with no production caller** — precisely the shape
the analyst independently records as `F20-MNT-01`. The unbounded-repetition defect therefore cannot
cause an unsafe action **in the shipped system today**: nothing in the shipped system runs the
loop.

### Guards searched

I hunted specifically for a bound the analyst might have missed. Commands run and what each hit
showed:

```
grep -rn "MAX_ATTEMPTS\|max_attempts\|attempt" gems/tamoz-agent-healing/lib
grep -rn "Circuit::Record\|FailureEvent\|fingerprint" gems/tamoz-agent-healing/lib
grep -rn "consecutive_remediation_failures\|remediation" gems/tamoz-core/lib gems/tamoz-sqlite/lib
grep -rn "MAX_REPAIR_ATTEMPTS\|seen_failure_signatures\|repeated_failure" gems/tamoz-agent-session/lib
```

Read every hit. Four candidate guards exist; **none bounds the healing protocol**:

1. **`EffectDispatcher::MAX_ATTEMPTS` (= 3)** — reached only through
   `rule.rb:510-520`, and only as a *ceiling on the rule's declared budget*. It never counts
   healing cycles. Not a bound on the protocol.
2. **The effect journal's dedupe** — real, and see below; it is a dedup, not a bound.
3. **`gems/tamoz-core/lib/tamoz/circuit/registry.rb:217`**,
   `Condition.new(id: "consecutive_remediation_failures", kind: "consecutive", threshold: 3)` —
   this looked promising and I chased it hard. It is a **registry declaration** of the
   `remediation` circuit scope's condition set. It is consumed only by
   `gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb`, whose `record_failure`
   (`circuit_store.rb:119-132`) builds
   `Tamoz::Circuit::Record::FailureEvent.new(kind:, context_digest: …)` — **it never passes
   `fingerprint:`**, leaving that `Data` member `nil` (`record.rb:34-38`). So even the durable
   store, the H3 replacement the seam docstring points at, records failures **without** the
   identity the analyst's recommendation depends on. This *strengthens* rather than refutes
   F20-REL-01: the fix the analyst recommends is not merely unwired, the durable adapter does not
   populate the field it would need. Worth recording as a refinement to the recommendation.
4. **`Tamoz::Circuit::Record::FailureEvent`'s `fingerprint` member** — defined
   (`record.rb:34`) but, per (3), unused by both the healing gem (`grep` in the gem returns zero
   hits) and the SQLite adapter. Dead capacity, not an active guard.

**The journal-dedupe interaction, reproduced and correctly scoped.** The analyst claims the
effective budget is 1 via `reused=true`. I reproduced it and it is **true but narrower than
stated**. The identity key is `(trace, operation, rule version, call_index, form)`. In probe6 the
caller holds `original_trace_id` and `call_index` fixed across cycles, so cycles 2+ hit a terminal
`reused=true` receipt. **A caller that varies only `original_trace_id` or `call_index` — exactly
what a real retry loop does — loses the dedupe immediately.** Control D below shows the second
cycle taking a *different* code path entirely. So dedupe does **not** prevent unsafe repetition;
it prevents it only for a caller that is already not retrying in the ordinary sense. The analyst's
severity reasoning survives, but "the effective repair budget is 1, uncounted and unrecorded"
should be qualified: it is 1 **only under a fixed trace and call index**, and it is a property of
the *journal*, not of the healing protocol.

### Probes

Environment: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`;
run from the repo root with `-Itest`.

**Analyst's probe6 re-run** — `/tmp/f20_probe6.rb`, `timeout 150 ruby -Itest /tmp/f20_probe6.rb`:

```
cycle 1: state=recovered recovered=true attempt=1 effect_attempt_number=1 reused=false
cycle 2: state=recovered recovered=true attempt=2 effect_attempt_number=1 reused=true
cycle 3: state=escalated recovered=false attempt=3 effect_attempt_number= reused=
cycle 4: state=escalated recovered=false attempt=4 effect_attempt_number= reused=
cycle 5: state=escalated recovered=false attempt=5 effect_attempt_number= reused=
TOTAL perform invocations across 5 cycles for ONE failure fingerprint: 1
3 runs, 0 assertions, 0 failures, 0 errors, 0 skips
```

Matches the analyst's report exactly. Note cycles 3-5 are `escalated`, not `circuit_open` — the
loop here is stopped by nothing in the protocol.

**Analyst's probe8 re-run** — `/tmp/f20_probe8.rb`:

```
cycle 1: state=escalated circuit_open?=false failures=1 escalations_total=1 performed=true
cycle 2: state=escalated circuit_open?=true  failures=2 escalations_total=2 performed=true
cycle 3: state=circuit_open circuit_open?=true failures=2 escalations_total=3 performed=false
cycle 4: state=circuit_open circuit_open?=true failures=2 escalations_total=4 performed=false
circuit conditions: ["verification_failed", "verification_failed"]
escalation ids: ["escalation.1", "escalation.2", "escalation.3", "escalation.4"]
distinct fingerprints in those records: 1
1 runs, 0 assertions, 0 failures, 0 errors, 0 skips
```

Matches. The circuit stops the loop **only** when the same `circuit:` object is passed in, and it
reaches `open?` **after** cycle 2 has already performed its mutation. Four escalation records are
written for one fingerprint with colliding positional ids — corroborating the analyst's
`F20-OBS-01`.

**Controls (written for this challenge).**

*Control C — `/tmp/f20_probe9c.rb`*: same circuit, same rule, same fixed
`original_trace_id`/`original_effect_id`, but a **new `FailureRecord` per cycle**
(`execution_id: "exec.#{n}"`, varying `observed_at_ms`):

```
CONTROL-C cycle 1: exec=exec.1 fp=sha256:7ca state=escalated performed=true  reused=false circuit_open?=false
CONTROL-C cycle 2: exec=exec.2 fp=sha256:7ca state=escalated performed=true  reused=true  circuit_open?=true
CONTROL-C cycle 3: exec=exec.3 fp=sha256:7ca state=circuit_open performed=false reused= circuit_open?=true
CONTROL-C TOTAL performs across 3 cycles (new record identity, fixed trace): 1
CONTROL-C distinct fingerprints: 1
```

Two things this settles: (a) the analyst's probe1 claim is independently **confirmed** — the
fingerprint is byte-identical (`sha256:7ca…`) across three different `execution_id` and
`observed_at_ms` values, so identity *is* available to key a repetition bound on; (b) the dedupe
regime is reproduced a second time. The circuit still fires only after a mutation.

*Control D — `/tmp/f20_probe9e.rb`*: same fingerprint, but the caller varies
`original_trace_id: "trace.#{n}"` and `call_index: n` — what a genuine retry loop supplies:

```
CONTROL-D cycle 1: trace=trace.1 => Outcome state=escalated performed=true reused=false
CONTROL-D cycle 2: trace=trace.2 => RAW ARRAY (not Outcome); first=Hash keys=["state", "failure_format_version", "failure_fingerprint", "rule_id"]
CONTROL-D cycle 3: trace=trace.3 => Outcome state=escalated performed=false reused=
CONTROL-D cycle 4: trace=trace.4 => Outcome state=escalated performed=false reused=
CONTROL-D TOTAL performs (one fingerprint, changing trace+call_index): 2
CONTROL-D escalations: 3
```

**Control D is the most important result in this challenge, and it is a defect the analyst did
not find.** Two consequences:

1. It confirms the dedupe is defeated by a changing trace: performs go from 1 (control C) to 2
   (control D) for **one** fingerprint, with no counter consulted. The repetition the
   README (`README.md:58-62`) promises to stop "rather than looping" is not stopped by any bound
   in this gem; only the incidental circuit-open at cycle 3 halts it.
2. On cycle 2, `Remediation.run` **returns a raw `Array` instead of an `Outcome`.** I traced this
   to its exact source and it is a separate live defect, not a probe artifact:
   - `AttemptEvidence#record` (`attempt_evidence.rb:27-31`) ends in `@transitions << …`, so it
     returns the **mutated transitions Array** — truthy.
   - `Session#handle_ambiguous_effect`'s `when :failed` branch (`session.rb:182-184`) calls
     `transition(:uncertain, evidence: { 'status' => 'failed' })` as its **last expression**, so
     the method returns that truthy Array.
   - `Session#call` line 50 is `return ambiguous_terminal if ambiguous_terminal` — truthy wins.
   - Therefore `verify_or_compensate` (`session.rb:52`) is **never reached** on a `:failed`
     effect: no `Oracle.verify`, no `CompensationFlow`, no `validate_terminal_state!`, no
     escalation payload. `Remediation.run` hands its caller a bare transitions list.
   I confirmed the dispatcher is not at fault: wrapping
   `EffectDispatcher.run` (`/tmp/f20_probe13.rb`) shows it returns a proper
   `EffectDispatcher::Outcome` (`status=failed reused=false`) on cycle 2. And instrumenting
   `CompensationFlow#call` (`/tmp/f20_probe14.rb`) shows it is invoked on cycle 1 and **not
   invoked at all** on cycle 2. This is a **false-completion / broken-effect-semantics** defect
   sitting directly on the F20-REL-01 code path. It is not currently reachable in production
   (same missing caller), but it is a distinct record from F20-REL-01 and should be raised
   separately rather than folded into it.

### Severity

BAR mapping, applied to what is actually reachable:

- `critical` requires an **active** defect or invariant/boundary violation that **can cause** an
  unsafe action, authority bypass, data loss, false completion, broken durability/effect
  semantics, or materially misleading evidence.
- `major` is a material correctness/reliability/scalability gap **with real operational cost**.

The unbounded-repetition behavior is a **real, executed, source-grounded gap** — the protocol
genuinely has no repetition bound, and the only bound in the repository lives in a different gem
that this vertical never calls. But the word that decides severity is **"active"**. The defect
cannot cause an unsafe action in the shipped system because **nothing in the shipped system calls
`Remediation.run`**. The unsafe action requires an H3/H4 caller that does not exist; the analyst
states this plainly in the Blind spots section and I verified it exhaustively. Grading an unwired
library surface as `critical` on the strength of a hypothetical future caller is exactly what the
BAR's "active" qualifier excludes.

I therefore assign **`major`** — while noting that this is a *demotion on reachability alone*, and
that the same missing caller is the **only** thing holding it below `critical`. If H3 wires a
caller that passes a caller-controlled `attempt:`, this becomes `critical` immediately and
unchanged.

I also record that control D's raw-`Array` escape, had it a caller, would independently be
**`critical`** on the "false completion / broken effect semantics" clause — verification and
compensation are silently skipped on a failed effect and the caller receives an evidence array
where an `Outcome` is contracted. It deserves its own ID.

### Verdict + reason

**DEMOTED — `critical` → `major`.** The source citations are all correct and the probes reproduce
exactly, so the defect is real and the analyst's evidence is trustworthy. But the crux resolves
against reachability: exhaustive sweeps A-D find **no production caller** for
`Remediation.run` anywhere outside `test/`, so the unbounded loop cannot cause an unsafe action in
the shipped system today. Under the BAR's "active defect" requirement that is a materially
expensive gap with real cost when wired — `major`, not `critical`. Confidence stays **high** for
the behavior and **high** for the absence of a caller. Two refinements the coordinator should
carry: (i) the "effective budget of 1" holds only under a fixed `original_trace_id`/`call_index`
and is a journal property, not a healing bound; (ii) the durable H3 replacement
(`Sqlite::CircuitStore#record_failure`, `circuit_store.rb:119-132`) does **not** pass
`FailureEvent#fingerprint`, so the analyst's recommended fix needs that adapter populated too, not
just a comparison added in `Session`.

## F20-SEC-01

### Source re-verified

| Claim | Verified at | Result |
|---|---|---|
| the human gate is a string prefix on a caller-supplied value | `rule_registry.rb:164-178` | Confirmed verbatim: `unless approval.is_a?(String) && approval.start_with?("human:")` → `SelfModificationError`. |
| `actor:` and `approval:` are ordinary keyword strings; `actor:` is recorded, not trusted | `rule_registry.rb:79`, `rule_registry.rb:74-78` | Confirmed. The docstring says "`actor:` is RECORDED, not TRUSTED: the in-band guard fires first and is independent of it." |
| `write_lifecycle_mode` has no actor/human check | `rule_registry.rb:100-116` | Confirmed. It calls `Scope.refuse_in_band!` and `assert_promotion_authorizes!` only. There is **no** `approval` parameter at all — so the analyst's note that it lacks a human check is right, though the reason is that it is gated by the *promotion record digest* instead. |
| this gem never reaches the approval seam | `gems/tamoz-approval/policy/base.yaml` + `engine.rb` | Confirmed. `grep -rn "approval\|Approval" gems/tamoz-agent-healing/lib` returns four hits, all in `rule_registry.rb`/`rule.rb`, none requiring `tamoz-approval`. |

The analyst's `rule_registry.rb:164-178` citation is correct. One correction to the *report's*
framing: the analyst writes that `write_lifecycle_mode` has "**no** human/`tamoz-evals` actor check
at all, only the in-band refusal and the promotion-record digest binding". That is accurate as
written, but the phrase "no actor check" could be misread as a missing guard rather than a
**different** guard. `write_lifecycle_mode` is protected by a content gate
(`assert_promotion_authorizes!`, `rule_registry.rb:180-189`: the promotion record must be a Hash
and `promotion["contract_digest"] == current.contract_digest`) plus `verify_lifecycle_backing!`
(`rule_registry.rb:119-130`) which fails closed at load. So it is weaker than a resolved approval
decision but is not unguarded. This nuance does not change the finding.

### Reachability — the crux

Settled by the same exhaustive sweep as above. `RuleRegistry` has **zero production callers**:
sweep C returns only `test/support/agent_smoke_corpus.rb:2286` and five sites in
`test/healing_failure_contract_test.rb`. There is no constructor outside `test/`. The registry is
never instantiated in `gems/`, `apps/`, `bin/`, `script/`, or `lib/`.

The approval seam that *is* authoritative is confirmed to be the combination of
`gems/tamoz-approval/policy/*.yaml` (base + digest-pinned profiles) and
`gems/tamoz-approval/lib/tamoz/approval/engine.rb` (`Engine#decide`). This gem references neither.
So the analyst's structural point stands: the `"human:"` prefix is a **second, unaudited verdict
source** for the same question the policy engine is supposed to answer, and it is inconsistent
with `AGENTS.md`'s "Approval policy is data too … Never hardcode a verdict, an approval constant,
or a bypass flag elsewhere."

There is, however, a genuine mitigation the analyst's own Domain-data check already identified and
which I verified independently at `rule_registry.rb:83-88`: `assert_reviewed_diff!` is reached
**only** when `changed_self_protected_fields` is non-empty, i.e. only for a real self-protected
delta, and it additionally requires `reviewed_diff` to name **exactly** the changed fields
(`rule_registry.rb:165-170`). An amend with no `approval:` raises. So the guard is not a bare
rubber stamp; it is a fail-closed shape gate that is weaker than a resolved decision.

### Guards searched

```
grep -rn "approval\|Approval" gems/tamoz-agent-healing/lib
grep -rn "human:" gems/ apps/ bin/ script/ --include=*.rb | grep -v gems/tamoz-agent-healing
grep -rn "Engine#decide\|Approval::Engine\|approval" gems/tamoz-agent-healing/lib/tamoz/agent/healing/rule.rb
```

- No call reaches `tamoz-approval`. The gate is self-contained.
- `"human:"` appears as an **owner-identity convention** elsewhere (`healing_rule`'s fixture
  `owner: "human:owner"`, `test/healing_fixtures.rb:52`), which suggests the prefix is borrowed
  from the owner-naming vocabulary rather than minted as an approval primitive — a plausible
  origin for the weakness, and worth naming in the five-whys chain.
- `PromotionGate` (`promotion_gate.rb`) is a pure predicate module and does not consult approvals
  either; it is not a mitigating guard here.

### Probes

`/tmp/f20_probe3.rb` re-run — the analyst's probe needed an explicit multi-gem load path
(`/tmp/f20_paths.rb`, mirroring `test/test_helper.rb:14-21`); the file as written does not run
under a bare `ruby -Itest`. That is a tooling nit in the analyst's probe, not a defect in the
finding. Exact output of the relevant lines:

```
with diff but non-human approval: Tamoz::Agent::Healing::SelfModificationError
amend allowed with human approval -> version 2, old still 1
in-band amend: Tamoz::Agent::Healing::SelfModificationError
in-band lifecycle: Tamoz::Agent::Healing::SelfPromotionError
out-of-band canary promotion: Tamoz::Agent::Healing::SelfPromotionError: the promotion record is not digest-bound to rule rule.imm version 2
active rule without promotion: Tamoz::Agent::Healing::SelfPromotionError
```

The accepted amend is called with `actor: "evil", reviewed_diff: ["budgets"], approval: "human:ops"`
— exactly the analyst's claim, at `rule_registry.rb:173`. **Reproduced: a caller-supplied
`"human:ops"` string satisfies the human gate regardless of the `actor:` value.** The other
output lines confirm the guards that *do* hold: non-human approval is refused, the in-band amend is
refused, and an unbacked lifecycle mode is refused at load. So the finding is precisely scoped —
one gate is weaker, the surrounding invariant-34 guards are real.

### Severity

The behavior is a genuine authority-contract weakness: a self-describing string stands in for a
resolved approval decision, and the repository's own `AGENTS.md` rule says the verdict belongs in
policy data. That is a real material gap with real cost when H4 wires the promotion lifecycle.

But it is **not an active authority bypass**: `RuleRegistry` has no production caller, no
production code can supply `actor: "evil"`, and reaching the seam already requires code inside the
trusted runtime. Grading it `critical` would fail the BAR's "active" test for the same reason
F20-REL-01 fails it.

I therefore keep the analyst's **`major`** — but for a reason the analyst states only in the
confidence column, not in the severity: the severity is carried by the **contradiction with a
standing repo rule** (`AGENTS.md`: approval policy is data; never hardcode a verdict elsewhere)
and by the fact that the seam is *designed to be the authority gate* for a self-protected rule
amendment. That is a material contract/ownership gap with operational cost — squarely `major`. It
is not `minor`, because the gate is the only thing standing between a caller and the edit of a
mutation-capable rule's self-protected fields, and it does not consult the owner of that decision.
I explicitly **reject** downgrading to `minor`/`info`: the analyst's own instinct to hedge toward
"contract gap rather than active bypass" describes the *impact* confidence, not the severity class.

### Verdict + reason

**UPHELD at `major`** (reachability-conditional like F20-REL-01, but the BAR class is unchanged).
Reproduced: `actor: "evil"` with `approval: "human:ops"` amends a mutation-capable rule's
self-protected `budgets` field. With no production caller the impact is conditional, which is why
`major` and not `critical` — but the gate is a second, unaudited verdict source for exactly the
question `gems/tamoz-approval` owns, contradicting a standing repo rule, so `major` is right and
`minor` would understate it. Confidence: **high** for behavior (executed), **medium** for impact
(no caller today).

## Relation to CF04-REL-01

**The analyst's "shared-shape, NOT duplicate" call is CORRECT. Confirmed — do not merge, and do
not index twice.**

Reading `analyses/failed-effect-resolution-replay.md` (the CF04 record) against F20-REL-01:

| | CF04-REL-01 | F20-REL-01 |
|---|---|---|
| Owning seam | `tamoz-agent-kernel` `EffectDispatcher#resolve_decision` / `terminal_attempt` — **status-specific terminal receipt selection** | `tamoz-agent-healing` `Remediation::Session` + `Seams::MemoryCircuitStore` — **no repetition counter or identity-keyed repeat detection** |
| Defect | a durable **failed** head replays using a historical **succeeded** attempt, so the replayed receipt reports `status=:failed` with `error=nil` (`effect_dispatcher.rb:91-101`, `280-283`, `162-173`) | a caller can re-enter the remediation protocol indefinitely because nothing counts attempts and the circuit is identity-blind |
| Trigger | idempotent effect, expired attempt, late success committing over a failed attempt, operator resolves the reconcile head `:failed` | any caller passing `attempt: 1` (or a fresh trace/call_index) on every cycle |
| Fix location | `EffectDispatcher#resolve_decision`'s `:failed` branch must read the **current** attempt's error | `Session` must compare an accumulated per-fingerprint count against `rule.budgets["max_attempts"]` |
| Shared trait | **only** the abstract proposition "the effect/retry layer's semantics are load-bearing and under-guarded" | same abstract proposition |

They share a *theme*, not a mechanism, a file, a value, or a remedy. Both are genuinely distinct
records. Note also that the two interact without overlapping: CF04-REL-01 corrupts what a replayed
failed receipt *says*; F20-REL-01 governs how many times the protocol may *run*. A fix to one does
not fix the other.

One addition the coordinator should record: the raw-`Array` escape I found in control D is a
**third** distinct defect on this surface (`Session#handle_ambiguous_effect` returning
`attempt_evidence.rb:28`'s truthy Array through `session.rb:50`, skipping
`verify_or_compensate`). It is *not* CF04-REL-01 (which is a journal-replay receipt-selection bug
in the kernel) and *not* F20-REL-01 (which is the missing bound). It needs its own ID — proposed
`F20-REL-02` — because it causes false completion and broken effect semantics on the `:failed`
path, and would be `critical` the moment a caller exists.

## Net effect on FINDINGS.md

- **F20-REL-01** — change severity to **`major`** (was `critical`). Keep open and confirmed;
  confidence high. Reason: exhaustive caller sweep proves `Remediation.run` has no production
  caller, so the unbounded loop is not an *active* defect under the BAR. Add the two refinements
  (dedupe holds only under a fixed trace/call_index; `Sqlite::CircuitStore#record_failure` does
  not populate `FailureEvent#fingerprint`).
- **F20-SEC-01** — **keep** at `major`. Reachability-conditional, but the BAR class is right: a
  second, unaudited verdict source for the approval question contradicts `AGENTS.md`'s
  approval-policy-is-data rule.
- **F20-REL-02** (new, not in the analyst report) — **add** as a new finding, proposed severity
  **`major`** today / `critical` when wired: `Remediation.run` returns a raw transitions `Array`
  instead of an `Outcome` whenever a remediation effect resolves `:failed`, skipping verification,
  compensation, terminal-state validation, and escalation. Owning seam
  `Session#handle_ambiguous_effect` (`session.rb:182-184`) via `AttemptEvidence#record`
  (`attempt_evidence.rb:27-31`). Evidence: `/tmp/f20_probe9e.rb`, `/tmp/f20_probe13.rb`,
  `/tmp/f20_probe14.rb`. Recommend re-running the F20 analyst lane before the row closes.
- **CF04-REL-01** — **no change**; confirmed a genuinely distinct seam. Do not merge with
  F20-REL-01.
- **F20-MNT-01 / F20-OBS-01 / F20-COR-01** — outside this challenge's assignment; not re-graded.
  Note only that this challenge independently corroborates F20-MNT-01's "no production caller"
  fact, which is now the load-bearing reason for F20-REL-01's demotion.

### Test pass counts (re-run, one file per command, `timeout 150`)

| Command | Runs | Assertions | Failures/Errors |
|---|---|---|---|
| `ruby -Itest test/healing_failure_contract_test.rb` | 35 | 264 | 0 / 0 |
| `ruby -Itest test/healing_remediation_test.rb` | 13 | 74 | 0 / 0 |
| `ruby -Itest test/healing_matrix_test.rb` | 4 | 44 | 0 / 0 |
| `ruby -Itest test/agent_repair_evaluation_test.rb` | 8 | 55 | 0 / 0 |
| `ruby -Itest test/agent_diagnosis_catalog_test.rb` | 15 | 53 | 0 / 0 |
| `ruby -Itest test/agent_worker_failure_reason_test.rb` | 6 | 14 | 0 / 0 |

All six match the analyst's counts exactly. **What they do not prove:** none of these suites
drives `attempt:` past 1, none asserts a repetition bound, and — critically for F20-REL-02 — none
exercises a remediation effect resolving to `:failed` through `Remediation.run` (grep confirms zero
such scenario in `test/healing_remediation_test.rb`). Their green state is therefore consistent
with both F20-REL-01 and F20-REL-02 being live; green here is evidence of coverage *gaps*, not of
correctness on these paths.
