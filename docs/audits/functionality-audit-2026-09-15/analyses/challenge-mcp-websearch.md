# Independent challenge — F09-SEC-02 (critical), F09-SEC-01/COR-01, F10-SEC-01/03/04

Challenger: independent adversarial reviewer (separate agent from both analysts).
Date: 2026-09-15.
Baseline commit: `582ae55` on `audit-15-09` (`git rev-parse --short HEAD` verified at start; working
tree clean apart from the untracked audit package).
Method: re-read every cited `file:line` in the source rather than trusting the reports; traced each
reachability chain to its production callers with `grep` over `gems/`, `script/`, `apps/`, `bin/`;
ran the named focused suites one file per command (`ruby -Itest test/<file>.rb`, `timeout 150`); and
wrote six read-only `/tmp` probes (`/tmp/f09probe/`) against the real classes. **No production code,
test, config, gemspec, fixture, or other doc was edited; nothing was committed; no real LLM, no real
MCP server from an untrusted source, and no live network call was made** (every probe injected a
resolver/connector spy or used the repo's own `script/mcp_test_server` fixture over stdio).

Prior-challenger consistency: I read `analyses/challenge-profile-authority.md` first and apply its
CF05-SEC-01 ruling explicitly in the F10-SEC-03 section below.

## F09-SEC-02

### Source re-verified

Read in full, not trusted from the report:

- `gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:362-375` — **exact**. The `MCP::Client::InputRequiredError`
  rescue returns `interrupt_or_deny(descriptor, error, effect_key:, headless:, url_policy:)`, which is the
  path that yields `Outcome#status = :interrupt` with a well-formed descriptor. The descriptor is genuinely
  well-formed: `:42` declares `Outcome` as `Data.define(:status, :observation, :interrupt, :denial, :effect_key)`,
  and `:43` documents the three states including `:interrupt (elicitation)`. **The report's claim that the gem
  builds the right value is correct.**
- `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:229-232` (`mcp_outcome?`) — **exact**;
  it duck-types on `status`/`observation`/`interrupt`/`denial`, so a real `Outcome` satisfies it.
- `session_effects.rb:246-251` (`mcp_payload`) — **exact**. `when :denied, :interrupt` is a single branch
  raising `ToolError, "MCP capability did not complete: #{safe_mcp_reason(reason)}"`. The descriptor is
  flattened to a string by `safe_mcp_reason` (`:253-256`).
- `session_effects.rb:392-401` (`mcp_entry`) and `:337-342` (`mcp_planning_surface`) — **exact**.
- `mcp_source_builder.rb:117-121` — **exact**: the executor returns `Tamoz::Mcp::Invocation.call(...)`
  unchanged, so the `Outcome` really does arrive at `result_payload`.
- `invocation.rb:108-124` (`reissue`) — **exact**, and its caller set is confirmed below.

### Reachability

The chain is fully production-reachable and needs no test machinery:

1. Operator enables an MCP server whose tool returns `input_required` (MRTR/SEP-2322 elicitation).
2. `SessionSteps#step_execute` → `SessionEffects#dispatch` (`session_effects.rb:75-86`) →
   `EffectDispatcher.run { execute_dispatch }` → `Capabilities#execute` → `McpDispatcher#execute` →
   `McpCapabilitySource#execute` → the executor lambda → `Invocation.call`.
3. `Invocation` returns `Outcome#status = :interrupt` with the §7 descriptor.
4. `execute_dispatch` (`:180-184`) calls `result_payload(result)` → `mcp_outcome?` is true → `mcp_payload`
   → the `:denied, :interrupt` branch raises `ToolError`.
5. `EffectDispatcher#execute_outcome` (`effect_dispatcher.rb:185-193`) rescues `Tamoz::Tools::ToolError`
   and records the attempt `status: :failed` with `"repairable" => error.repairable?` (`:256`).

**The descriptor never enters `view.interrupts`.** I verified the interrupt surface that *should* have
received it is real and live for other kinds: `session.rb:367` (`interrupts: snapshot.interrupts`),
`session_context_controls.rb:282-320`, `cli_rendering.rb:196-201` (`render_show_interrupts`),
`cli.rb:472,494`, `worker.rb:454-455` (`resolve_approval_asks`/`answers_for`), and
`session_status_projection.rb:82,100`. So the defect is not "there is no interrupt machinery"; it is
that this one kind never reaches the machinery that exists.

**No other `:interrupt` consumer.** `grep -rn ":interrupt\|status == :interrupt\|interrupts" gems/*/lib`
confirms the report: the only other `case` arm over an MCP-shaped outcome is
`governed_browser_source.rb:180` (`when :interrupt then [adapter_reason(raw), nil]`), and
`grep -rn "GovernedBrowserSource" gems/ script/ apps/ bin/ test/` returns **only** the class file, a
README line, `public_api_test.rb:55`, and `agent_phase4_capability_test.rb` — **it is not wired into
`CapabilityBinding`**, so it is test-only and cannot consume the MCP interrupt. `Invocation.reissue`
has **zero production callers**: `grep -rn "\.reissue\|reissue(" gems/ script/ apps/ bin/ test/` returns
only its definition, `public_api_test.rb:273`, and three test files. The report is exact.

### The scorecard-evidence claim

This was the coordinator's priority item. **The claim is TRUE and I verified it end to end.**

- `test/support/agent_smoke_corpus.rb:1483-1510` (`mcp_elicitation_proof`) builds a descriptor with
  `Tamoz::Mcp::Invocation.descriptor_for(entry, snapshot:)`, constructs a `Tamoz::Mcp::Supervisor`
  directly, and calls **`Tamoz::Mcp::Invocation.call(descriptor, {}, snapshot:, supervisor:)`** — twice
  (once attended, once `headless: true`). It asserts `outcome.status == :interrupt` and the descriptor's
  fields. **It never constructs a `Session`, a `SessionEffects`, or a `CapabilityBinding`.** The session
  is bypassed entirely.
- That boolean becomes the proof `"elicitation_not_fabricated"` (`:1435`), which feeds
  `"mcp_elicitation_interrupts" => proofs.fetch("elicitation_not_fabricated") ? 1 : 0` (`:1323`).
- `test/agent_scorecard_test.rb:242` asserts `assert_equal 1, mcp_case.fetch("mcp_elicitation_interrupts")`.
- The same block is additionally required for the case's `oracle_success` (`:1301`).

So **the scorecard's `mcp_elicitation_interrupts` counter is incremented by a direct call to the gem's
`Invocation.call`**, and the counter is named as though it measured the agent surfacing an elicitation to
an operator. It reports the gem, not the agent. The analyst's strongest claim is **verified**.

I add one datum the report did not have: this same proof is a **hard gate on the case's `oracle_success`**
(`:1301`), so the scorecard cannot go green on the MCP case unless this gem-level proof passes — the
misleading counter is load-bearing, not decorative.

### Severity

I attacked the `critical` grade on the analyst's own stated consequence and **the analyst's livelock
claim does not hold**. This is the report's decisive error.

The report says the collapsed elicitation produces a failure that "the step is retried through the repair
loop with the same arguments, and the same elicitation recurs until the repair budget is exhausted — a
livelock." That is false at the cited seam. The bare `Tamoz::Core::ToolError` raised at
`session_effects.rb:248` has `def repairable? = false` (`gems/tamoz-core/lib/tamoz/core/tool_error.rb:24-25`;
`Tamoz::Agent::ToolError` is a rebinding of the same class object — `tamoz-agent.rb:36-43`). The only
ToolError subclass that is repairable is `ToolArgumentError` (`:38-39`), which this raise site does not use.
Consequently `SessionEvidence#repairable_outcome?` (`session_evidence.rb:88-89`, which tests
`error['repairable'] == true`) returns **false**, and `SessionSteps#failed_update`
(`session_steps.rb:230-232`) takes the `raise ToolError, evidence.tool_error_message(outcome)` arm —
**terminal**. There is no repair loop, no repeated re-ask, and no unbounded livelock. Probe p2 confirms
the predicate directly.

So the reachable consequence is narrower than claimed: **the run stops** with an unhelpful
"MCP capability did not complete: {…}" message instead of the server's question. The honest operational
costs are:

1. **False completion / broken stated semantics** — `documentation/design/mcp.md` promises an elicitation
   is "bound to the originating call, persisted as an interrupt, and rendered with the configured server
   identity." None of that happens. A designed, documented capability is unreachable in production.
2. **Materially misleading evidence** — verified above, and it is worse than the report framed it: a
   scorecard counter named `mcp_elicitation_interrupts` is incremented by a gem-level direct call, and it
   gates the case oracle.
3. **An operator cannot answer a question the server asked**, and `Invocation.reissue` — the merge-and-
   re-issue path — is dead code in production.

### Guards

`grep -rn ":interrupt\|interrupts" gems/*/lib` (all hits read): every `view.interrupts` consumer is an
*approval* consumer built from `snapshot.interrupts`; none inspects an MCP `Outcome`. There is no
secondary guard that recovers the descriptor. **No missed guard.** I also checked for a wrapper that might
catch the descriptor under a different name — none exists.

### Probe

Two probes, both read-only, under `/tmp/f09probe/`.

**p1 (`p1_collapse.rb`)** — builds real `Invocation::Outcome` values (all three statuses) and drives them
through the **real private `SessionEffects#result_payload`**:

```
succeeded -> RETURNED {"output"=>"ok", "source_id"=>"test-server", "provenance"=>"remote_untrusted", ...}
denied    -> RAISED Tamoz::ToolError: MCP capability did not complete: {"consent"=>false, "reason"=>"headless"}
interrupt -> RAISED Tamoz::ToolError: MCP capability did not complete: {"kind"=>"mcp_elicitation", "server_id"=>"test-server", "capability"=>"mcp:te...
mcp_outcome?(:interrupt)=true
interrupt_descriptor_lost=true
```

**I reproduced the collapse.** `:denied` and `:interrupt` are indistinguishable at the consumer.

**p2 (`p2_repair.rb`)** — the severity probe:

```
raised_class=Tamoz::Core::ToolError
repairable?=false
SessionEvidence.repairable_outcome?=false
session_steps.rb:232 -> raise ToolError (TERMINAL, session ends)
control_ToolArgumentError_repairable?=true
```

**This refutes the report's livelock consequence.** A probe that fails to reproduce a claimed consequence
is a first-class result, and this one does.

### Verdict + reason

**UPHELD as `critical`, but on corrected reasoning — the report's stated livelock consequence is REFUTED.**

I keep `critical` and reject the demotion, because the BAR's `critical` band is met on two independent
clauses that do **not** depend on the livelock story, and one of them I verified more strongly than the
analyst did:

1. **"materially misleading evidence"** — the scorecard counter is verified to report the gem while the
   harness and counter names imply the agent, and it gates the case oracle. That is the audit's own
   evaluation evidence asserting something untrue, which is exactly the BAR's wording.
2. **"broken durability/effect semantics" + "false completion"** — a documented interrupt contract is
   silently converted into a terminal tool failure; the server's question is destroyed, and the only
   merge-and-re-issue path (`reissue`) has no production caller. The design doc and `P10_MCP_PLAN.md:210`
   both promise the durable-interrupt shape.

Why I did not demote to `major` on the corrected (terminal, not livelock) consequence: a `major` would be
right if the only harm were "an elicitation fails." But the harm is that **the repository's own evidence
artifact misreports agent capability**, and the audit is being conducted partly on that artifact. The
livelock claim should be struck from the report; the `critical` grade should stand on the misleading-evidence
and broken-contract grounds. The analyst's own recommendation (make `:interrupt` terminal *and
operator-visible*, routed through `Tamoz.interrupt`, then drive answers through `reissue`) is unchanged and
remains the smallest credible fix; note that "make it terminal" is **already the de-facto behavior**, so the
real fix is operator visibility plus wiring `reissue`, not loop-breaking.

## F09-SEC-01

### Source re-verified

- `catalog.rb:197-202` (`bounded_description`) — **exact**: `BoundedText.bound(value, config.budgets.max_description_bytes)`.
- `session_effects.rb:392-401` (`mcp_entry`) — **exact**: returns `[name, prompt_safe(description)]`, the raw
  server description, with no provenance marker.
- `session_effects.rb:337-342` (`mcp_planning_surface`) — **exact**.
- `deliberation.rb:104-108` (`merge_tool_surfaces`) — **exact**: `local.merge(mcp)` merges remote and local
  descriptions into one map of identical shape; `:119-128` puts that map in `available_tools`. **No marker,
  delimiter, or `provenance` field.**

### Reachability

Full and production-only: `mcp_planning_surface` → deliberation planning input → planner prompt. No test
machinery.

### Probe

**p3 (`p3_inject.rb`)** — re-run of the analyst's probe C:

```
raw_bytes=8190
bounded_bytes=4096
retains_INJECTION=true
retains_never_ask=true
has_untrusted_marker=false
has_server_attribution=false
has_delimiter=false
```

**Reproduced exactly** (the analyst used 6132 B; I used 8190 B — same result, and it shows the bound is
byte-based, not sentence-aware).

### Guards

The guard the report leans on is real, though its citations drift. The report cites
`capability_binding.rb:344-353` for "an unlisted MCP tool is `:bounded` with `approval_policy: :required`."
Read at those lines: `:344-353` is `mcp_kind`/`mcp_egress_policy`/`mcp_protocol_profile` — **not the approval
policy**. The substantive guard exists but at different lines: `closed_effect_class` (`:206-209`) maps anything
outside the closed set to `:bounded`, and `mcp_approval_policy` (`:362-363`) is
`effect_class == :read_only ? :none : :required`. I verified `mcp_approval_policy(:bounded) == :required`.
**Behavior as described; line numbers wrong.** This is a citation-drift finding, not a severity change.

### Verdict + reason

**UPHELD as `major`.** The injection is real and reaches the planner prompt verbatim, but it **cannot grant
authority by itself**: any resulting MCP call is `:bounded`, approval-required, and non-retryable
(`mcp_retry_policy` `:366-368`), so a human sees the preview before dispatch. The operational cost is a
model steerable toward an approval prompt the operator did not originate — a `major` "security gap with real
operational cost" — not a `critical` authority bypass. The analyst's grading and its stated reason are
correct. I correct only the approval-guard citation (`:362-363`, not `:344-353`).

## F09-COR-01

### Source re-verified

- `invocation.rb:73-78` — **exact**: `Descriptor#read_only?` derives from `effect_class`.
- `invocation.rb:37` — **exact**: `REQUIRED_DESCRIPTOR_METHODS = %i[id name source_id definition_digest input_schema effect_class]`.
  **`read_only?` is not in it.**
- `invocation.rb:402-404` (`retry_eligible?`) and `:489-491` (`post_send_transport_error`) — **exact**:
  both branch on `descriptor.read_only?`.
- `mcp_capability_source.rb:171-176` (`read_only_descriptor?`) — **exact**: prefers `read_only?` when the
  descriptor responds to it, else derives from `effect_class`.
- `capability_binding.rb:206-209`/`:362-368` — `closed_effect_class`/`mcp_approval_policy` key off
  `effect_class`.

### Reachability

This is the crux and **it is weak in production**. `grep -rn "McpSourceBuilder.new" gems/ script/ apps/ bin/`
returns exactly two production construction sites — `cli.rb:662` and `worker_runtime.rb:922` — and both call
`.build`, whose `append_descriptors` (`mcp_source_builder.rb:80-89`) uses `Invocation.descriptor_for`. So
**there is one production descriptor producer, and it cannot diverge.** The binding's own interface validator,
`McpCapabilitySource#validate_descriptor_interface!` (`:239-246`), requires only
`%i[id name source_id definition_digest effect_class]` — again **not `read_only?`** — and contains **no
agreement check**. So the divergence is constructible only by a caller that hand-builds a descriptor against
the advertised duck-type; no production caller does.

### Probes

**p4 (`p4_cor.rb`), probe A** — a struct satisfying all five required methods with `read_only? = true` and
`effect_class = :bounded`:

```
PROBE_A effect_class=bounded read_only?=true
PROBE_A post_send_transport_error -> read_only_unavailable_error
PROBE_A retryable_as_read_only=true
```

**Reproduced**: a post-send failure on a `:bounded` descriptor is reported as
"read-only and may be retried," and `retry_eligible?` would permit the retry.

**p4b (`p4b.rb`), probe B** — the real `Catalog.compile` + `descriptor_for` path:

```
descriptor_for(effect_class: :read_only) -> read_only?=true consistent=true
descriptor_for(effect_class: :bounded) -> read_only?=false consistent=true
descriptor_for(effect_class: :unknown_effects) -> read_only?=false consistent=true
```

**Reproduced**: the production constructor is consistent for every class.

### Verdict + reason

**DEMOTED — real contract gap, confidence medium, and not `major`. I assign `minor` (contract/ownership debt).**

Probes A and B both reproduce, so the *mechanism* is real. But the BAR grades behavior, and the behavior here
is not reachable in production: the sole producer is self-consistent by construction, and both interface
validators omit `read_only?` without a mismatch guard only because nothing is expected to supply it
independently. A `major` requires "real operational cost"; the report itself concedes reachability is medium
and that "no production caller constructs such a descriptor today." A hypothetical future caller is exactly
the BAR's `minor` band — "bounded maintainability… debt with limited immediate impact."

On the coordinator's specific question — **can this make an unsafe effect retryable in production? No.**
`retry_eligible?` only fires when `descriptor.read_only?` is true *and* the descriptor reached
`Invocation.call` through the production executor, which only ever sees `descriptor_for` output. To reach it
an operator would have to write new code that hand-builds a contradicting descriptor, and that new code is
the defect. This is a **contract-hardening recommendation, not a production defect**, and it is the same shape
F10-MNT-01 already records as `info` from the other row. It should not be counted as a second `major` for
this row. Keep the recommendation (add `:read_only?` to `REQUIRED_DESCRIPTOR_METHODS`, or make `Invocation`
prefer `effect_class` when present, and document which reader is authoritative); drop the severity to `minor`
and record it once, not twice.

## F10-SEC-01

### Source re-verified

- `script/websearch_adapter:143-146` — **exact**: the only check is
  `endpoint.is_a?(String) && endpoint.start_with?("https://")`.
- `:171` (`endpoint = provider.fetch("endpoint")`) and `:174-178` — **exact**: it is passed verbatim to
  `client.fetch(...)` with the query in the JSON body.
- `egress_client.rb:202-207` (`request_path`) — **exact**: `uri.request_uri` is returned verbatim, with only a
  nil check.
- `egress_client.rb:278` — **exact**: `Net::HTTP::Post.new(path)`; the path is sent as-is.

### Reachability

`WebsearchAdapter.search_response` → `load_provider` (env `TAMOZ_WEBSEARCH_PROVIDER`, itself an
`env_allowlist` entry the operator must list) → `http_result` → `EgressClient#fetch`. The endpoint string is
entirely process-environment-controlled; nothing on the Tamoz side constrains its host or path.

### Probe

**p5 (`p5_endpoint.rb`)** — real `EgressPolicy` + real `EgressClient`, injected resolver and connector:

```
DIALLED=["internal.example/collect body={\"query\":\"find the secret\",\"max_results\":3}"]
OFF_ALLOWLIST_REFUSED=Tamoz::Mcp::Websearch::EgressPolicyError dials=0
METADATA_REFUSED=Tamoz::Mcp::Websearch::EgressPolicyError: the websearch target host "metadata.example" resolved only to refused addresses dials=0
ARBITRARY_PATH_DIALLED=["/deep/arbitrary/path?x=1"]
```

**Reproduced**, with all three controls: an allowlisted-but-different host is dialed at an arbitrary path
with the query in the body; an off-allowlist host is refused with zero dials; a metadata address is refused
**even when its hostname is allowlisted**; and the path is unvalidated. The analyst's implicit claim that
private ranges hold is confirmed.

### Guards / severity

The report's `major` rests on this being a boundary violation rather than SSRF-to-metadata, and I looked for
the strongest counter-argument: **"the allowlist is the authority, so any host on it is permitted and the
endpoint is not supposed to be pinned."** That counter-argument **fails on the repository's own text.**
`documentation/guides/agent-operator.md:250-252` instructs the operator:

> For a live HTTP provider, use an `https://` endpoint whose **exact host** is in `allowlisted_hosts`

So the documented contract **is** that the endpoint host is the declared provider identity, and
`allowlisted_hosts` exists to bound *redirect* targets (`egress_client.rb:84-109` re-validates every hop).
The shipped code enforces only "some host on the list," which is a real divergence between documented
contract and code — not a case of the allowlist being the authority. The finding stands.

### Verdict + reason

**UPHELD as `major`.** Confirmed at source and by probe; the documented "exact host" contract is not what the
code does; the risk is that *which provider receives the query* stops being a Tamoz-side fact. It is not
`critical`: private ranges genuinely hold even when allowlisted (probe-verified), so this is not
SSRF-to-metadata, no authority or approval gate is widened, and the attacker is whoever controls the
adapter's process environment — which `runtime_directory.rb` already treats as operator authority. The
analyst's recommendation (require the resolved endpoint host to be the first entry of
`policy.allowlisted_hosts`) matches the documented contract and is the right minimal fix.

## F10-SEC-03

### Source re-verified

- `session.rb:251-264` (`enforce_egress_binding!`) and `:293-298` (`current_egress_pin`) — **exact**: both only
  *pin and compare* the declaration.
- `session_bindings.rb:44-48` — the `egress_pin` write.
- `mcp_source_builder.rb:239-254` (`config_arguments_for`) — **exact**: forwards `env_allowlist` and
  `credential_refs`; no egress declaration.
- `egress_policy.rb:16-22` — **exact and quoted accurately by the analyst**: "Any 'runtime comparison' a
  caller surfaces is a SELF-REPORTED, `author_claimed` check with no enforcement value (invariant 35: a
  self-report is not policy)."
- `documentation/guides/agent-operator.md:246-249` and `:204-217` — the manual operator procedure.

### CF05-SEC-01 consistency ruling

The prior challenger DEMOTED CF05-SEC-01 from `major` to **info/documentation gap**, on the ground that the
profile schema has **no MCP field at all**, so "the profile must cap MCP" names no data path — an unfinished
specification, not a violated implementation.

**I agree with that ruling and apply it consistently, and I extend it one step further, which changes the
answer for F10-SEC-03.** CF05-SEC-01's demotion rests on a *missing schema field*. F10-SEC-03 has no such
excuse: the egress field **exists**, is validated, is pinned, and is resume-checked. The gap is not a missing
data path; it is a missing **join** between two declarations that both exist. That is a stronger footing than
CF05-SEC-01, not a weaker one — so if CF05-SEC-01 falls to `info`, F10-SEC-03 does not automatically fall with
it on the "no data path" ground.

**But it falls anyway, on the code's own disclaimer.** `egress_policy.rb:16-22` states, in the owning file's
own voice, that the runtime comparison is "SELF-REPORTED, `author_claimed` … with no enforcement value." The
question the coordinator posed is the right one, and my answer is: **when the code's own comment disclaims
enforcement value, recording the absence of enforcement as a `major` defect is not honest grading — it is
re-recording a documented limitation as a new defect.** A `major` is "a material gap with real operational
cost"; here the design deliberately places the enforcement point outside Tamoz (a network-capable process
Tamoz never runs), documents the duplication as intentional and boundary-driven
(`egress_policy.rb:9-14`, "tamoz-mcp must not depend on tamoz-agent"), and states the residual risk in prose.
That is the BAR's `info` band — "a verified design fact, limitation, or question … not itself a defect."

The one part that is *not* pure limitation is the documentation asymmetry: `agent-operator.md:246-249` tells
the operator to "put the same egress declaration under the profile's `egress:` section so the session records
and pins the policy," which a reasonable operator reads as a safety property, while no code joins the two.
That is a real doc-vs-code gap — but it is the **same** doc-vs-code gap CF05-SEC-01 already carries, on the
same unsettled admission contract.

### Verdict + reason

**DEMOTED — `info` / documentation gap, consistent with the prior challenger's CF05-SEC-01 ruling.**

### Merge call

**MERGE F10-SEC-03 into CF05-SEC-01 as one indexed record.** The analyst argued for keeping them separate
("CF05-SEC-01 is about which MCP NAMES reach the model, this is about which EGRESS DECLARATION governs the
call"). I disagree with that separation, for three reasons:

1. **They are the same root cause**, which the analyst's own five-whys states: *"admission authority for the
   `websearch` source id was never assigned — the same gap CF05-SEC-01 records."* Two findings with one root
   cause and one owner ("the profile-to-MCP admission contract is unsettled") should be one record with two
   axes, not two records.
2. **They share one fix.** CF05-SEC-01's fix is "decide and implement profile→MCP admission"; F10-SEC-03's fix
   is "derive the adapter's declaration from, or check it against, the pinned one." Both are the *same*
   decision — does the profile bound the MCP/websearch surface or not — expressed on two axes (which tools,
   which egress). Splitting them lets the coordinator ratify a contract on one axis and leave the other
   dangling.
3. **They share one severity**, and keeping them separate inflates the count: two `major`s for a single
   undecided contract reads as two defects. Once both are `info`/documentation gaps, one record with an
   "admission axis (names)" and an "egress axis (declaration)" is the honest representation.

Proposed merged record: **CF05-SEC-01 (`info`/documentation gap; open)** — "the profile→MCP/websearch
admission contract is unstated and unjoined on both axes: capability names (`admission_set` appends every
`@mcp.names`) and egress declaration (pin-only readers; adapter runs under its own env)." Keep F10-SEC-03's
recommendation as the egress-axis sub-item and keep both regression recommendations regardless of which
contract is ratified. F10's own verdict line should then read 0 critical / 0 major (after F10-SEC-04 is also
closed) rather than 0/2.

## F10-SEC-04

### Source re-verified

- `websearch.rb:52-56` (`credential_shaped_query?`) and `:68-73` (`sanitize_result`) — **exact**.
- **Zero production call sites — CONFIRMED.** `grep -rn "credential_shaped_query?\|sanitize_result"`
  (excluding this doc tree) returns only: `websearch.rb` itself; `test/websearch_invocation_test.rb:325,405,411,444`;
  `test/support/agent_smoke_corpus.rb:1846,1877,2008`; and the public-API manifests
  (`test/public_api_test.rb:295-297`, `docs/public-api.json:315-317`, `docs/requirements-*.json`). The
  analyst's list is exact.

### But the analyst's "no production control" reading is REFUTED

The finding assumes the production path performs neither hygiene nor sanitization. **That is false**, on two
independent counts I verified:

1. **Query hygiene IS wired — into the adapter, via its own implementation.**
   `script/websearch_adapter:110` calls `credential_shaped?(query)` and refuses with a named reason, and
   `:190-194` defines that method *inside the adapter*. So the invariant-24 control genuinely runs on the one
   production egress path. That it is a private duplicate rather than the gem's exported
   `Websearch.credential_shaped_query?` is a **duplication/maintenance** fact (the meaningful part: the two
   implementations differ — the gem's uses `Tamoz::Core.secret_shaped?` and an anchored env-assignment regex,
   the adapter's uses `CREDENTIAL_NAME_PATTERN`, an anchored `sk-`/`pk-` token, and a looser `=`
   split), not an absent control.
2. **Result sanitization IS performed in production — by a different implementation.**
   `session_effects.rb:259-263` (`sanitize_remote_text`) applies `Tamoz::Core::SECRET_VALUE_PATTERNS` with
   `[REDACTED]` on the production observation path, and `:238-245` is where it runs. Probe p6 (`p6_sanitize.rb`)
   feeds the repository's own credential fixture (`script/websearch_adapter:158-160`,
   `OPENAI_API_KEY=sk-fixture-leaked-value … api_token: sk-fixture-leaked-value`) through the real production
   sanitizer:

   ```
   PRODUCTION_STRIPPED="The configured answer is 42.\nOPENAI_API_KEY=[REDACTED] field api_token: [REDACTED]"
   still_has_raw_sk=false
   ```

   **The production path strips the credential.** The gem's `sanitize_result` is a second, richer
   implementation of a control that production already performs.

### The docstring claims

The analyst flagged "missing wiring vs misleading docstring are both supported." **Neither is supported by
the docstrings**, which is decisive:

- `websearch.rb:46-51` says *"Such a query is rejected at invocation (fail closed, no call is issued)"* — a
  statement about the **function's own** contract, and true of the adapter path.
- `websearch.rb:57-67` (`sanitize_result`) says explicitly: ***"The caller applies this** to the observation
  text before it enters the effect journal."* That is an explicit **caller obligation**, not a claim that the
  production path runs it. A method that documents "the caller applies this" and has no in-repo production
  caller is a **library helper with an unmet caller obligation**, not misleading evidence.

### Verdict + reason

**REFUTED as a defect — close it (record at most a `minor` maintenance note about the duplicated,
divergent hygiene implementations).**

The report's core claim ("the production path applies neither") is false on both halves: the query control
runs in the adapter (`:110`/`:190`), and the result sanitization runs in `SessionEffects#sanitize_remote_text`
(`:259-263`), verified by probe against the repo's own credential fixture. The docstrings claim only what the
functions do and explicitly assign the sanitizer to the caller, so there is no misleading-evidence defect
either. The genuine residual — two divergent `credential_shaped?` implementations and two result-sanitizers
where one would do — is a `minor` duplication/maintainability item owned at `McpSourceBuilder`/adapter, and
it is already adjacent to F10-MNT-02's drift observation. Per `AGENTS.md` ("the simple solution over the
complicated one"; "a new class that duplicates a capability the codebase already has is a defect"), the honest
recommendation is to **delete the gem-side duplicate or make the adapter call it**, not to wire a third copy
into `build_validator`.

## Net effect on FINDINGS.md

- **F09-SEC-02**: **keep `critical`, open** — but **strike the livelock/repair-loop consequence** from the
  report (refuted by probe p2: the raised `ToolError` has `repairable? == false`, so `session_steps.rb:232`
  makes it terminal). Keep the grade on the two verified grounds: (a) the scorecard's
  `mcp_elicitation_interrupts` counter is incremented by a direct `Invocation.call` bypassing the session and
  gates the case oracle (materially misleading evidence — stronger than reported), and (b) a documented
  durable-interrupt contract is destroyed, with `Invocation.reissue` production-dead. Keep the recommendation.
- **F09-SEC-01**: **keep `major`, open.** Correct the approval-guard citation from
  `capability_binding.rb:344-353` to `:206-209` (`closed_effect_class`) and `:362-363` (`mcp_approval_policy`).
- **F09-COR-01**: **change severity to `minor`** (contract/ownership debt, medium confidence, no production
  reachability — the sole descriptor producer `McpSourceBuilder#build` is self-consistent, and
  `validate_descriptor_interface!` omits `read_only?`). Keep the hardening recommendation; do not double-count
  it with F10-MNT-01.
- **F10-SEC-01**: **keep `major`, open.** Recommendation is correct; add that
  `documentation/guides/agent-operator.md:250-252` ("exact host") is the contract the code violates.
- **F10-SEC-03**: **change to `info`/documentation gap, and MERGE into CF05-SEC-01** as a single indexed
  record with a names axis and an egress axis. F10's major count drops by one.
- **F10-SEC-04**: **close as REFUTED** (production performs both controls; the docstring claims only the
  function's own contract and explicitly assigns sanitization to the caller). Optionally re-record the
  duplicated/divergent hygiene implementations as a `minor` maintenance item. F10's major count drops to zero.
