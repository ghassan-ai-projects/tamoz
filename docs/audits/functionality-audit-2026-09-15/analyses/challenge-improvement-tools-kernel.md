# Independent challenge — F23-SEC-01 (critical), F23-COR-01/02/REL-01/MNT-01, F08-SEC-01 (critical), F08-REL-01, F17-COR-01, F17-B9-01

Challenger: independent adversarial challenger (read-only audit lane)
Date: 2026-09-15
Baseline: branch `audit-15-09`, commit `582ae55` (`git rev-parse HEAD` = `582ae5566de1ae073aea82b69bb2bbf444494d3b`), tree otherwise unmodified
Method: for each finding I re-read the cited source at the exact `file:line` rather than trusting the
report's quotation; ran an exhaustive production-caller sweep (`grep -rn` over `gems/ apps/ bin/ script/`
with `test/` excluded, then read every non-test hit); attacked severity against `BAR.md:70-78`; searched
for a missed guard or missed caller beyond the cited files; ran the named focused suites one file per
command; and reproduced or failed to reproduce each claim with a minimal probe under `/tmp/c15/` against
the real classes. No production file, test, config, gemspec, fixture or other doc was edited; all probes
live under `/tmp/c15/` and the repo contains zero scratch files.

Environment: `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`. Probes load the real
gems read-only via explicit `$LOAD_PATH` entries. No model or provider was called anywhere.

**Headline.** Both assigned criticals are real defects, but only one survives as `critical`. F08-SEC-01 is
**UPHELD** — the child genuinely inherits `TAMOZ_SIGNING_KEY`, and `SECURITY.md:34` states the opposite in
writing. F23-SEC-01's gate is exactly as weak as claimed, but the gem has **no production caller at all**
and the promotion it guards records nothing that is installed or activated, so the "unsafe action /
authority bypass" limb of the `critical` definition is not reachable at HEAD: **DEMOTED to `major`**.
F17-COR-01 is **DEMOTED to `info`** — the exploit the analyst asked for does not exist, and I found the
guard that closes it (`Tamoz::Core.deep_freeze` at record construction plus the graph checkpointer's own
freeze). F17-B9-01 is **DEMOTED to `minor`**, and I found a third copy of the lattice the analyst missed.

---

## F23-SEC-01

The promotion human gate is an unbound string; the approval policy data seam is not on the path —
report says **critical / high / open**.

### Source re-verified

Every citation is accurate. I re-read each line myself.

- `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/evaluation_report.rb:220` — the signature is
  literally `def assert_human_gate!(gate_classes:, evidence:)`. Confirmed by reflection in the probe:
  `parameters: [[:keyreq, :gate_classes], [:keyreq, :evidence]]`. There is no digest, actor, candidate or
  report parameter.
- `evaluation_report.rb:228-233` — the whole check is `text.start_with?(HUMAN_GATE_PREFIX) && text.length > HUMAN_GATE_PREFIX.length`.
  Confirmed.
- `evaluation_report.rb:50` — `HUMAN_GATE_PREFIX = "human:"`. Confirmed.
- `promotion.rb:51` — `EvaluationReport.assert_human_gate!(gate_classes:, evidence: human_gate_evidence)`,
  with `human_gate_evidence:` a bare keyword at `:42`. Confirmed.
- `promotion.rb:350` — the string is persisted verbatim as `human_gate_evidence:`. Confirmed.
- `candidate_proposal.rb:45-48` — the same prefix test, no digest. Confirmed.

The analyst's one **citation error** is trivial and does not affect the finding: `promotion.rb:42`'s
parameter is documented in-file as `human_gate_evidence:,  # "human:<actor>" approval artifact` — the
report quotes it correctly.

### Reachability — the crux

**There is no production caller.** This is the finding's defining fact and the report states it only in
its blind spots (`F23-agent-improvement.md:505`), not in the finding body where it belongs.

Sweep, all non-test hits read:

| Sweep | Result |
|---|---|
| `grep -rn "Promotion\.new\|Generator\.new\|CandidateLifecycle\.new\|CandidateProposal\.new" gems/ apps/ bin/ script/ test/` | `Promotion.new` appears at `test/improvement_candidate_test.rb:539` **only**; `Generator.new` at `test/…:26,292,303` **only** |
| `grep -rn "Improvement::" gems/tamoz-agent/lib/` | **zero hits** |
| `grep -rn "Promotion\b" gems/ apps/ bin/ script/` (non-test) | only `gems/tamoz-agent-improvement/README.md:17`, `monitor.rb:9` (a comment), `wisdom.rb:6` (a comment) |
| `grep -rn "CandidateLifecycle\|CandidateProposal" gems/tamoz-agent/lib/ gems/tamoz-agent-cli/lib/ apps/ bin/` | **zero hits** |
| `grep -rn "Improvement\|improvement" apps/ bin/ script/` | only `script/generate_requirements_manifest:99,276-279` (test-name strings) and three `script/benchmark_*` gem-name lists |

The one seemingly-promising hit is `gems/tamoz-agent/lib/tamoz/agent.rb:19` — `require "tamoz/agent_improvement"`.
I read its context (`:14-24`): it sits in an alphabetical block of nine sibling `require`s
(`agent_session`, `agent_memory`, `agent_healing`, `agent_improvement`, `agent_profile`, …) that exist so
`gems/tamoz-agent/lib/tamoz/agent.rb` names its whole dependency set. Nothing in the gem then uses it —
`grep -rn "Improvement::" gems/tamoz-agent/lib/` returns nothing. **The require is a manifest, not a call
site.** The gem is loaded and never invoked.

`script/benchmark_holdout:10`, `benchmark_run:10` and `benchmark_release:50` list the gem among modules to
exercise; they name it as a package, they do not call `Promotion#promote`. Notably, `F23-MNT-01` in this
same row answers the row's own question with **"the gem promotes nothing that is installed anywhere"**
(`F23-agent-improvement.md:178`, `:424`): the only write is a `Profile::Transition` row or an adoption-registry
entry, and `promote!` returns `'activated' => false` (`candidate_proposal.rb:66`). I re-verified that:
`promotion.rb:359` returns `"activated" => false`, and every promotion test asserts it
(`test/improvement_candidate_test.rb:625`). **The analyst's own MNT-01 finding states the promotion is inert.**

So the reachable-consequence chain is: no caller → no promotion is ever recorded in production → nothing is
activated, installed, or put in front of a model → no unsafe action, no authority bypass, no data loss.

### Severity

Against `BAR.md:70-73`, `critical` requires an **active defect or invariant/boundary violation that can
cause an unsafe action, authority bypass, data loss, false completion, broken durability/effect semantics,
or materially misleading evidence.** The defect is real and active *as code*; the *consequence* limb is not
satisfiable at HEAD because the seam has no production consumer and its product is inert by its own return
value.

I also checked the two escape hatches that could restore `critical`:

1. **Is there an independent upstream gate?** No — and this cuts the other way, not toward severity. The
   report's claim that the approval seam is absent is correct and I verified it exhaustively:
   `grep -rniE "improvement|heuristic|candidate|promotion" gems/tamoz-approval/` returns **zero matches**
   across `policy/base.yaml` and all five profiles (`auto/implement/plan/review/unattended.yaml`);
   `grep -rn "Approval" gems/tamoz-agent-improvement/` returns only `errors.rb:57`
   (`ApprovalDigestError`), a local `Approval = Data.define(...)` at `candidate_lifecycle.rb:16`, and a
   README line. The gem has **no reference to `Tamoz::Approval`**. So `assert_human_gate!` is the **only**
   gate on this path — there is no second gate to catch a forged string. That is what makes the *finding*
   correct; it does not make the *defect reachable*.
2. **Is the artifact bound to anything?** No. The probe shows the identical string `"human:operator-1"`
   passes the gate for two candidates with **different report seals** (`seal differs? true`). The report's
   strongest sub-claim is confirmed.

**Verdict: DEMOTED to `major`.** This is a real, source-grounded security gap at a named seam with a
trivial fix; it is not "active" in the BAR sense, because it can only bite after someone wires a caller.
The concrete operational cost today is **zero**; the cost the moment a caller lands is a promotion that
records an unverifiable `human_gate_evidence` string bound to nothing, which the durable audit trail
(`behavior_transition.rb:73`) then cannot distinguish from a typed prefix. `major` under `BAR.md:74-75`
("material security gap with real operational cost") is the honest grade; the recommendation is unchanged
and should still be taken before any caller lands.

### Guards

Searched beyond the cited files for anything upstream that binds the evidence. Found **none** — see the
approval sweep above. The adjacent `assert_not_self_promoting!` (`promotion.rb:240-262`) is genuinely
stronger (it refuses actor == generator/evaluator/candidate-id/candidate-digest and a report whose
`generator_principal` disagrees with the candidate's), but it compares the same caller-supplied
`String(actor)`, so it does not close the gap — as the report says at `:107`. I confirmed
`wisdom.rb:105-123` uses the same prefix convention for `wisdom_promotion`, so the convention is repo-wide
(a scope note, not a defence).

### Probe

`/tmp/c15/sec01_human.rb` — real `Tamoz::Agent::Improvement::EvaluationReport`, loaded read-only from the repo.

```
signature: [[:keyreq, :gate_classes], [:keyreq, :evidence]]
"human:anybody"                  -> ACCEPTED
"human:1"                        -> ACCEPTED
"human:x"                        -> ACCEPTED
"human:the_candidate_itself"     -> ACCEPTED
"human:"                         -> refused(Tamoz::Agent::Improvement::UngatedActivationError)
"human:operator-1"               -> ACCEPTED
seal differs for two candidates? true
gate passes for candidate A with 'human:operator-1': true
gate passes for candidate B with 'human:operator-1': true
```

**Reproduced exactly as the analyst reported, including the control** (`"human:"` and `"auto-approved"` are
refused, so the gate is not vacuous). The reproduction confirms the mechanism; the caller sweep is what
demotes it.

### Verdict

**DEMOTED — `major` (was `critical`).** The gate is exactly as unbound as claimed and is the only gate, but
the row's own companion finding establishes the promotion is inert and no production caller exists anywhere
in the tree; per `BAR.md:70-73` a `critical` needs a reachable unsafe action, and none is reachable at HEAD.

---

## F23-COR-01

A promotion can be recorded from a forged-but-correctly-sealed report produced inside this gem, with the
resolver supplied by the promoter — report says **major / high / open**.

### Source re-verified

All citations accurate. `evaluation_report.rb:59` does govern the module body, so `seal`,
`paired_task_digest`, `decide` and `assert_human_gate!` are all publicly callable `module_function`s.
`promotion.rb:209-227`'s `assert_evidence_resolves!` checks callable → Hash → seal equality, and
`promotion.rb:200-208` concedes in a comment that "the seal is a digest and not a keyed MAC … anyone able
to CONSTRUCT a report could also seal it". Confirmed verbatim.

### Reachability

Same caveat as F23-SEC-01 — no production caller and no activation. This caps the *consequence*, not the
*mechanism*.

### Severity

I reproduced the analyst's claim **in full, from scratch, with a control**, which is the strongest available
test of it. `major` is correct: the gap is the "trust a caller-supplied value" root shared with F23-SEC-01,
and the fix is one argument at an existing seam. It does not reach `critical` for the same reachability
reason as F23-SEC-01.

One correction to the analyst's framing: I had to **use** the public `paired_task_digest` to complete the
forgery. My first attempt used an invented `"sha256:forged-pair"` and was **refused**:
`assert_paired!` raised `EvaluatorTamperError: evaluation report paired_task_digest does not bind the
partition task sets`. That is a refutation of the *weaker* claim ("any hand-built report promotes") and a
confirmation of the *stronger* claim the analyst actually makes ("a report built from this gem's own public
API promotes"). The gate the analyst praised at `evaluation_report.rb:157-163` is real and did its job; it
is simply not a barrier to a caller who has the same public API. This strengthens the finding's precision
and does not change its grade.

### Guards

`assert_paired!` (`:136-164`) re-derives the pairing digest and refuses an identical dev/holdout set — a
real guard, and the reason the naive forgery fails. `assert_not_self_promoting!` and
`assert_provenance_binds!` both bind *values the promoter also supplies*, so they raise cost, not the bar.
`assert_evidence_resolves!` is the would-be guard and is defeated precisely because the resolver is a
parameter.

### Probe

`/tmp/c15/cor01_forge.rb` — real classes; an in-memory `BehaviorTransition` history; **no corpus, no
trajectory, no harness, no scorer**. The report body, the candidate and the eight-axis provenance are all
built from public values.

```
forged report verifies? true
forged decision: {"development_margin"=>4, "holdout_margin"=>3, "passed"=>true, "reasons"=>[]}
fabricated provenance complete? true
CONTROL resolver-returns-nil: refused (Tamoz::Agent::Improvement::EvaluatorTamperError)
!! POSITIVE: PROMOTED with forged report + promoter-supplied resolver: activated=false
   decision={"development_margin"=>4, "holdout_margin"=>3, "passed"=>true, "reasons"=>[]}
```

The **control** is the important half: a resolver that returns `nil` (simulating a real protected evaluator
partition the promoter cannot read) is correctly refused with the message "a candidate cannot supply its own
evaluation evidence". Only the promoter-supplied resolver that returns the promoter's own artifact passes.
Real evaluator data on the same corpus is `development_margin => 2, holdout_margin => 1`
(`test/improvement_candidate_test.rb:373-374`) — my forged report claims 4 and 3.

### Verdict

**UPHELD — `major`.** Reproduced end to end from public API only, with a control that proves the
resolution step is the only thing defeated and that it is defeated exactly when the promoter controls it.

---

## F23-COR-02

Rollback restores the pre-promotion epoch and never marks the heuristic epoch undone; the byte-identity
proof is relative to the rollback's own target — report says **major / high / open**.

### Source re-verified

- `promotion.rb:88-89` — `target_digest = current.rollback_target["snapshot_digest"]`. Confirmed.
- `transition_registry.rb:104` — `rollback_target: { 'behavior_version' => before, 'snapshot_digest' => control.active_snapshot_digest }`,
  i.e. the **prior** epoch by construction. Confirmed by reading the `record` body.
- `promotion.rb:133` — `"injection_digest" => self.class.injection_digest(snapshot)`, over the **restored**
  snapshot. Confirmed.
- `promotion.rb:142-161` — the assertion compares against digests the caller obtained from the rollback
  result. Confirmed: the comparison is target-relative.
- `behavior_transition.rb:22,40` — `STATUSES` declares `:rolled_back` and `Transition` carries
  `rolled_back_at`; `grep -rn "rolled_back" gems/` finds no writer outside the constant, the Data members,
  `candidate_lifecycle.rb:227`'s unrelated phase map, and `promotion.rb`'s own liveness filter. Confirmed —
  the analyst's "no writer" claim is correct.

### Reachability

Unchanged from F23-SEC-01: `Promotion#rollback` has no production caller. The served region is also
**correct** in the intended single-lane usage — the analyst concedes this at `:341` and I agree. The gap is
in the ledger, not in the bytes.

### Severity

`major` is defensible and I do not demote it, but the grade rests on the ledger claim, not on a wrong served
state: after a rollback the superseded heuristic row still reads `status: activated` / `rolled_back_at: nil`,
and "what is live" is derived from a `"rollback."` prefix scan on a *different* row
(`promotion.rb:306-314`) rather than from the transition's own declared terminal status. The operational
cost is an audit-trail that cannot answer "is this heuristic still live?" from the record that owns the
field — materially misleading evidence under `BAR.md:72`, but bounded to the record, not the served bytes.
`major` stands. No independent caller exists, so no further escalation is available.

### Guards

The byte-level proof itself is a genuine guard and better than the record-value comparison the doc-comment
warns about (`:136`, `:156-161`). `assert_forward!` (`:333-340`) plus the forward-only allocator
(`successor_version`, `:189-197`) is what makes both the rollback assertion and the audit claim pass while
the served region is pre-heuristic — the analyst's causal chain is right.

### Probe

I did not re-run the rollback probe: the claim is a source/ledger claim (which two digest values the
assertion compares against, and which status the undone row holds), and I verified both directly in source
rather than inferring them from a probe. The analyst's `/tmp/f23_probe_rollback_scope.rb` output
(`row status now: activated`) is consistent with `activate_row` being the only writer of `:activated`
(`transition_registry.rb:352-372`), which I re-read and confirm.

### Verdict

**UPHELD — `major`.** Source re-verified line by line; the undone row is never marked terminal and the
byte-identity proof is stated against the rollback's own output.

---

## F23-REL-01

A partially completed activation is not retried and is not rollback-able; the candidate is stranded in
`:verified` — report says **major / medium / open**.

### Source re-verified

- `candidate_lifecycle.rb:223-228` — `return :unknown if status == :unknown; return @phase unless status == :succeeded`.
  Confirmed: `:failed` falls through to `@phase` unchanged.
- `:128-132` — `rollback!` requires `require_phase!(:active, :rollback)`, and `:verified` fails
  `require_phase!` (`:177-181`). Confirmed.
- `effect_dispatcher.rb:179-203` — a raised `ToolError` is caught and routed to
  `complete_exceptional_attempt(..., status: :failed)`. Confirmed.
- `effects_journal.rb:114-118` and `effect_preparation.rb:158-159` — a non-`:succeeded` terminal status
  replays as itself. Confirmed: the retry cannot double-apply, which is why this is `major` and not
  `critical`. The analyst's self-limiting reasoning is correct and I uphold it.
- `candidate_lifecycle.rb:236-245` — `adoption_registry.activate(...)` runs **then**
  `@proposal.promote!(...)`, so a raise between them leaves the adoption registration with no transition.
  Confirmed by reading the lambda.

### Reachability

No production caller (same sweep as F23-SEC-01). This is explicitly the reason the analyst gives
`medium` confidence and did not escalate.

### Severity

`major` is correct and I do not demote it. The in-gem half — that `:failed` leaves the phase at `:verified`
and `rollback!` then refuses — is a directly readable, deterministic consequence of one method's branch
structure. The harm is a **stuck candidate, not a duplicate or unsafe effect**, and the analyst says so
plainly. That is honest grading; a stuck candidate is real operational cost under `BAR.md:74-75`, below the
`critical` bar. The `medium` confidence is right for the right reason: the durable journal half is read
from two implementations rather than executed.

### Guards

`:unknown` is handled correctly and deliberately (`:224` → `CandidateUnknownError` at `:177-181`), and
`test/agent_improvement_lifecycle_test.rb:49-64` pins it. The terminal-receipt immutability of a `:failed`
effect at both journals is the guard that keeps this from being worse — I re-read both maps and confirm the
analyst's reasoning.

### Probe

I did not re-run this probe: the claim reduces to "does `stage_result_phase(:activate, :failed)` return
`:verified`", which is a two-line branch I read directly (`candidate_lifecycle.rb:223-228`), and to the
journal's terminal-status mapping, which I read at both implementations. Under the "reproduce the analyst's
probe" instruction the honest statement is: **probe not re-run; source re-verified; the specific
`:failed`-falls-through branch is confirmed by reading, and the `:unknown` sibling that the report says is
handled correctly is confirmed by reading.** This is a weaker reproduction than I achieved for F23-SEC-01/
COR-01 and should be recorded as such.

### Verdict

**UPHELD — `major`, `medium`.** The owning branch is as cited and the harm is correctly self-limited to a
stuck candidate; the durable half remains read-not-run, matching the report's own confidence statement.

---

## F23-MNT-01

`limitations.md` states there is no skill self-improvement pipeline while this gem implements `scope: 'skill'`
end to end — report says **major / high / open** (documentation).

### Source re-verified

- `documentation/limitations.md:88-94` — "Skills are compiled from operator-configured directories into
  immutable, content-addressed snapshots … **There is no install, update, or self-improvement pipeline**:
  no quarantine staging, no provenance checks on a downloaded artifact, no atomic activation of a new
  digest." Read at `:85-96`. Confirmed verbatim.
- `README.md:42` — "`tamoz-agent-improvement` | Bounded self-improvement: candidate provenance, heuristic
  generator, paired evaluation reports, **human-gated promotion/rollback** |". Confirmed at `:40-44`.
- `candidate_proposal.rb:13` — `SCOPES = %w[profile skill config]`. Confirmed.
- `candidate_proposal.rb:66` — `{ 'transition' => transition, 'activated' => false, 'candidate_digest' => to_digest }.freeze`.
  Confirmed: the returned artifact is a `Profile::Transition` and `activated` is `false`.

### Reachability and severity

The analyst answers the row's question honestly and I confirm both halves: the *limitations* claim is true
about the executable artifact (nothing writes a skill tree to disk; `promote!` returns `activated: false`),
and the *README/design* claim is true only about the candidate record. Two documents describe two different
halves and neither says which. The reader consequence is real (a reader treats the boundary as closed while
the README advertises the pipeline).

`major` is defensible but it is the **weakest** of the four majors in this row, and the report itself
concedes the fix is one sentence with no code change (`:433`). I considered demoting to `minor` under
`BAR.md:76-77` ("bounded … documentation … debt with limited immediate impact"). I **uphold `major`** on one
ground only: `BAR.md:74-75` names "documentation gap with real operational cost", and this one is not
cosmetic — an operator who trusts `limitations.md:88-94` will not look for a candidate pipeline that the
sibling document advertises. The consequential half is that the *code-side bound* is safe: non-`profile`
scopes are refused any authority (`candidate_policy.rb:23-26`), which the analyst verified and which keeps
this out of `critical`.

### Guards

`candidate_policy.rb:23-26` refuses `authority` on a `skill` or `config` candidate — the de-facto bound that
makes the limitations claim safe for the executable artifact. Confirmed present.

### Probe

None needed; this is a documentation-contradiction finding and both texts are quoted above from source. The
test evidence gap the analyst names is real: `test/agent_improvement_lifecycle_test.rb:9-25` builds a
`scope: 'config'` proposal and no test exercises `scope: 'skill'` (verified by grep over `test/`).

### Verdict

**UPHELD — `major`** (documentation), with the note that it is the row's softest major and the coordinator
could reasonably re-route it to the docs owner rather than count it against the row.

---

## F08-SEC-01

The `run_check` child inherits operator credentials it does not name — report says **critical / high / open**.

### Source re-verified

- `check_runner.rb:13-15` — `ENV_PATTERN` is a `_`-delimited suffix alternation over
  `API_?KEYS?|ACCESS_?KEYS?|SECRET_?KEYS?|PRIVATE_?KEYS?|SESSION_?KEYS?|TOKENS?|SECRETS?|PASSWORD|PASSWD|CREDENTIALS?|PASSPHRASE`,
  and `ENV_NAMES` is a 13-name list of `AWS_*` plus eight provider `*_API_KEY`s. Confirmed verbatim.
- `:17-19` — `env.keys.each_with_object({}) { |name, redactions| redactions[name] = nil if credential_env?(name) }`.
  Confirmed: this is a **redaction list** building a hash whose *other* names are simply absent, and in
  Ruby's `spawn` an absent name is inherited.
- `:60` — `Open3.popen3(self.class.credential_free_env, *argv, chdir: toolbox.root.to_s, pgroup: true)`.
  Confirmed: no `unsetenv_others: true`.
- `:8` — the doc comment calls it "a credential-free environment". Confirmed: the code and its comment read
  as an allow-list while the implementation is a deny-list. The analyst's core observation is exact.

### The deciding question — where does the check command come from?

This is the trust trace the coordinator asked for, and it settles the finding: **the check command is
operator-authored profile data, but the child's environment is *not* the operator's deliberate grant.**

The command string's provenance, traced end to end:

1. `gems/tamoz-agent-profile/lib/tamoz/agent/profile/check_spec_validator.rb:25-169` — the strictest
   validator in the loader. Its own comment (`:8-15`) says "*This is the profile's execution surface, so it
   is the strictest validator in the loader*". It validates the name, the shape, argv element types, and
   `argv[0]`: `refuse_workspace_relative!` (`:121-128`) **refuses a relative path so repository content can
   never name the program**, and `refuse_wrapper!` (`:130-139`) refuses shells and inline-source
   interpreters. This is precisely the guard that keeps an *untrusted* source from supplying the command.
2. `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1204` — `checks: resolved.checks.transform_values { |check| check.fetch("argv") }`,
   plus `:1205` `check_safeties`. The values come from `resolved` — a resolved **profile document**.
3. `gems/tamoz-agent/lib/tamoz/agent/cli.rb:681` — `checks: profile.checks.transform_values { |check| check.fetch("argv") }`.
   Same provenance: the operator's profile file, loaded by the CLI.
4. The model's reach: `tool_argument_validator.rb:144-151` (cited by the F08 report at `:87`) accepts only
   `{"name": <configured>}` for `run_check`, so the model cannot supply a program or argv. The analyst
   verified this and I confirm the validator is the only entry.

**So the check program is trusted operator code.** By that reading, inheriting the operator's *environment*
is arguably intended — and the F08 report concedes exactly this at `:186`: "*If the coordinator rules that a
configured check is trusted operator code and inheriting the operator's environment is intentional, this
drops to `minor`/documentation*."

**But that reading is refuted by the repository's own written claim, three ways**, and that is what keeps
this `critical`:

- **`SECURITY.md:34`** states: "*`run_check` runs one operator-configured argv by name; the model chooses
  which check runs and can never alter its program, arguments **or environment**. Credential-shaped
  variables are stripped from every check subprocess.*" The code strips *pattern-matched* variables, not
  credential-shaped ones. `TAMOZ_SIGNING_KEY` is credential-shaped by any operator's reading and is not
  pattern-matched.
- **`check_runner.rb:8`** — the class comment says "a credential-free environment".
- **`test/agent_toolbox_test.rb:284-285`** — the test comment says "*a check's output is captured into
  prompts, streams, and the durable log, so the child must not inherit credential-shaped variables*", and
  then asserts only a name the pattern happens to cover.

The analyst's claim about the test is **exactly right**: `test/agent_toolbox_test.rb:286-304` uses
`TAMOZ_TEST_API_KEY` (which `credential_env?` returns `true` for — I verified in the probe), and
`test_credential_env_classification` (`:306-315`) asserts only the covered direction, using
`MY_SECRET_TOKEN` / `database_password` (both covered) and refuting `PATH` / `TAMOZ_CONFIG_HOME` /
`KEYBOARD_LAYOUT` (none of which is a credential). No test names a secret the pattern misses.

Where the analyst is **wrong** is narrower than they claim: they list `GH_TOKEN` as a leaked secret
(`:182`). It is **not** — `credential_env?("GH_TOKEN")` returns `true` (my probe), because `TOKENS?` matches
`_TOKEN` at the end. The leak class is "credentials whose name misses the pattern", and `GH_TOKEN` is a
counter-example that strengthens the deny-list's partial coverage; using it as an example weakens the
report. `NPM_TOKEN` likewise matches (`TOKENS?` covers the `_TOKEN` suffix) and is also not a leak. The
names that genuinely miss the pattern — verified in `/tmp/c15/envcheck.rb` — are `TAMOZ_SIGNING_KEY`,
`TAMOZ_SMTP_URL`, `MY_DSN` and `GH_PAT` (all `credential_env? == false`), plus base64 blobs in `TAMOZ_*`.
The analyst names several of these correctly, so the finding is sound; only the `GH_TOKEN` example is
misclassified, and correcting it does not change the severity.

### Severity

`critical` **stands**, on the `BAR.md:70-73` limb "can cause … authority bypass … or materially misleading
evidence": the child's stdout is captured into the check receipt, the model prompt, streams and the durable
log — which is the entire reason the guard exists — and the security model says in writing that it does not
happen. The two candidate downgrades both fail:

- *"Trusted operator code is entitled to the operator's environment"* — a check is a **verification command**
  (`run_check` runs a lint/test/build), not an operator shell. Nothing in the profile schema grants it an
  environment, and the report's recommendation (per-check `env` allow-list merged onto a minimal base with
  `unsetenv_others: true`) is the smallest change that makes the grant *deliberate*. The `tamoz-evals-runner`
  `SubprocessRunner` already does it correctly with an explicit `environment:` plus `unsetenv_others: true`
  (`subprocess_runner.rb:222-233`) — so the property is achievable at this seam and merely absent here.
- *"The program is trusted, so the env is fine"* — the trust argument is about the *program*, and the
  finding is about the *environment*, which the operator never chose and the docs claim is stripped.

Reachability is also **direct**: `Toolbox#initialize` (`toolbox.rb:71`) runs the sweep at action-capable
construction and `run_check` is dispatched by the session/worker paths (`worker_runtime.rb:1204`), so this
seam is on a live production path — unlike F23-SEC-01. That asymmetry is exactly why one critical is upheld
and the other is demoted.

### Guards

Searched for a missed guard: `grep -rn "credential_free_env\|ENV_PATTERN" gems/tamoz-tools/lib` → single
definition, single call site (the report says this; confirmed). `Toolbox` re-exports the classification
(`toolbox.rb:40-41`) purely as a convenience. There is no `unsetenv_others` anywhere in `tamoz-tools`
(`grep -rn "unsetenv_others" gems/tamoz-tools/` → no hits). **No guard exists.**

### Probe

`/tmp/c15/sec08_env.rb` — real `Tamoz::Tools::Toolbox` + `CheckRunner`, `--root` under `/tmp/c15/ws`.

```
TAMOZ_DATABASE_PASSWORD in child env hash? true value=nil     <- correctly unset
TAMOZ_SIGNING_KEY in child env hash?       false value=nil    <- ABSENT, therefore inherited
credential_env?(TAMOZ_SIGNING_KEY) = false
credential_env?(GH_TOKEN)          = true
credential_env?(TAMOZ_TEST_API_KEY)= true
--- child ACTUALLY saw (values masked) ---
  TAMOZ_SIGNING_KEY=<15 chars>
  UNRELATED_MARKER=<12 chars>
reproduced leak: true
```

The child is `/usr/bin/env` run **through the real `Toolbox#execute("run_check", ...)`**, so the observed
environment is the genuine spawn environment, not a hand-built hash. **Reproduced exactly.** The control is
in the same output: `TAMOZ_DATABASE_PASSWORD` is correctly nil-ed (pattern-matched via `PASSWORD`), which
proves the redaction mechanism works and that the failure is the deny-list's coverage, not a broken spawn.

### Verdict

**UPHELD — `critical`.** Reproduced against the real classes through the real dispatch path; the seam is on
a live production path (`worker_runtime.rb:1204`); no guard exists; and `SECURITY.md:34` plus the code and
test comments state the opposite in writing, which is materially misleading evidence about a secret-exposure
control. The trust trace confirms the *program* is operator-authored and legitimately trusted, but the
*environment* is neither a deliberate grant nor what the repository documents.

---

## F08-REL-01

The staging sweep deletes user files that match the reserved name shape — report says **major / high / open**.

### Source re-verified

- `staging_reaper.rb:13` — `PATTERN` matches `\A\.tamoz-(?:create-)?[A-Za-z0-9_.-]+\.tmp\z`. Confirmed;
  my probe confirmed both the victim name and a real `Tempfile` stage name match it.
- `:62` — `stat.file? && PATTERN.match?(path.basename.to_s) && stat.uid == Process.uid && now - stat.mtime >= older_than`.
  Confirmed: type, name shape, uid and age are the **only** identity rules. There is no provenance marker.
- `:29` — `File.unlink`. Confirmed.
- `toolbox.rb:71` — runs automatically at action-capable construction. Confirmed.
- `documentation/limitations.md:213-215` — read at `:212-215`: "*A workspace crash can leave a **private**
  `.tamoz-*.tmp` staging file. The next action-capable session sweeps files older than 60 seconds; the delay
  exists so a concurrently publishing session is never disturbed.*" The word is **"private"**, and the
  documented narrowing is **only the 60-second delay** — the doc does not claim name-shape is sufficient
  provenance, but it does call the file private, which is the claim the reaper cannot enforce.

### Severity — the question the coordinator asked

I took the upward case seriously, because `BAR.md:70-73` names **data loss** as a `critical` limb. It does
not reach it, for four reasons I verified:

1. **The blast radius is a dotfile with a `.tmp` suffix.** The pattern requires a leading `.tamoz-` and a
   trailing `.tmp`, so ordinary operator files (`notes.md`, `config.yaml`, `data.csv`) are untouchable.
2. **Age and uid both must match.** A file the operator is actively using is safe; a file owned by another
   user is safe.
3. **The deletion is visible, not silent.** `reap` returns the relative paths and `Toolbox#reaped_staging`
   exposes them (`staging_reaper.rb:23-36`, `toolbox.rb:71`). My probe printed `reaped_staging=[".tamoz-notes.tmp"]`.
   A silent destructive action would be worse; this one is reported.
4. **The name space is the system's own reserved prefix**, deliberately introduced by `patch_operations.rb:70`
   (`Tempfile.new(['.tamoz-', '.tmp'], dirname)`) and `creation_operations.rb:53` (`.tamoz-create-*.tmp`).
   `.tamoz-` is the project's namespace; a user file wearing it is already colliding with the system.

Against that, the honest debit is that **age + uid + name-shape is not provenance**, the pre-existing test
comment overstates what is proven (`test/toolbox_staging_reaper_test.rb:72-97` plants only *near-misses* of
the pattern, never a *match that is not ours*), and `limitations.md` calls the file "private" without the
system having any way to know that. That is a real destructive action in the operator's workspace with a
documentation claim it cannot support: **`major`** under `BAR.md:74-75`, not `critical`. The name shape is
*a* reservation, but a convention the system does not enforce against writers, so deleting on it is a
judgment call rather than a proof.

### Guards

The reaper is genuinely careful and I confirmed each rule by reading `:23-65`: `lstat` (never follows a
symlink), regular-file-only, uid match, age floor, `.git`/`vendor`/`node_modules` prunes, and a 200-file cap.
The gap is precisely that none of these is a provenance test — as the report says at `:196`.

### Probe

`/tmp/c15/rel08_reaper.rb` — real `StagingReaper` via `Toolbox.new(root:, allow_changes: true, checks: {})`,
`--root` under `/tmp/c15/ws2`.

```
before: exists=true mode=755 age=600s
reaped_staging=[".tamoz-notes.tmp"]
after:  exists=false  DELETED=true
control real staging name matches PATTERN? true
victim name matches PATTERN? true
```

**Reproduced exactly**, with a control showing a real `Tempfile`-shaped name also matches — i.e. the
pattern cannot distinguish the two, which is the mechanism.

### Verdict

**UPHELD — `major`.** Reproduced; the deletion is real and the identity test is provably not provenance. It
stays below `critical` because the blast radius is a reserved-prefix dotfile, the action is reported, and
uid+age bound it — but `limitations.md:213` should stop calling the file "private" until provenance is
enforced, as the report recommends.

---

## F17-COR-01

The approval records a plan digest that is never verified against the plan it approves — report says
**major / medium / open**, with an explicit instruction: "*If that attempt fails, downgrade to `info` and
keep the recommendation as a one-line hardening*" (`:483`).

### Source re-verified

Every citation is accurate:

- `session_steps.rb:173` — `'plan_digest' => accepted.fetch('plan_digest')` in the approval descriptor.
  Confirmed.
- `session_steps.rb:188` — `plan_digest: accepted.fetch('plan_digest')` in the approval record. Confirmed.
- `session_effects.rb:284` — `plan_digest: accepted.fetch('plan_digest')` in the effect intent. Confirmed.
- `session_steps.rb:126-131` — `journaled_verdict` matches on **`approval_id` only**:
  `entry['approval_id'] == "#{accepted.fetch('plan_id')}.#{step.fetch('id')}"`. Confirmed exactly.
- `session_evidence.rb:20-28` — `find_intent` matches on `plan_id` + `step_id`, **not** `plan_digest`.
  Confirmed.
- The repo-wide grep for `plan_digest` in `gems/*/lib` returns **writes and provenance projections only** —
  30 hits in the session/kernel/graph/memory/cli gems, none a comparison or a `verify_*` against a
  recomputed digest. Confirmed: the analyst's "the absence is proven" claim holds.

### The attempt the analyst asked for — and it fails

The report's own disposition turns on this: *"it needs an independent challenge that attempts to mutate
`accepted_plan` between the gate and execution."* I attempted it and **it cannot be done.** Two independent
guards close it, both of which the analyst missed:

1. **`Tamoz::Core.deep_freeze` at record construction.**
   `session_plan_outcomes.rb:127-137` builds the accepted-plan record through
   `SessionRecords.build('accepted_plan', …)`, and `session_records.rb:377` ends `build` with
   `load!(Tamoz::Core.deep_freeze(record), kind:)`. The record, its nested `plan`, its `steps` array and
   every step hash are **frozen at the moment they are constructed**.
2. **The graph checkpointer freezes values independently.** `memory_checkpointer.rb:140-158`'s `freeze_value`
   recursively dups-and-freezes strings, arrays and hashes, and raises `ConfigurationError` for any
   non-frozen non-primitive. So even a record that arrived unfrozen could not enter the state channel mutable.

Probe `/tmp/c15/f17cor01_freeze.rb`:

```
frozen? true nested plan frozen? true steps frozen? true
mutation refused: FrozenError: can't modify frozen Hash: {"id"=>"s1", "tool"=>"read_file", ...}
digest mutation refused: FrozenError
```

The mutation the finding needs — changing `plan.steps[i].tool` after acceptance, or rewriting
`plan_digest` to match a mutated plan — raises `FrozenError`.

I also confirmed the write surface: `grep -rn "accepted_plan" gems/*/lib` shows the channel is written only
by `session_plan_outcomes.rb:48` and `:121` (both at plan acceptance), read everywhere else, and reset only
via `session_context_controls.rb:30`'s `RESETTABLE_NIL_CHANNELS` (which nils it, not mutates it). No writer
mutates `accepted_plan['plan']` in place. The analyst's guess at `:480` — "I found no writer that mutates
`accepted_plan['plan']` in place" — is correct, and the reason is stronger than they knew: it is structurally
impossible.

### Severity

The analyst's own instruction applies: **the exploit attempt failed, so downgrade to `info`.** Under
`BAR.md:77-78`, `info` is "a verified design fact, limitation, or question that is useful for later work but
is not itself a defect". That is exactly what this is: `plan_digest` is recorded provenance with no
comparison site, and the state channel is immutable by construction, so there is no gap to exploit. The
one-line hardening at `session_steps.rb:126-131` remains worth doing as defence in depth — if a future
writer ever introduces a mutable path, the comparison becomes load-bearing — but it is not a defect today.
I also confirm the analyst's *positive* half, which is what makes the downgrade safe: the approval **is**
bound to the exact patch three ways (`arguments_digest` at `session_effects.rb:287`, `preview_digest` at
`session_steps.rb:147`, and `expected_sha256` re-verified against the live workspace at
`session_effects.rb:88-98`), so a mutated patch cannot ride an old approval regardless.

### Guards

`Tamoz::Core.deep_freeze` (`session_records.rb:377`) and `MemoryCheckpointer#freeze_value`
(`memory_checkpointer.rb:140-158`) — **missed by the analyst**, and they are what settles the finding. The
report's blind spot at `:555-559` worries that "`SessionRecords` schema validation is structure-only … not a
digest check" and that it "did not read the checker in full". It read the schema lines but not the
`build` method five lines below the schema table, where `deep_freeze` is applied. That is the one
evidential gap that would have settled the finding without a challenge.

### Verdict

**DEMOTED — `info` (was `major`).** The exploit path is not merely unproven, it is closed by
`deep_freeze` at record construction and by the checkpointer's independent freeze; per the report's own
instruction and `BAR.md:77-78` this is a verified design fact, not a defect. The recommendation survives as a
one-line hardening.

---

## F17-B9-01

`EpisodeNodes::RISK_RANK` is a Ruby-literal risk-class table duplicating `IntentCatalog::RISK_CLASSES`,
against AGENTS.md's B9 rule — report says **major / high / open**.

### Source re-verified

- `episode_nodes.rb:31` — `RISK_RANK = {"R0" => 0, "R1" => 1, "R2" => 2, "R3" => 3, "R4" => 4}.freeze`.
  Confirmed verbatim.
- `episode_nodes.rb:260-263` — `RISK_RANK.fetch(risk_class, 99) > RISK_RANK.fetch(ceiling, 0)`. Confirmed.
  Probe output: `fetch('R5', 99) = 99`, i.e. an unranked class is treated as above every ceiling — **fails
  closed**, exactly as the analyst says.
- `intent_catalog.rb:26` — `RISK_CLASSES = %w[R0 R1 R2 R3 R4].freeze`. Confirmed. My probe confirms the two
  agree today: `agree? true`.
- `episode_nodes.rb:27-28` — the comment reads "*the risk lattice is the wire enum's semantics*". Confirmed.

### (a) Is `RISK_RANK` domain content or framework taxonomy?

**It is framework taxonomy — the wire enum's closed ordering — and AGENTS.md's B9 paragraph does not reach
it.** Two pieces of evidence settle this:

1. **The fixtures do not carry a lattice; they carry a mapping.** The B9-governed data is
   `test/fixtures/domains/*.json`'s `intent_types` object, which is `{"install_watch_condition": "R0",
   "create_maintenance_ticket": "R1", …}` — a per-domain *intent → risk* assignment, which the loader turns
   into `"risk_class" => risk` (`domain_loader.rb:62`) and the catalog validates against `RISK_CLASSES`
   (`intent_catalog.rb:102`). The **ordering** of `R0..R4` appears in **no fixture**: I grepped every domain
   JSON and the only occurrences of `R0`–`R4` outside `intent_types` are inside the operator *prompt prose*
   (`cold-chain.json:13` — "`install_watch_condition (R0, observe only)`") and one `risk_ceiling` value.
   A lattice that no domain file authors is not domain data.
2. **The wire protocol fixes it.** `documentation/benchmark/BENCHMARK_PROTOCOL.json:39` carries
   `"risk_ceiling": "R2"` as a protocol field, and AGENTS.md says the protocol SHA is a deliberately pinned
   cross-language artifact — the Go side fixes the same vocabulary. R0–R4 is a two-implementation wire enum,
   exactly the category the analyst's counter-argument describes (and the same category as an error-severity
   enum, which B9 plainly does not reach).

The analyst reached this conclusion too but recorded the finding as `major` anyway, on the strength of the
duplication. I think that is the wrong call, for the reason in (b).

### (b) If the duplication is real but the failure mode is closed — `major` or `minor`?

**`minor`, and I found a third copy that changes the picture.**

I ran the sweep for missed copies and found one the analyst missed:
`gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb:23` declares
`RISK_RANK = { "R0" => 0, "R1" => 1, "R2" => 2, "R3" => 3, "R4" => 4 }.freeze` — the same literal, with the
same "wire enum's semantics, not a domain table" comment (`:21-22`), consumed at `:207-209` as
`RISK_RANK.fetch(declared_risk) <= RISK_RANK.fetch(@envelope.risk_ceiling.to_s.upcase)`. **So there are
three copies of the lattice in Ruby, not two.** This matters in two directions:

- It *strengthens* the duplication half of the finding: the report's proposed fix ("derive the lattice from
  `IntentCatalog`") would leave `tamoz-stream`'s copy untouched, and `tamoz-stream` deliberately does not
  depend on `tamoz-agent-kernel` (the `WATCH_TYPE` alias comment at `intent_catalog.rb:29-30` says the
  constant was homed in `tamoz-core` *precisely so `tamoz-stream` resolves it without an agent dependency
  edge*). The duplication is a consequence of the dependency direction, not an oversight, and "one
  definition" is not achievable at `IntentCatalog` without adding the edge the repo avoided. The report's
  recommendation is therefore **not** the smallest credible fix, and its premise is incomplete.
- It *weakens* the severity: three independent copies that have agreed across two languages, with the
  kernel copy failing closed (default 99) and the stream copy failing closed differently (a bare `fetch`
  raises `KeyError`), is a maintainability/drift risk, not an active defect.

Under `BAR.md:76-77` — "bounded maintainability, naming, documentation, testability, or local observability
debt with limited immediate impact" — this is a `minor`. The duplication is real and should be recorded;
the absence of a test binding the copies is the actual defect, and it is one assertion, not a redesign.
The analyst's own qualifier ("I record it as `major` rather than `critical` precisely because I could not
show a reachable unsafe action") is the right reasoning applied one notch too high.

### (c) F17-B9-02 (`INTENT_WATCH_TYPE`) and whether the two should be one finding

I checked the companion finding the same way. `tamoz-core/lib/tamoz/core.rb:28` holds
`INTENT_WATCH_TYPE = "install_watch_condition"`, aliased at `intent_catalog.rb:29`, enforced as a required
catalog member at `intent_catalog.rb:189-191`, and used as the R0 watch fallback at `episode_nodes.rb:216-231`.

This is **the same category as B9-01 and reads as a single finding**: both are wire-protocol constants that
the B9 rule does not govern (the *watch properties* and *presets* — the actual B9-governed content — live in
the domain JSON), both were homed in `tamoz-core` for the same cross-gem dependency reason (the alias comment
states it explicitly for `WATCH_TYPE`), and both fail closed (a renamed watch type raises
`intent_catalog/missing_watch_type`; an unranked risk class sorts above every ceiling). Splitting them into
`major` + `minor` overstates the first and understates the shared root. The honest record is **one `minor`
finding**: "two wire-protocol constants are restated in Ruby and no test binds either to the domain data",
with the note that the stream copy makes B9-01's recommendation infeasible as written.

Note also that the analyst's own `minor` for B9-02 rests on the observation that
`gems/tamoz-agent-kernel/lib` contains **zero** intent type names (verified: their grep). B9-01's
`RISK_RANK` is the same kind of constant as B9-02's `INTENT_WATCH_TYPE`; grading them `major` and `minor`
respectively is internally inconsistent.

### Guards

There is **no test** binding `RISK_RANK` to `RISK_CLASSES`. `test/agent_intent_catalog_test.rb` (14 runs /
19 assertions / 0F — I ran it) does not assert the table. `test/stream_episode_reconsider_test.rb`, which
the analyst names as the consuming suite, was **not run by them**; the missing assertion is the finding.

### Probe

`/tmp/c15/b9_probe.rb`:

```
EpisodeNodes::RISK_RANK = {"R0"=>0, "R1"=>1, "R2"=>2, "R3"=>3, "R4"=>4}
IntentCatalog::RISK_CLASSES = ["R0", "R1", "R2", "R3", "R4"]
agree? true
fetch('R5', 99) = 99  (fails CLOSED: above every ceiling)
```

**Confirms the analyst's "fails closed" claim**, which is the basis for not calling it `critical`.

### Verdict

**DEMOTED — `minor` (was `major`); merge with F17-B9-02 into one finding.** The literal is real and
duplicated (three times, not twice), but it is a wire-protocol enum outside B9's domain-content rule and its
failure mode is closed in both consumers; the actual debt is a missing agreement test, and the report's
"derive from `IntentCatalog`" recommendation is infeasible without the dependency edge `tamoz-stream`
deliberately avoids.

---

## Net effect on FINDINGS.md

| ID | Report | Challenge | Net |
|---|---|---|---|
| F23-SEC-01 | critical / high / open | DEMOTED | **change severity to `major`** — gate is as unbound as claimed and is the only gate, but no production caller exists and the promotion is inert (`activated => false`), so the `critical` consequence limb is unreachable |
| F23-COR-01 | major / high / open | UPHELD | **keep** — forged report + fabricated provenance promote end to end from public API, with a control proving the resolution step is the only thing defeated |
| F23-COR-02 | major / high / open | UPHELD | **keep** — `rollback_target.snapshot_digest` is the prior epoch by construction and nothing writes `:rolled_back`; the ledger, not the served bytes, is wrong |
| F23-REL-01 | major / medium / open | UPHELD | **keep** — `stage_result_phase` maps `:failed` to the unchanged `:verified` and `rollback!` then refuses; harm correctly self-limited to a stuck candidate |
| F23-MNT-01 | major / high / open | UPHELD | **keep** (softest major in the row; coordinator may re-route to the docs owner) — `limitations.md:88-94` and `README.md:42` describe different halves and neither says which |
| F08-SEC-01 | critical / high / open | UPHELD | **keep** — reproduced through the real dispatch path; the check *program* is trusted operator data but the *environment* is not a deliberate grant, and `SECURITY.md:34` claims the opposite in writing |
| F08-REL-01 | major / high / open | UPHELD | **keep** — stale mode-0755 `.tamoz-notes.tmp` is deleted; below `critical` because the blast radius is a reserved-prefix dotfile and `reaped_staging` reports it |
| F17-COR-01 | major / medium / open | DEMOTED | **change severity to `info`** — the mutation attempt the report asked for is impossible: `Tamoz::Core.deep_freeze` at `session_records.rb:377` and the checkpointer's `freeze_value` close the state channel |
| F17-B9-01 | major / high / open | DEMOTED | **change severity to `minor` and merge with F17-B9-02** — a wire-protocol enum outside B9's domain rule, failing closed in both consumers; three Ruby copies, not two, and the stream copy makes the report's fix infeasible |

**Category tallies after challenge.** F23: 0 critical, 4 major, 2 minor, 2 info (was 1/4/2/2) — the row
stays **IMPROVE**, now on the four majors rather than on a critical. F08: 1 critical, 1 major, 3 minor,
0 info — **unchanged**. F17: 0 critical, 2 major, 3 minor, 3 info (was 0/3/2/2) — the row stays **IMPROVE**
on F17-REL-01 and the new-merged B9 item alone would not carry it.

Two probe results are worth carrying into the synthesis independently of any finding:
**(1)** the naive forged evaluation report is refused by `assert_paired!` — the pairing gate is real and
catches a hand-built report that does not re-derive `paired_task_digest`, which is a point in the gem's
favour the report already makes; and **(2)** `TAMOZ_DATABASE_PASSWORD` is correctly stripped while
`TAMOZ_SIGNING_KEY` is not, which locates F08-SEC-01 precisely in the deny-list's *coverage* rather than in
the redaction mechanism.
