# F18 tamoz-agent-capabilities — sealed capability catalog and durable child-task dispatch

Row: F18 · Queue: W1B · Baseline: branch audit-15-09, commit 582ae5566de1ae073aea82b69bb2bbf444494d3b · Analyst: independent read-only F18 analyst · Date: 2026-09-15

## Scope and source map

The primary gem was read end to end. The cross-gem files below were read at the
callers and contracts that decide admission, provenance, policy, execution,
resume, and child-task authority.

| File | Lines | Role |
|---|---:|---|
| gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb | 462 | Production binding; local, skill, MCP/websearch, and child source construction; dispatch |
| gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb | 299 | Operator MCP configuration, catalog materialization, effect classification, database policy |
| gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_capability_source.rb | 292 | Frozen catalog/descriptors, validation, source execution and source pins |
| gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task.rb | 285 | Canonical child identity, narrowed profile, transitions, bounds |
| gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task_dispatcher.rb | 190 | Sealed delegate_child_task capability and durable enqueue request |
| gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_browser_source.rb | 188 | Injected browser adapter contract and fail-closed output/location checks |
| gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_database_source.rb | 103 | Read-only query and row bound policy used by the MCP builder |
| gems/tamoz-agent-capabilities/lib/tamoz/agent_capabilities.rb | 31 | Gem entry point; public requires |
| gems/tamoz-core/lib/tamoz/core/capability/descriptor.rb | 260 | Unified descriptor fields and digest/policy invariants |
| gems/tamoz-core/lib/tamoz/core/capability/source.rb | 50 | Frozen source container and descriptor ownership |
| gems/tamoz-core/lib/tamoz/core/capability/registry.rb | 150 | Built-in source gate, intersection, collision checks, sealed registry |
| gems/tamoz-tools/lib/tamoz/tools/capability_host.rb | 211 | Per-source dispatcher binding and uniform routing |
| gems/tamoz-mcp/lib/tamoz/mcp/server_config.rb | 474 | Validated operator server configuration and describe payload |
| gems/tamoz-mcp/lib/tamoz/mcp/catalog.rb | 251 | Catalog handshake, entry validation, per-server entry budget, snapshot digest |
| gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb | 764 | Descriptor/schema/digest gate, supervised call, bounded attributed output |
| gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb | 176 | Session MCP catalog/source pin record |
| gems/tamoz-agent-session/lib/tamoz/agent/session.rb | 516 | Resume guards for MCP catalog/source digests |
| gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb | 406 | Effect journal identity and capability dispatch |
| gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb | 1249 | Parent/child session construction, durable child authority binding, enqueue/settlement |
| gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb | 342 | Operator runtime source enablement and config loading |

The public gemspec advertises CapabilityBinding, McpSourceBuilder,
McpCapabilitySource, GovernedBrowserSource, GovernedDatabaseSource, ChildTask,
and ChildTaskDispatcher. It depends on tamoz-core, tamoz-mcp,
tamoz-agent-kernel, and tamoz-tools
(gems/tamoz-agent-capabilities/tamoz-agent-capabilities.gemspec:7-17).

## Behavior path

1. Runtime authority begins at RuntimeDirectory. Its enabled source names are
   restricted to skills, memory, mcp, and websearch
   (gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:43-128).
   McpSourceBuilder reads the configured MCP and reserved websearch entries,
   validates each ServerConfig, compiles one catalog, creates one supervisor,
   applies read_only_tools and database settings, and composes one
   McpCapabilitySource
   (gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:50-89,
   125-138, 169-204, 257-296).

2. The source holds frozen snapshots and source digest maps. Descriptors must
   be source-qualified, unique, and pinned to the corresponding snapshot
   entry
   (gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_capability_source.rb:50-74,
   160-169, 239-279). The real builder's descriptor producer is
   Invocation.descriptor_for through append_descriptors
   (gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:80-89).

3. CapabilityBinding creates one local source, an optional skill source per
   skill epoch, and one source per grouped MCP/websearch server. It adds the
   caller's MCP names to the host admission set, builds full descriptors, and
   binds each dispatcher before freezing the binding
   (gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:48-68,
   161-175, 261-310). Core Registry enforces built-in source prefixes,
   descriptor ownership, cross-source descriptor ID uniqueness, and the
   descriptor/admission intersection before sealing
   (gems/tamoz-core/lib/tamoz/core/capability/registry.rb:21-35,
   69-120). CapabilityHost routes every descriptor to the dispatcher of its
   owning source
   (gems/tamoz-tools/lib/tamoz/tools/capability_host.rb:102-171).

4. Session planning calls capability validation, builds an effect intent,
   derives effect class and approval, and renders a preview before execution.
   SessionEffects sends the execution through EffectDispatcher; McpDispatcher
   forwards the source-qualified ID to McpCapabilitySource, whose builder
   executor calls Invocation.call
   (gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:92-136,
   419-459; gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:75-86,
   279-296; gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:105-123).
   Invocation validates the descriptor and arguments, checks the catalog
   definition digest before I/O, supervises the call, and bounds/attributes
   the result
   (gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:81-100, 136-143,
   267-292, 614-665).

5. A session record stores MCP snapshot digests and source digests. Resume
   compares those two maps and stops when either changes
   (gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:34-41;
   gems/tamoz-agent-session/lib/tamoz/agent/session.rb:233-248). The source
   digest currently hashes ServerConfig#describe, while builder policy settings
   are supplied separately.

6. Child delegation is a sealed, bounded local capability. The dispatcher
   checks the descriptor ID, task/capability bounds, secret shape, durable
   parent context, and subset of the parent capability profile, then calls
   WorkerRuntime#enqueue_child_task
   (gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task_dispatcher.rb:8-85,
   121-186). The runtime rechecks narrowing and identity, persists the child
   and immutable authority binding, enqueues a durable request, and executes
   the child with local-only tools and the parent profile's digest
   (gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:202-235,
   708-728, 737-748, 1087-1123, 1195-1229). Child status transitions and
   completion/adoption are durable CAS operations
   (gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:242-325).

## Lens: correctness — reviewed

The normal sealed path is coherent. A content hash cannot become a
Capability::Source, source IDs are checked against descriptor ownership, IDs
collide across sources only by rejection, and only the descriptor/admission
intersection enters the host
(gems/tamoz-core/lib/tamoz/core/capability/source.rb:18-45;
gems/tamoz-core/lib/tamoz/core/capability/registry.rb:69-120). Local and skill
descriptors derive approval, retry, and source digest from the same
read-only split. MCP descriptors preserve source-qualified IDs, catalog
definition digests, schemas, and the remote source dispatcher.

Invocation's digest gate occurs before supervisor availability, client creation,
or connect. Child identity and parent narrowing are checked both at dispatcher
validation and durable enqueue. The focused registry, host, phase-four,
MCP-source, and child-runtime tests pass.

One generic host contract gap is recorded as F18-COR-01: Registry accepts
duplicate source IDs, while CapabilityHost has one dispatcher slot per source
ID. The production CapabilityBinding groups remote descriptors and constructs
unique source IDs, so no current production caller was found for the bad shape.

## Lens: security and authority — reviewed

The source and descriptor types are real immutable values. Registry construction
rejects an unbuilt-in source prefix and descriptors whose source ID does not
match the containing source
(gems/tamoz-core/lib/tamoz/core/capability/registry.rb:69-100). The model,
skill content, MCP catalog content, and child task text do not construct a
source or alter approval policy. MCP server risk is operator-owned:
unlisted tools become bounded/approval-required through
CapabilityBinding#closed_effect_class
(gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:201-209,
362-371). Database policy is operator-owned and rejects writes before the
underlying source call
(gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_database_source.rb:41-74,
93-100).

F18-SEC-01 identifies a resume authority drift: operator policy fields used by
McpSourceBuilder are not in the source digest that Session uses as its MCP
binding. This is separate from CF05-SEC-01's unresolved profile/MCP admission
contract and from F09's description/safety duck-type findings. The workspace
still cannot author an MCP server or descriptor; the gap is that a changed
operator policy can be treated as the same pinned source.

Child capabilities are restricted to local-qualified names at the dispatcher,
checked against the parent profile, and converted to local toolbox names only
after the child authority binding is reloaded. The child path intentionally
passes mcp: nil
(gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task_dispatcher.rb:145-166;
gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:721-728, 1220-1228).
The existing F25-REL-01 child MCP ambiguity is carried forward to F25 and is
not duplicated here.

## Lens: reliability and durability — reviewed

Remote execution enters the ordinary effect journal through SessionEffects and
uses request identity, authority revision, and MCP catalog revision
(gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:75-86,
135-156). Invocation distinguishes pre-send from post-send failures and the
builder maps ambiguous remote outcomes to EffectUnknownError
(gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:267-305, 382-404,
489-509; gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:140-162).
Catalog and source pins stop ordinary snapshot drift on resume. F18-SEC-01
shows that this durability boundary excludes policy settings that influence
effect classification and database validation.

Child creation, parent authority binding, request enqueue, worker claim,
terminal transition, and adoption have durable seams. A child profile digest is
checked against the current trusted profile before child session construction.
The child-runtime test proves reopen, CAS completion, enqueue/adopt exactly
once, changed-profile refusal, and sibling concurrency refusal.

The browser adapter has fail-closed behavior when no external connector is
present, but no live connector is registered in this repository. This is the
documented partial Phase 4 boundary and is recorded as information below.

## Lens: observability and evidence — reviewed

Typed MCP errors, catalog/source mismatch errors, effect receipts, child
completion digests, and status transitions preserve refusal and outcome
categories. MCP result observations include source attribution and truncation
metadata
(gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb:39-50, 614-665;
gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:229-263).
Child authority bindings retain parent profile, request/thread identity,
authority revision, profile digest, and child capabilities
(gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1087-1104).

The source-level provenance map is optional at McpCapabilitySource construction:
source_digests defaults to an empty map and is copied without exact-key or
digest validation
(gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_capability_source.rb:50-74,
208-221). The production McpSourceBuilder supplies a map, so this is an
evidence/contract limitation of caller-supplied sources rather than a proven
CLI/worker bypass. F18-OBS-01 records that boundary. The status peek exposes
read_only_tools but not the database sidecar policy
(gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:206-220).

## Lens: scalability and resource bounds — reviewed

Per MCP server, catalog entries are bounded by ServerConfig budgets and
Invocation bounds arguments, output, and transport behavior. Child task text,
capabilities, depth, concurrency, preview, and child list reads are bounded
(gems/tamoz-mcp/lib/tamoz/mcp/server_config.rb:59-111;
gems/tamoz-mcp/lib/tamoz/mcp/catalog.rb:107-113;
gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task.rb:12-25,
257-281; gems/tamoz-agent-capabilities/lib/tamoz/agent/child_task_dispatcher.rb:13-20).

There is no aggregate MCP server or descriptor bound. McpSourceBuilder maps all
configured server entries and materializes one catalog/supervisor per entry,
while CapabilityBinding appends all MCP names to the host surface
(gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:50-64,
257-280; gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:302-310).
F18-SCL-01 records the resulting aggregate resource and prompt-surface risk as
minor because the input is operator configuration and each individual server
is bounded.

No load, soak, or many-server experiment was run. The conclusion is from the
unbounded source loop and aggregate surface construction, not a claim about a
particular deployment limit.

## Lens: maintenance and architecture — reviewed

Dependency direction is explicit: the capability gem owns the binding and
duck-typed MCP source contract, tamoz-mcp owns protocol/catalog/supervision,
tamoz-tools owns the generic host, and tamoz-agent-session owns journal and
resume wiring. The registry is sealed after construction and the host has no
source-specific dispatch branches
(gems/tamoz-tools/lib/tamoz/tools/capability_host.rb:13-23,
137-171). No duplicated domain catalog or diagnosis data was found in this
surface; runtime policy arrives as operator data and the child profile is
canonicalized.

F18-COR-01 is a small public API invariant gap: source IDs are treated as
unique by dispatcher storage but are not rejected at Registry construction.
The browser source is a public, tested adapter seam rather than a registered
built-in source. Phase 4 documentation explicitly says that no end-to-end
browser mission or connector registration is delivered
(docs/openclaw-intelligence-study/implementation-plan/05-phase-4-governed-expansion.md:14-19;
docs/openclaw-intelligence-study/implementation-plan/evidence/phase-4/implementation-review.md:50-61).

## Tests, contracts, and probes

Focused tests were run one file per command. All listed passing commands used
the pinned Ruby environment via the repository's normal test load path.

| Command | Result |
|---|---|
| ruby -Itest test/capability_registry_test.rb | 9 runs / 28 assertions / 0 failures / 0 errors |
| ruby -Itest test/capability_host_test.rb | 21 runs / 91 assertions / 0 failures / 0 errors |
| ruby -Itest test/agent_phase4_capability_test.rb | 7 runs / 31 assertions / 0 failures / 0 errors |
| ruby -Itest test/agent_child_task_runtime_test.rb | 4 runs / 11 assertions / 0 failures / 0 errors |
| ruby -Itest test/agent_mcp_capability_source_test.rb | 14 runs / 102 assertions / 0 failures / 0 errors |
| ruby -Itest test/agent_worker_mcp_test.rb -n '/test_(?!the_worker_calls_a_real_mcp_server_over_http)/' | 10 runs / 32 assertions / 0 failures / 0 errors |
| ruby -Itest test/agent_governed_database_source_test.rb | 2 runs / 7 assertions / 0 failures / 0 errors |
| ruby -Itest test/agent_cli_mcp_test.rb | 6 runs / 28 assertions / 0 failures / 0 errors |
| ruby -Itest test/agent_mcp_adversarial_test.rb | 8 runs / 41 assertions / 0 failures / 0 errors |
| ruby -Itest test/capability_closed_world_test.rb | 3 runs / 14 assertions / 0 failures / 0 errors |
| ruby -Itest test/capability_descriptor_contract_test.rb | 4 runs / 18 assertions / 0 failures / 0 errors |
| ruby -Itest test/capability_inventory_test.rb | 3 runs / 18 assertions / 0 failures / 0 errors |
| ruby -Itest test/mcp_server_config_test.rb | 39 runs / 321 assertions / 0 failures / 0 errors |
| ruby -Itest test/mcp_catalog_test.rb | 9 runs / 80 assertions / 0 failures / 0 errors |
| ruby -Itest test/mcp_invocation_test.rb | 31 runs / 208 assertions / 0 failures / 0 errors |
| ruby -Itest test/public_api_test.rb | 3 runs / 1051 assertions / 0 failures / 0 errors |

Passing focused total: 173 runs / 2081 assertions / 0 failures / 0 errors.

The full command ruby -Itest test/agent_worker_mcp_test.rb reached 11 runs and
32 assertions with 0 failures and 1 error. Its HTTP fixture test failed before
the fixture server started with Errno::EPERM binding 127.0.0.1:0 at
test/support/mcp_http_fixture_server.rb:13. The filtered command above reran
the other 10 tests successfully. This is an environment restriction, not a
production assertion.

The no-network source digest probe constructed one ServerConfig and computed
the production source digest for two different sidecar settings:

    {"read_only_tools"=>["query"], "database"=>{"max_rows"=>10}}
    {"read_only_tools"=>[], "database"=>false}

Both produced sha256:de24b9cd6db94ed553d9cab41aad26c639bb270873efcd8c760d051e4f4c0d42.
ServerConfig#describe reported neither read_only_tools nor database.

The no-network sealed-host probe built two valid Capability::Source values with
the same source_id local. Registry.build accepted both; CapabilityHost rejected
the second dispatcher binding and routed both descriptor IDs through the first
dispatcher. No production CapabilityBinding path creates this duplicate shape.

The no-network source-container probe built a valid catalog and descriptor
without source_digests. McpCapabilitySource accepted it and exposed
mcp_source_digests as {}. No test was found that requires an exact source
digest map for every catalog.

## Findings

### F18-SEC-01 — MCP source resume pins omit operator policy that changes effect and validation semantics

| Field | Content |
|---|---|
| Severity | major |
| Confidence | high |
| Status | open |
| Seam | gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb#record_source_digest! and Session MCP binding |
| Source evidence | McpSourceBuilder reads settings["read_only_tools"] to choose each descriptor effect class (mcp_source_builder.rb:80-89, 202-204), and settings["database"] to install the query/row policy (mcp_source_builder.rb:125-138, 182-189). It records source_digests from only config.describe (mcp_source_builder.rb:191-195). ServerConfig#describe contains transport/config/budgets but neither sidecar setting (tamoz-mcp/server_config.rb:158-174). Session records and compares the source digest map (session_bindings.rb:34-41; session.rb:233-248). CapabilityBinding maps effect class to approval and retry behavior (capability_binding.rb:201-209, 362-371). |
| Test/contract evidence | The inline source digest probe above produced the same digest for read-only/database policy variants. Existing worker and CLI tests prove those settings change behavior (test/agent_worker_mcp_test.rb:135-161; test/agent_governed_database_source_test.rb:26-35), but no test changes a sidecar policy while keeping the catalog identical and asserts resume refusal. |
| Scanner signal | Existing F09/F10 reports identified MCP source construction and policy wiring; neither recorded that builder-consumed sidecar settings are outside the source digest. |
| Independent judgment | Confirmed. A session can resume with an unchanged catalog and unchanged source digest after an operator changes read_only_tools or database policy. A tool can move between unknown/bounded approval-required/non-retryable and read_only/no-approval/read-only-retry behavior without the MCP resume guard stopping. Database max_rows and write-query validation can also change while the recorded source binding remains equal. The model or MCP server cannot author these settings; this is operator-policy drift across a durability boundary. |
| Five whys | 1. Resume accepts changed policy because stored and current mcp_source_digests remain equal. 2. They remain equal because the builder hashes only ServerConfig#describe. 3. ServerConfig#describe omits settings consumed separately by the builder. 4. The sidecar policy is applied after configuration object creation, with no canonical payload joined to the source digest. 5. No invariant or end-to-end test requires every builder-consumed authority input to be represented in the source binding. |
| Recommendation | At the existing builder seam, hash a canonical payload containing config.describe plus every policy setting consumed by build_server, at minimum normalized read_only_tools and database options, and pass that digest into McpCapabilitySource. Add a resume test that changes each policy while keeping the catalog snapshot unchanged and expects McpCatalogSnapshotUnavailableError before a step runs. |
| Disposition | Open. This is distinct from CF05-SEC-01 (profile/MCP name admission), F09-SEC-01/F09-SEC-02 (remote description and elicitation handling), F09-COR-01 (duck-typed read_only divergence), and F10-SEC-03/F10-SEC-04 (websearch egress and sanitizer wiring). |

### F18-COR-01 — the sealed registry accepts duplicate source IDs although host dispatch has one implementation slot per ID

| Field | Content |
|---|---|
| Severity | minor |
| Confidence | high |
| Status | open |
| Seam | gems/tamoz-core/lib/tamoz/core/capability/registry.rb#build and gems/tamoz-tools/lib/tamoz/tools/capability_host.rb#bind_dispatcher |
| Source evidence | Registry checks built-in prefixes and descriptor ID collisions but never checks source.source_id uniqueness (registry.rb:69-112). CapabilityHost stores dispatchers in a hash keyed by source ID and refuses a second binding (capability_host.rb:102-123), then resolves each descriptor through the first source found with that descriptor definition (capability_host.rb:147-157; registry.rb:45-48). |
| Test/contract evidence | The no-network host probe accepted two Capability::Source values with source_id local, rejected the second dispatcher binding, and dispatched both IDs through the first dispatcher. test/capability_registry_test.rb:116-125 covers duplicate descriptor IDs across different sources, but no test covers duplicate source IDs. |
| Scanner signal | None; found while checking whether sealed source provenance and per-source routing agree. |
| Independent judgment | Confirmed as a public contract edge with limited current reachability. CapabilityBinding creates one local source, one skill source per epoch, and groups remote descriptors by source ID (capability_binding.rb:261-310), so the normal production path does not generate the duplicate shape. A caller of the public CapabilityHost/Registry API can construct it, however, and receive a sealed surface whose second source cannot receive its own dispatcher. |
| Five whys | false |
| Recommendation | Reject duplicate source.source_id values in Registry.build before build_registry and add one focused host/registry test. |
| Disposition | Open minor API invariant debt; no current production caller was found, so this is not promoted to a major authority finding. |

### F18-SCL-01 — MCP server and descriptor aggregation has no global resource bound

| Field | Content |
|---|---|
| Severity | minor |
| Confidence | high |
| Status | open |
| Seam | gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb#server_configs/build |
| Source evidence | McpSourceBuilder accepts every mapping in sources.mcp.servers and iterates all configs, compiling and materializing one catalog/supervisor per entry (mcp_source_builder.rb:50-64, 71-78, 257-280). Catalog limits are per server (tamoz-mcp/catalog.rb:107-113); CapabilityBinding then appends all source names into one ordered host surface (capability_binding.rb:302-310). No total server or total descriptor cap exists in these seams. |
| Test/contract evidence | Per-server catalog and transport bounds pass in test/mcp_server_config_test.rb and test/mcp_catalog_test.rb. No test or configuration contract was found for maximum server count, total descriptors, aggregate planning bytes, or supervisor count. |
| Scanner signal | None; found by comparing per-server budget fields with the aggregate builder loop. |
| Independent judgment | Confirmed boundedness gap. A large operator configuration can create an unbounded number of supervisors and aggregate MCP names/descriptions, despite each server individually respecting its catalog budget. It cannot be authored by workspace content, and no load experiment was run; the immediate impact is startup/memory/prompt pressure under operator configuration. |
| Five whys | false |
| Recommendation | Add a simple aggregate server/descriptor admission limit before catalog materialization, and reject the complete configuration when it exceeds that limit. |
| Disposition | Open minor scalability debt; no existing CF05/F08/F09/F10/F25 finding owns this aggregate MCP limit. |

### F18-OBS-01 — caller-supplied MCP sources may omit the source provenance map

| Field | Content |
|---|---|
| Severity | info |
| Confidence | medium |
| Status | unconfirmed |
| Seam | gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_capability_source.rb#initialize |
| Source evidence | source_digests defaults to {} and the constructor only stringifies/freezes the supplied map; it does not require one digest per catalog or validate digest shape (mcp_capability_source.rb:50-74, 208-221). SessionBindings records that map as the resume source pin (session_bindings.rb:34-41). |
| Test/contract evidence | The no-network source-container probe built a valid catalog and descriptor without source_digests and observed mcp_source_digests == {}. Existing hand-built source tests omit source_digests (test/agent_mcp_capability_source_test.rb:144-169, 296-329). The production builder supplies source digests at mcp_source_builder.rb:169-178. |
| Independent judgment | Confirmed acceptance behavior; intent is unconfirmed. The production CLI/worker path supplies a map, but the public caller-supplied source contract permits a catalog-only pin, so full transport/policy provenance is not guaranteed at this gem boundary. |
| Five whys | false |
| Recommendation | Decide whether source provenance is mandatory for every MCP source. If it is, require an exact valid digest map keyed by every catalog server; otherwise document the catalog-only mode and keep it out of claims that the source configuration is resume-pinned. |
| Disposition | Unconfirmed contract limitation; not duplicated with F18-SEC-01, which is a production builder digest omission. |

### F18-MNT-01 — browser governance is an injected adapter seam with no sealed-catalog reachability

| Field | Content |
|---|---|
| Severity | info |
| Confidence | high |
| Status | open |
| Seam | gems/tamoz-agent-capabilities/lib/tamoz/agent/governed_browser_source.rb and CapabilityBinding source construction |
| Source evidence | agent_capabilities.rb requires GovernedBrowserSource, and the gemspec/public API expose it, but CapabilityBinding constructs only local, skill, and MCP/websearch sources (agent_capabilities.rb:12-17; capability_binding.rb:261-310). GovernedBrowserSource refuses before network action without an injected adapter (governed_browser_source.rb:46-55, 163-175). |
| Test/contract evidence | test/agent_phase4_capability_test.rb:130-201 exercises the browser adapter directly with a nil or injected adapter. The Phase 4 implementation review states that no live browser connector registration or network execution is delivered (docs/openclaw-intelligence-study/implementation-plan/evidence/phase-4/implementation-review.md:50-61). |
| Independent judgment | Confirmed design limitation, not an authority bypass. The browser adapter's URL, output, and final-location controls are tested in isolation, but no browser descriptor can reach the sealed host in the current production path. This resolves the earlier F09 uninvestigated lead; it is an explicit partial-phase boundary. |
| Five whys | false |
| Recommendation | Keep the public contract explicit that this is an injected adapter seam, or add a deliberate browser source registration only when an approved connector exists; add a reachability test for the chosen state. |
| Disposition | Open information item. No live browser mission is claimed and no existing F09/F10 finding is duplicated. |

## Carried forward and overlap

- CF05-SEC-01 remains owned by the profile/MCP admission contract. This report
  does not re-litigate whether configured MCP names should intersect a trusted
  profile; it records only source-policy digest drift after admission.
- F08-SEC-01 remains the local check credential-environment finding. No child
  task or capability binding path was used to duplicate it.
- F09-SEC-01, F09-SEC-02, and F09-COR-01 remain MCP description, elicitation,
  and duck-typed descriptor findings. F18 verified their call sites while
  checking the common binding but does not restate them.
- F10-SEC-01, F10-SEC-03, and F10-SEC-04 remain websearch endpoint, egress
  comparison, and sanitizer-wiring findings. F18 records that websearch enters
  through the same MCP builder, but does not duplicate those adapter defects.
- F25-SEC-01 remains parent profile resume verification, and F25-REL-01
  remains the unconfirmed child MCP path question. The child dispatcher and
  runtime narrowing path were checked for bypass and no new bypass was proven.

## Blind spots

- No full CI, ci_full, RuboCop, Enola, or quality gate was run, per the bounded
  read-only brief.
- The full worker MCP file could not run its local HTTP fixture because the
  sandbox denied bind(2); the other ten tests in that file passed separately.
- No real external provider or live browser connector exists in this checkout,
  so no real browser execution or browser cross-process evidence is claimed.
- No load/soak/many-server experiment was run. F18-SCL-01 is based on the
  unbounded aggregate loop and per-server-only limits.
- The generic duplicate source ID and optional source digest behaviors were
  proven with no-network probes, but no external embedding currently calls the
  generic API with those shapes. Their production reachability is therefore
  limited or unconfirmed.
- The report reads the session and worker seams necessary to prove dispatch,
  journal, resume, and child authority. Defects wholly inside unrelated
  session, SQLite, approval, or MCP transport responsibilities remain with
  their owning rows.

## Report metadata and completion

- Files changed: docs/audits/functionality-audit-2026-09-15/analyses/F18-capabilities.md; docs/audits/functionality-audit-2026-09-15/analyses/F18-capabilities.json; /tmp/tamoz-agents/audit_f18_capabilities.log.
- Exact passing command total: 173 runs / 2081 assertions / 0 failures / 0 errors across the commands listed above.
- Deviation: ruby -Itest test/agent_worker_mcp_test.rb had 1 sandbox EPERM error on the local HTTP fixture bind; the remaining 10 tests passed with the filtered command listed above.
- No implementation, test, config, README, existing audit, or other repository file was edited. The tracked production/test/config diff from baseline is empty; only the two owned F18 analysis files were created in the audit package by this unit.
- Created report files are mode 0644. No scratch files were left in the repository.
