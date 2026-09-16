# Independent challenge — F18 capabilities

| Field | Value |
|---|---|
| Row | F18 — tamoz-agent-capabilities, sealed capability catalog and durable child-task dispatch |
| Baseline | audit-15-09 at 582ae5566de1ae073aea82b69bb2bbf444494d3b |
| Date | 2026-09-15 |
| Challenger | independent read-only challenge agent |
| Boundary | Only this challenge file and /tmp/tamoz-agents/challenge_f18_capabilities.log were writable |

## Method and source boundary

I read docs/subagent-orchestration.md, the audit README.md, BAR.md, COVERAGE.md,
and FINDINGS.md before reading analyses/F18-capabilities.md and
analyses/F18-capabilities.json. I independently re-read every live path cited by
the F18 record at the deciding callers and contracts:

- gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb
- gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_capability_source.rb
- gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb
- gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_browser_source.rb
- gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_database_source.rb
- gems/tamoz-agent-capabilities/lib/tamoz/agent_capabilities.rb
- gems/tamoz-core/lib/tamoz/core/capability/{source,registry}.rb
- gems/tamoz-tools/lib/tamoz/tools/capability_host.rb
- gems/tamoz-mcp/lib/tamoz/mcp/{server_config,catalog,invocation}.rb
- gems/tamoz-agent-session/lib/tamoz/agent/{session_bindings,session,session_steps,session_effects}.rb
- gems/tamoz-agent/lib/tamoz/agent/{runtime_directory,worker_runtime}.rb
- test/capability_registry_test.rb
- test/agent_mcp_capability_source_test.rb
- test/agent_worker_mcp_test.rb
- test/agent_governed_database_source_test.rb
- test/agent_phase4_capability_test.rb
- docs/P10_MCP_PLAN.md
- docs/P18_CAPABILITY_HOST_PLAN.md
- docs/openclaw-intelligence-study/implementation-plan/01-phase-0-authority-and-identity.md
- docs/openclaw-intelligence-study/implementation-plan/05-phase-4-governed-expansion.md
- docs/openclaw-intelligence-study/implementation-plan/evidence/phase-4/implementation-review.md

I also checked the existing CF05, F08, F09, F10, F21, F22, and F25 findings and
their challenge records before assigning ownership. All experiments used
temporary files or objects under /tmp. No production code, test, configuration,
existing audit file, or commit was touched.

## Verdict summary

The F18 analyst's IMPROVE verdict remains correct because the production MCP
builder and session resume guard have a major policy-binding gap. The other
leads are narrower than an authority bypass: one is a generic API invariant, one
is an operator-configuration aggregate bound, one is an optional caller
contract, and one is an intentionally undelivered browser connector.

| Finding | Challenge result | Recommended disposition |
|---|---|---|
| F18-SEC-01 | Reproduce; sidecar policy changes do not change the resume source pin | Keep major, high, open; owner is the builder-to-session MCP binding |
| F18-COR-01 | Reproduce; duplicate source IDs misalign Registry and Host | Keep minor, high, open; owner is Core Registry construction |
| F18-SCL-01 | Reproduce and qualify; all configured servers are materialized without an aggregate cap | Keep minor, high, open; owner is MCP builder configuration admission |
| F18-OBS-01 | Reproduce acceptance, but not in-tree production reachability | Keep info, medium, unconfirmed; decide the public caller contract |
| F18-MNT-01 | Refute as an open defect; the injected-only boundary is documented and fail-closed | Close the defect lead as info/design limitation; retain the phase boundary |

## Six-lens readout

Correctness is sound for the ordinary sealed path: source ownership, descriptor
identity, catalog entry digests, argument validation, and uniform dispatch are
all enforced. F18-COR-01 is a generic construction edge where source identity is
not unique even though dispatchers are keyed by it.

Security and authority are bounded by operator-owned runtime configuration.
Untrusted model output, catalog descriptions, and workspace content do not build
a source or select an approval class. F18-SEC-01 is still a real durability
boundary defect because an operator policy input changes the effect and database
validation semantics without changing the recorded source binding.

Reliability and durability pin the catalog snapshot and source digest maps, and
remote calls use the ordinary effect journal. The missing sidecar inputs mean a
resumed session can be reconstructed with different policy semantics while the
catalog and source maps compare equal.

Observability preserves catalog digests, result provenance, truncation, and typed
refusals. F18-OBS-01 shows that a caller can construct a source with no source
provenance map; the production builder supplies one, so this remains an
unconfirmed public-contract limitation.

Scalability has per-server catalog, output, transport, and child-task bounds but
no bound on the number of MCP servers or the combined descriptor/planning
surface. The source proves the missing aggregate guard; no load claim is made.

Maintenance ownership is mostly clear: the builder owns operator MCP settings,
Core owns source identity, the host owns dispatcher binding, and Session owns
resume checks. The browser class is a tested public adapter seam, not a
registered built-in source in this phase.

## F18-SEC-01 — MCP resume source pins omit operator policy

**Challenge: reproduce. Severity: major, confidence high, status open.**

The builder consumes read_only_tools while constructing each descriptor
(gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:80-89,
202-204), and consumes database settings to install a row/query validator
(mcp_source_builder.rb:125-138, 182-200). It records the source pin by hashing
only ServerConfig#describe (mcp_source_builder.rb:191-195). That describe payload
contains transport, command, endpoint, credentials by name, protocol, and
budgets, but not either sidecar (gems/tamoz-mcp/lib/tamoz/mcp/server_config.rb:158-174).
The catalog snapshot digest also covers only server/protocol/entry definition
digests (gems/tamoz-mcp/lib/tamoz/mcp/catalog.rb:239-246); Invocation's
descriptor effect class is supplied separately
(gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:145-164).

SessionBindings stores the two maps exposed by the source
(gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:34-41), and
Session#enforce_mcp_binding! accepts a resume when those two maps compare equal
(gems/tamoz-agent-session/lib/tamoz/agent/session.rb:233-248). The guard runs on
the durable continuation path (session.rb:439-449). It does not compare the
builder settings that produced the current descriptor effect class or database
policy. SessionEffects' catalog revision is derived from mcp_catalogs alone, so
the source map is not part of the logical effect identity either
(gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:135-156).

The independent probes were no-network and used the production classes:

~~~
SEC01 sidecar_variants_digest_equal=true digest_a=sha256:e3a0e891aa012a014ec7404185219a79c4ee5e848c9cb36aad30983d70a95601 digest_b=sha256:e3a0e891aa012a014ec7404185219a79c4ee5e848c9cb36aad30983d70a95601
SEC01 variant_a_effect=:read_only variant_b_effect=:unknown_effects
SEC01 variant_a_rows=10 variant_b_rows=nil
~~~

The second semantic probe built the corresponding sealed bindings:

~~~
SEC01 binding_effect_class_unknown_effects=bounded safety=:unsafe
SEC01 binding_effect_class_read_only=read_only safety=:read_only
SEC01 database_policy_outputs=[1, 10]
OBS01 catalogs={"probe"=>"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} source_digests={}
SEC01 resume_guard_with_empty_map=ACCEPTED
~~~

The two equal digests represent different settings: one source marks query
read-only and limits rows to 10; the other marks no tool read-only and disables
the database sidecar. The same catalog and source digest map therefore admit
both effect classifications. CapabilityBinding turns the former into
read_only/no approval/read-only retry and the latter into bounded/unsafe,
approval-required/non-retryable behavior
(gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:201-209,
362-371, 451-453). GovernedDatabaseSource likewise changes the effective row
limit and write-query validation before the underlying MCP call
(gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_database_source.rb:21-23,
41-74). SessionSteps executes the no-approval branch from the current
preparation and SessionEffects derives its approval request from the current
capability effect class (gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb:20-35,
60-91; gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:279-297,
366-375).

The threat model is an operator changing a valid runtime MCP policy while a
durable session is paused or resumed. The model, MCP server, catalog
description, and workspace cannot author these settings; RuntimeDirectory
restricts enabled sources to operator configuration
(gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:43-45,112-132). That
limits this to policy drift or same-UID operator-path compromise and is why I
do not promote it to critical. The semantic drift is still material: a resumed
plan can be governed by a different approval, retry, or database validation
policy while the session reports the old source binding.

Five whys:

1. Resume accepts changed policy because the stored and current MCP source maps
   remain equal.
2. The maps remain equal because record_source_digest! hashes only
   ServerConfig#describe.
3. ServerConfig#describe omits read_only_tools and database, even though the
   builder consumes both after creating the config.
4. No canonical sidecar payload is joined to the source digest passed into
   McpCapabilitySource.
5. No invariant or end-to-end test requires every builder-consumed authority
   input to be represented in the session MCP binding.

Control cases are present and passed. The control probe changed ServerConfig
arguments and showed that the existing config digest changes. The existing
resume test accepts an identical source and rejects a changed catalog before
continuation (test/agent_mcp_capability_source_test.rb:443-487). Invocation
also verifies each descriptor's definition digest before I/O
(gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:267-292). These controls show that
ordinary config and catalog drift are fenced; they do not cover the omitted
sidecars.

The smallest repair is at the existing builder seam: canonicalize normalized
read_only_tools and database options together with config.describe, record that
digest for each server, and make the resume test change each sidecar while
holding the catalog fixed. The finding is **upheld as major, high, open**, with
ownership assigned to McpSourceBuilder and Session's MCP binding rather than
CF05, F21, or F22.

## F18-COR-01 — duplicate source IDs are accepted by Registry

**Challenge: reproduce and qualify. Severity: minor, confidence high, status
open.**

Core Source rejects duplicate descriptor IDs inside one source and requires an
exact definition-digest map, but it does not assert uniqueness of source_id
across Source values (gems/tamoz-core/lib/tamoz/core/capability/source.rb:18-45).
Registry checks built-in prefixes, descriptor ownership, and duplicate descriptor
IDs, but not duplicate source IDs
(gems/tamoz-core/lib/tamoz/core/capability/registry.rb:69-112). CapabilityHost
stores one dispatcher per source ID, refuses a second binding, and routes through
the first source found for a descriptor
(gems/tamoz-tools/lib/tamoz/tools/capability_host.rb:102-123,147-157;
gems/tamoz-core/lib/tamoz/core/capability/registry.rb:45-48).

The no-network probe constructed two valid Core Source values with source_id
local:

~~~
COR01 registry_duplicate_source_ids=["local", "local"]
COR01 second_binding=REJECTED Tamoz::Core::Capability::DescriptorConflictError: capability source "local" already has a bound dispatcher; a bound source is never re-implemented
COR01 dispatch_one=first:one
COR01 dispatch_two=first:two
~~~

The result is a real generic API invariant gap. A caller can publish a registry
whose second source has no implementation slot, and the host then executes both
IDs through the first implementation. The ordinary production binding groups
MCP descriptors by source ID and creates one Source and one dispatcher per group
(gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:283-305),
so no current CapabilityBinding path generated the bad shape. No content or model
path can call Registry.build under the closed runtime source set.

Controls are also clear: cross-source duplicate descriptor IDs are rejected by
Registry and covered by test/capability_registry_test.rb:116-127; duplicate
descriptor IDs within a Source are rejected by source.rb:25-27; unique source
IDs bind and route normally. The causal chain is a missing uniqueness assertion
followed by a hash-keyed dispatcher contract, with the production grouping
currently masking it.

Reject duplicate source_id values during Registry.build, before the descriptor
registry is published, and add one construction test. Keep this as **minor,
high, open API invariant debt**. It is owned by Core Registry construction and
must not absorb F09-COR-01's separate duck-typed descriptor-field issue.

## F18-SCL-01 — no aggregate MCP server or descriptor bound

**Challenge: reproduce and qualify. Severity: minor, confidence high, status
open.**

McpSourceBuilder returns every configured MCP server mapping
(gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:256-280),
then loops over all of them, compiling a catalog and creating a supervisor for
each (mcp_source_builder.rb:50-78). Catalog's maximum entry budget is per server
(gems/tamoz-mcp/lib/tamoz/mcp/catalog.rb:107-113), and CapabilityBinding appends
the resulting remote names to the host surface
(gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:302-310).
No total server, descriptor, description-byte, or supervisor-count bound is
enforced before materialization.

The probe supplied one valid server and then 300 valid server mappings to the
real builder's server_configs seam:

~~~
SCL01 one_server_configs=1
SCL01 many_server_configs=300
SCL01 aggregate_guard=not_observed
~~~

This is a boundedness gap with operator-only reachability. A large valid runtime
configuration can consume startup work and memory for supervisors and can
produce a large model-visible MCP name/description surface even though each
individual catalog obeys its 256-entry budget. No model output, workspace file,
or remote catalog can add a server to RuntimeDirectory. No load or soak run was
made, so the evidence proves the missing guard rather than a deployment-specific
failure threshold.

Controls are the per-server budget and ServerConfig's bounded transport,
timeout, output, and concurrency fields
(gems/tamoz-mcp/lib/tamoz/mcp/server_config.rb:59-110), plus the one-server
configuration path that materializes normally. The causal chain is that the
builder treats the operator list as an unbounded iteration, only Catalog
enforces a per-server limit, and the host then aggregates all names.

Add a simple aggregate server and descriptor admission limit before catalog and
supervisor materialization, rejecting the complete configuration when exceeded.
Keep this **minor, high, open** scalability debt owned by McpSourceBuilder. It
does not overlap CF05 admission semantics or F10 websearch egress.

## F18-OBS-01 — source provenance map is optional at source construction

**Challenge: reproduce acceptance and qualify reachability. Severity: info,
confidence medium, status unconfirmed.**

McpCapabilitySource defaults source_digests to an empty map and only stringifies
and freezes what the caller supplies
(gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_capability_source.rb:50-74).
The constructor validates catalog and descriptor structure but has no exact
catalog-key or SHA-256 shape requirement for the source map
(mcp_capability_source.rb:208-228). SessionBindings persists whatever map the
source exposes (gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:34-41).

The probe built a valid catalog and descriptor without source_digests and
observed:

~~~
OBS01 catalogs={"probe"=>"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"} source_digests={}
SEC01 resume_guard_with_empty_map=ACCEPTED
~~~

This is acceptance behavior at a public caller-supplied source boundary. The
production McpSourceBuilder always supplies the map when composing the source
(mcp_source_builder.rb:169-178), and no CLI/worker caller that omits it was
found. The threat model is therefore an embedding or future adapter passing a
catalog-only source, not untrusted content obtaining a source. The supplied
map is also not shape-validated, but no production caller with an invalid map
was found, so that fact does not justify a higher severity.

Controls are the builder's populated map, the catalog digest mismatch refusal
covered by test/agent_mcp_capability_source_test.rb:443-487, and the source's
descriptor/catalog digest checks. Decide whether every MCP source must carry an
exact valid map keyed by every catalog server. If yes, require it at
McpCapabilitySource construction; if catalog-only mode is intentional, document
that it does not claim transport/policy provenance. Keep this as **info,
medium, unconfirmed**. It is a separate API-contract question from SEC-01's
production omission of sidecar inputs.

## F18-MNT-01 — browser adapter reachability

**Challenge: refute as an open defect and preserve the limitation. Severity:
info, confidence high, recommended status closed.**

RuntimeDirectory's closed source set contains skills, memory, MCP, and websearch;
browser is not a runtime source
(gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:43-45,112-132).
CapabilityBinding constructs local, skill, and grouped MCP/websearch sources
only (gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:261-310).
The public browser class is required and documented, but it accepts an adapter
by injection. Its execute path validates the descriptor and arguments, then
refuses before any connector action when the adapter is absent
(gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_browser_source.rb:46-55,
163-175).

The repository search used by the challenge found only the class and its README
entry under gems, with no production source construction or registration:

~~~
gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_browser_source.rb:11:    class GovernedBrowserSource
gems/tamoz-agent-capabilities/README.md:20:- GovernedBrowserSource / GovernedDatabaseSource — policy-guarded
~~~

The direct nil-adapter control produced
browser adapter unavailable: configure an approved browser connector. The
injected-adapter tests also prove bounded output, final-location evidence, and
redirect host enforcement
(test/agent_phase4_capability_test.rb:130-201). Phase 4 states explicitly that
it does not provide an end-to-end browser mission or connector registration
(docs/openclaw-intelligence-study/implementation-plan/05-phase-4-governed-expansion.md:14-19;
docs/openclaw-intelligence-study/implementation-plan/evidence/phase-4/implementation-review.md:50-61).

There is no authority bypass: a browser capability cannot reach the sealed host
in this checkout, and a direct source without a connector fails closed. The
lead is therefore a verified phase limitation, not an unresolved production
bug. Close the open defect lead as **info/closed**, keep the injected-only
boundary explicit in capability documentation, and add a reachability test only
when an approved connector is intentionally registered. This also resolves the
uninvestigated browser lead noted during F09 without moving any F09 or F10
ownership.

## Ownership and overlap

- **CF05:** owns the profile-to-MCP-name admission contract. This challenge
  does not decide whether a profile should declare MCP names; SEC-01 begins
  after admission and covers builder sidecar policy drift.
- **F08:** owns inherited credential-environment exposure in local checks. No
  MCP registry, source digest, or browser seam duplicates that finding.
- **F09:** owns remote description injection, elicitation handling, and the
  duck-typed descriptor mismatch. COR-01 is source-container identity and host
  routing; MNT-01 closes the earlier browser reachability question as an
  intentional partial boundary.
- **F10:** owns websearch endpoint, egress, and sanitizer behavior. SEC-01 is
  the MCP builder's read-only/database policy binding and remains distinct from
  profile egress declaration or websearch adapter wiring.
- **F21:** owns profile digest replay integrity. SEC-01 does not change the
  profile snapshot; it covers sidecar settings absent from the MCP source pin.
- **F22:** owns the session profile-binding comparison. The MCP catalog/source
  guard is a different record field and owner; SEC-01 belongs to the
  builder-to-MCP binding.
- **F25:** owns worker restart profile loading and the child-MCP ambiguity.
  The child path deliberately receives mcp: nil; no new child MCP bypass was
  proven. SEC-01 is the parent MCP policy digest boundary.

No challenge finding should be counted twice. SEC-01 and OBS-01 are related
only in that both concern source pins: SEC-01 is a concrete production digest
omission, while OBS-01 is an optional caller contract. COR-01 and SCL-01 are
also independent: source identity/routing versus aggregate resource admission.

## Commands and results

Each focused test command named one test file and used ruby -Itest. No bundle
installation or lint command was run.

| Command | Result |
|---|---|
| ruby -Itest test/capability_registry_test.rb | 9 runs, 28 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/capability_host_test.rb | 21 runs, 91 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/agent_mcp_capability_source_test.rb | 14 runs, 102 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/agent_phase4_capability_test.rb | 7 runs, 31 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/agent_governed_database_source_test.rb | 2 runs, 7 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/agent_cli_mcp_test.rb | 6 runs, 28 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/mcp_server_config_test.rb | 39 runs, 321 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/mcp_catalog_test.rb | 9 runs, 80 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/mcp_invocation_test.rb | 31 runs, 208 assertions, 0 failures, 0 errors, 0 skips |
| ruby -Itest test/agent_worker_mcp_test.rb -n '/test_(?!the_worker_calls_a_real_mcp_server_over_http)/' | 10 runs, 32 assertions, 0 failures, 0 errors, 0 skips |

Focused total: 148 runs, 928 assertions, 0 failures, 0 errors.

The full worker command ruby -Itest test/agent_worker_mcp_test.rb was also
run independently. It reached 11 runs and 32 assertions with 0 failures and
one error: the HTTP fixture failed before startup with
Errno::EPERM binding 127.0.0.1:0 at
test/support/mcp_http_fixture_server.rb:13. The filtered command reran the
other ten tests successfully. No network or live connector evidence is claimed.

The probe commands and their temporary outputs were:

- ruby /tmp/f18_challenge_probe.rb — reproduced empty source map acceptance,
  duplicate source IDs, first dispatcher routing, and 300 accepted server
  configurations.
- ruby /tmp/f18_sidecar_digest_probe.rb — varied read-only/database sidecars
  over one unchanged ServerConfig and reproduced equal source digests alongside
  different effect and database policies.
- ruby /tmp/f18_semantics_probe.rb — reproduced effect/safety changes,
  database max-row changes, and nil-browser-adapter refusal.
- ruby /tmp/f18_control_probe.rb — changed a ServerConfig argument and observed
  a changed production source digest.

## Deviations and forbidden-file proof

I did not run full CI, ci_full, RuboCop, Enola, a real model/provider, a live
browser connector, or load/soak testing. The full worker HTTP fixture was
attempted and was blocked by the sandbox bind permission above. The aggregate
finding therefore has no deployment-specific threshold, and the browser finding
has no live connector evidence by design.

Before writing this report, I captured SHA-1 hashes for the 87 pre-existing
files under docs/audits/functionality-audit-2026-09-15, excluding this owned
path, and captured an empty tracked diff. After writing, the same 87 hashes
were compared. The four root audit files shown as untracked in the final status
were already present before this unit; their hashes are included in that
comparison. The proof result was:

~~~
existing-audit-hashes-identical=true
tracked-diff-empty=true
forbidden-production-test-config-lines=0
~~~

The forbidden-path check covered gems/, test/, config/, README.md, and the
root audit BAR.md, COVERAGE.md, FINDINGS.md, and README.md. The only repository
path created by this unit is
docs/audits/functionality-audit-2026-09-15/analyses/challenge-f18-capabilities.md.
The required liveness log is
/tmp/tamoz-agents/challenge_f18_capabilities.log. Both owned files are mode
0644. Scratch probes and outputs remain only under /tmp.
