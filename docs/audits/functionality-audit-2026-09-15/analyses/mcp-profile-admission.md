# CF05-SEC-01 — profile-bound sessions admit every configured MCP capability

| Field | Assessment |
|---|---|
| Functionality | CF05 trusted authority, capability intersection, and governed egress; affected F09/F10/F18/F21/F24/F25 |
| Severity | **Major** if a trusted profile is the session-wide capability ceiling; the missing ceiling can expose remote reads and effects. |
| Confidence | **High** for the observed surface and dispatch path; **medium** for the contract violation because the repository also describes runtime MCP configuration as independent operator authority. |
| Status | **Open; contract decision required** |
| Scanner signal | A profile with only local `read_file` still receives MCP IDs from the configured runtime source. |
| Independent judgment | Confirmed behavior. The host is correctly sealed against the admission set it receives; the gap is that MCP names are admitted upstream without a profile intersection. |

## Finding and exact trigger

Create a trusted profile whose `tools.allowed` contains only `read_file`, enable an
MCP server in the operator runtime directory, and start a durable session with that
profile. The CLI derives the local toolbox from the profile, including its narrowed
allowlist (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:665-684`). In the same path,
`run_durable` builds MCP independently and passes both objects to `Session`
(`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:579-598,621-635`).

`build_mcp_source` checks that the runtime directory's workspace matches the profile
root, then builds every enabled MCP source; it does not ask the profile for a server
or capability admission (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:650-662`). The
worker follows the same shape: `build_session` defaults `mcp` to the complete
`mcp_source` while it derives the profile's local toolbox (`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1030-1055,1195-1208`).

Session construction validates only the MCP duck-type and the profile's toolbox
catalog/root (`gems/tamoz-agent-session/lib/tamoz/agent/session_options.rb:129-175`).
There is no profile MCP field or source-qualified allowlist: the profile schema's
tools are the six local names (`gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:64-89`),
and `AuthorityValidator#tools!` accepts only those names
(`gems/tamoz-agent-profile/lib/tamoz/agent/profile/authority_validator.rb:44-55`).

The binding then constructs the host admission set as local toolbox names plus every
`@mcp.names` (`gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:161-169`),
and passes that set to the sealed registry (`:302-305`). The resulting capability
names are exactly what session effects expose to planning
(`gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:337-352`); the plan
prompt includes the MCP surface and the accepted plan can route execution through
the MCP dispatcher (`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_attempt.rb:49-65,120-128`; `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:180-183`).

A bounded, no-network probe used a toolbox restricted to `['read_file']`, a fake
MCP source exposing `mcp:probe/set_answer`, and a non-nil profile argument. It
reported:

```text
profile_local_allowlist=["read_file"]
model_surface=["read_file", "mcp:probe/set_answer"]
mcp_descriptor_visible=true
mcp_dispatch_result={"executed":"mcp:probe/set_answer", ...}
```

The probe output is logged at `/tmp/tamoz-agents/analyze_mcp_admission.log`; no real
provider or repository scratch was used.

## Six-lens impact

| Lens | Assessment |
|---|---|
| Correctness | The model-visible and dispatchable surface is wider than the profile's apparent `tools.allowed` ceiling. Read-only MCP tools can execute without an approval request; unknown-effect tools are still approval-gated (`gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:201-205,362-368`). |
| Security/authority | This is an authority boundary gap if profiles are intended to constrain the whole session: a profile cannot prevent a configured remote capability. The workspace cannot create the source because the runtime directory is operator-owned, so this is not a content-grant path. |
| Reliability/durability | MCP catalog/source digests are pinned in session records (`gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:34-41`), and profile identity is separately pinned (`:51-61`). No record binds the two admission decisions, so resume proves catalog/profile identity but not profile-to-MCP authorization. |
| Observability/evidence | Status/peek and session records can show a configured source and its catalog digest, but there is no explicit admission reason or effective profile/MCP intersection to explain why the remote IDs were visible. |
| Scalability/resource bounds | Catalog and descriptor sizes are bounded by MCP configuration; no independent unbounded-work defect was found. Every configured server's catalog can nevertheless widen the model prompt up to those bounds. |
| Maintenance/architecture | Authority is split between profile schema, runtime source configuration, and approval policy. `CapabilityHost` correctly documents a policy-derived admission set, but the producer silently treats catalog membership as MCP authority. |

## Contract challenge

There is credible evidence that independent operator configuration may be intentional:
`RuntimeDirectory` calls the runtime directory “the only place its authority comes
from” and says everything there is operator authority (`gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:10-28`); the MCP builder says server list and risk classification come from that directory (`gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:5-27`); and the test harness explicitly scopes the trusted profile to project-local `tools.allowed` (`test/support/autonomy_case.rb:269-297`). P10 also says MCP effect class comes from local policy and unlisted tools fall to unknown effects (`docs/P10_MCP_PLAN.md:146-150`). Under that model, the observed behavior is an intentional two-authority design.

The conflicting contract is P18: it says MCP/websearch register “if profiles admit” and
defines the admission set as the already-intersected result of
`build_profile_toolbox` and `verify_profile_binding!` (`docs/P18_CAPABILITY_HOST_PLAN.md:60-72`).
Invariant 35 requires effective authority to intersect current application/agent/task/
parent limits (`docs/design-v0.1/INVARIANTS.md:82-88`). P17 further says websearch
egress is a P8 profile extension (`docs/P17_WEBSEARCH_PLAN.md:67-95`). The checkout
does not state which authority wins for a profile-bound session, so the safety claim
cannot be evaluated deterministically.

## Test and prior-review gap

`test/capability_host_test.rb:403-416` proves a withheld **local** tool is absent, while
`:418-439` proves MCP dispatch routing. `test/agent_cli_mcp_test.rb:21-53` exercises
configured MCP with no `--profile`. `test/agent_worker_mcp_test.rb:65-97` exercises
the worker source without a restrictive profile. No test combines a restrictive
trusted profile with configured MCP and asserts either absence or intentional
independent admission. Profile tests cover local names only (`test/agent_profile_test.rb:55-63`).
No earlier audit directly records this combined path; the handover review only warns
that MCP and skills could become alternate authority paths (`docs/reviews/PROJECT_HANDOVER_PLAN_REVIEW.md:18-21`).

## Five whys

1. A restrictive profile sees MCP because `CapabilityBinding#admission_set` appends all MCP names.
2. It does so because the binding treats the caller's catalog as MCP authority.
3. The profile cannot narrow that set because its schema has no source-qualified MCP authority.
4. P10 implemented operator runtime configuration as the local MCP policy while P18 described profile admission without defining the data path.
5. The phases kept separate authority vocabularies and never added an end-to-end negative test for profile plus configured MCP.

## Recommendation and disposition

First choose and document one contract. If a trusted profile is the session-wide ceiling,
add a bounded source-qualified MCP/websearch allowlist to the profile authority and its
digest, then intersect it at the existing `CapabilityBinding` admission-set seam before
the host is built. Preserve the existing catalog pin and reject an unadmitted plan before
any network/process I/O. If runtime configuration is intentionally independent
authority, correct P18 and the host/profile comments to say that explicitly, expose the
effective source authority in status, and add a regression proving a restrictive profile
still intentionally admits configured MCP while approval/egress remain separate gates.

Add one end-to-end case with only `read_file` in the trusted profile and both a
read-only and an unknown-effect MCP tool. Assert the chosen model surface, plan
validation, approval behavior, and dispatch result. Until that decision and test exist,
keep this as an open major CF05 finding. If independent runtime authority is ratified,
the code finding should be downgraded to an information/documentation gap; the current
behavior itself is confirmed.

**Blind spots:** the probe stopped at the binding/dispatcher seam and used a fake source;
it did not start a real MCP server, call a real provider, or run the full CLI with a
loaded YAML profile. Those limitations do not affect the source-level admission result.
