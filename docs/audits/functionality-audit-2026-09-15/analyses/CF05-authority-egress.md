# CF05 trusted authority, capability intersection, and governed egress — IMPROVE

Row / queue / baseline / analyst

- Row: **CF05** — trusted authority, capability intersection, and governed egress.
- Queue: cross-gem flow inventory in `COVERAGE.md`.
- Code baseline: `audit-15-09` at `582ae55`, 2026-09-15.
- Analyst: coordinator direct read-only review after the cross-flow scanner and
  the independent authority challenge. No subagent was used for this continuation.
- Scope: profile loading, runtime source construction, capability admission,
  session pins, MCP dispatch, and the operator-side websearch egress adapter.

## Source map and boundary

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb` | 64-103 | trusted profile schema; local tool and egress vocabularies |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/authority_validator.rb` | 44-66 | profile tool/policy validation |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/egress_validator.rb` | 31-58, 72-143 | profile egress validation and bounds |
| `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb` | 10-27, 43-133 | operator-owned source authority and closed source set |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` | 579-635, 650-684 | durable CLI profile/toolbox/MCP construction |
| `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb` | 917-923, 1030-1055, 1195-1208 | worker MCP source, profile toolbox, session construction |
| `gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb` | 5-27, 50-87, 239-297 | operator MCP/websearch catalogs, descriptors, subprocess config |
| `gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_capability_source.rb` | 40-114, 160-176, 224-228 | frozen catalog/descriptors and source digests |
| `gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb` | 161-169, 201-248, 302-310 | sealed admission set, effect class, and dispatch routing |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_options.rb` | 129-175 | MCP duck-type and local profile/root binding checks |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb` | 34-61 | MCP, egress, and profile record bindings |
| `gems/tamoz-agent-session/lib/tamoz/agent/session.rb` | 147-166, 233-264, 439-447 | resume guards for catalog/egress and the guard sequence |
| `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch/egress_policy.rb` | 31-58, 136-231, 265-301 | validated websearch egress declaration |
| `gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch/egress_client.rb` | 41-109, 114-220 | per-hop resolve, classification, pinning, and bounded HTTP |
| `script/websearch_adapter` | 4-15, 75-118, 123-151, 170-180 | operator-side provider, grant, and `TAMOZ_WEBSEARCH_EGRESS` process boundary |

The flow has two operator-controlled inputs. The trusted profile supplies the
workspace root, local toolbox allowlist, model roles, budgets, policy versions,
and optional egress declaration. The runtime directory supplies enabled MCP and
websearch servers, server commands/endpoints, read-only classification, and the
environment allowlist. `McpSourceBuilder` turns the latter into pinned catalog
descriptors. `CapabilityBinding` then combines the local toolbox and the caller's
MCP catalog into one sealed host. Session state records the profile, MCP catalog,
source digests, and egress declaration separately and verifies the MCP and egress
pins on resume.

## Behavior path

1. `Profile` accepts only six local names in `tools.allowed`; its separate
   `egress:` section has exact host, scheme, byte, timeout, redirect, circuit,
   and credential-reference fields (`profile.rb:64-103`; validators above).
2. `CLI#run_durable` builds the profile toolbox and, independently, calls
   `build_mcp_source`. The latter checks only that the runtime workspace root
   matches the profile/root, then builds every enabled operator source
   (`cli.rb:579-635,650-684`).
3. `WorkerRuntime` caches the same runtime-directory source and passes it to a
   profile-bound `Session` while `session_toolbox` narrows only local names
   (`worker_runtime.rb:917-923,1030-1055,1195-1208`).
4. `CapabilityBinding#admission_set` appends all `@mcp.names` after local tools
   and the optional child capability. The sealed `CapabilityHost` receives that
   set before dispatchers are bound (`capability_binding.rb:161-169,302-305`).
   Remote descriptors outside the closed effect vocabulary become `:bounded`
   and require approval (`:201-209,362-371`).
5. `SessionBindings` records MCP catalogs/source digests, the canonical profile
   egress declaration, and the profile digest as separate fields
   (`session_bindings.rb:34-61`). Resume compares MCP and egress pins, but
   `Session#verify_profile_binding!` checks the toolbox catalog and root only
   (`session_options.rb:140-175`; `session.rb:233-264,439-447`).
6. For websearch, `McpSourceBuilder` passes server `env_allowlist` and
   credential-reference names, not the profile's egress mapping, to the
   supervised adapter (`mcp_source_builder.rb:239-253`). The adapter independently
   reads and validates `TAMOZ_WEBSEARCH_EGRESS`, requires the operator grant and
   provider configuration, and forwards `max_results` to the provider
   (`script/websearch_adapter:75-118,123-151,170-180`). The egress client applies
   HTTPS, exact-host, private-range, redirect, and response-byte checks on every
   hop (`egress_client.rb:77-109,130-157,168-220`).

## Lens: correctness

Reviewed. The local profile surface is derived wholesale from `tools.allowed` and
the MCP catalog is frozen and digest-pinned. MCP descriptors are visible to the
planning surface and route to the owning server; unknown effect classes fail
closed into approval-required `:bounded` descriptors. The focused local,
profile, and egress contracts passed as recorded below.

The combined behavior is confirmed: a profile restricted to `read_file` does not
remove a configured MCP name from `CapabilityBinding#admission_set`. The existing
independent challenge (`analyses/challenge-profile-authority.md`, CF05 section)
verified the same result with a no-network probe and corrected the earlier
line-number error in the capability report.

## Lens: security and authority

Reviewed. Runtime configuration is outside the workspace, the source set is
closed, descriptors are sealed, and remote metadata cannot select its own risk
class. Websearch is disabled by default unless the adapter has a validated policy,
provider, and explicit operator grant. Redirects re-run the complete egress check
and remove credential headers across an authority change.

The authority contract is nevertheless split. `runtime_directory.rb:10-27` says
the operator runtime is the only authority, while P18 and the security-model
summary describe effective authority as an intersection and say MCP/websearch
appear “if profiles admit.” The profile schema contains no source-qualified MCP
allowlist (`profile.rb:68-103`), so the code cannot implement that phrase as
written. The challenge therefore **demotes CF05-SEC-01 to `info`**, a verified
documentation/contract gap, rather than treating the deliberate operator
configuration as a confirmed authority bypass. `F10-SEC-03` is the corresponding
egress-side declaration gap and is merged into the same contract decision.

The demotion does not close the carried authority findings. A restarted worker can
run a widened profile against an existing thread (`F25-SEC-01`), a session layer
does not enforce the profile digest (`F22-SEC-01`), and the MCP sidecar policy can
drift without changing the source digest (`F18-SEC-01`). Remote description
injection and elicitation collapse remain owned by F09 (`F09-SEC-01` and
`F09-SEC-02`); endpoint validation and result-count bounds remain owned by F10
(`F10-SEC-01` and `F10-SEC-02`). Their five-whys chains and independent challenges
remain in the existing row reports.

## Lens: reliability and durability

Reviewed. Catalog snapshots and source digests are immutable at construction and
must match the session record on resume. Profile egress declarations are also
canonicalized and compared. `McpSourceBuilder` closes already-started supervisors
when construction fails (`mcp_source_builder.rb:50-68,165-167`), and the egress
client stops before dialing a refused hop. MCP execution enters the ordinary
effect-journal path through the capability dispatcher; a read-only websearch
timeout therefore follows the declared idempotent retry semantics.

The remaining durability risk is authority, not catalog replay: worker restart
uses the current profile without a general session-profile digest guard
(`F25-SEC-01`), and the session guard sequence does not add that missing check
(`session.rb:439-447`). Egress pinning can prove that the declaration changed,
but it cannot prove that the current profile is the one that accepted the plan.

## Lens: observability and evidence

Reviewed. Session records expose profile digest, MCP catalogs/source digests, and
egress pins. MCP observations are attributed and bounded by the session effect
budget; websearch results are control-stripped, secret-pattern sanitized, and
marked as remote/untrusted by the adapter and invocation layers. Refusals use
typed policy errors or an MCP error response, and an egress circuit reset requires
operator evidence.

The effective authority explanation is incomplete. A status record can show a
profile digest and a configured MCP catalog, but it does not state whether the
source was admitted by profile intersection or by independent runtime authority.
That is part of CF05-SEC-01's documentation gap. The carried F18 sidecar-policy
digest gap can additionally leave the recorded source identity weaker than the
policy that classified its descriptors.

## Lens: scalability and resource bounds

Reviewed. Profile files and egress declarations have byte/field bounds; MCP
arguments and output are bounded by `McpCapabilitySource` and the capability
descriptors; redirects, response bytes, and circuit thresholds are bounded by
`EgressPolicy`/`EgressClient`. The adapter caps query bytes but its schema has no
maximum for `max_results`; that existing F10 minor finding remains open. The
capability host also has no aggregate MCP server/descriptor limit (`F18-SCL-01`).

No sustained provider, subprocess, catalog-growth, or long-lived session load was
run here. The absence of a measurement is recorded as an evidence limitation and
does not create a new CF05 finding.

## Lens: maintenance and architecture

Reviewed. Ownership is mostly legible: profile validators own trusted data,
runtime directory owns operator source selection, capabilities own the sealed
registry, session owns durable pins, and the adapter owns network enforcement.
The maintenance weakness is duplicated authority vocabulary: profile egress is
validated and recorded in Tamoz, while the adapter validates a separate environment
declaration. `EgressPolicy` itself says any caller-side runtime comparison is
`author_claimed` and has no enforcement value, which confirms that the two values
are not compared at the seam.

The smallest architectural decision is documentation and one combined-path
contract test: explicitly ratify independent runtime authority (the current
implementation model), state that profile egress is a resume pin rather than an
adapter input, expose that effective authority in status, and test a restrictive
profile with read-only and unknown-effect MCP tools. If the owner instead ratifies
profile-wide intersection, the existing `CapabilityBinding#admission_set` is the
seam to change; no alternate source or dispatcher is needed.

## Tests and contracts

- `ruby -Itest test/capability_host_test.rb` → **21 runs / 91 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_cli_mcp_test.rb` → **6 runs / 28 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_profile_test.rb` → **44 runs / 130 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/websearch_egress_test.rb` → **10 runs / 74 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/websearch_adapter_test.rb` → **14 runs / 58 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_worker_mcp_test.rb` → **11 runs / 32 assertions / 0 failures / 1 error / 0 skips**. The only error is the sandbox's `Errno::EPERM` while the HTTP fixture tries to bind `127.0.0.1`; the other worker cases passed. No network service or real provider was used.
- No existing test combines a restrictive trusted profile with configured MCP and
  asserts the selected authority contract. That is a genuine test gap.

## Findings and disposition

No new machine-counted CF05 defect is added. The contract lead is retained as an
information-level coordinator finding, and all existing critical/major items keep
their owner, challenge, and five-whys record.

| Finding | Current disposition in CF05 | Owner / evidence |
|---|---|---|
| CF05-SEC-01 | **Info, open documentation/contract gap; demoted by the independent challenge.** The observed admission is real, but the checkout does not define a profile MCP field and the owning runtime code explicitly treats the operator directory as authority. | `CapabilityBinding#admission_set`; `challenge-profile-authority.md` CF05 section |
| F10-SEC-03 | **Merged into CF05-SEC-01; info contract axis.** The profile egress declaration is pinned but never compared with the adapter's `TAMOZ_WEBSEARCH_EGRESS`. | `McpSourceBuilder#config_arguments_for`; `script/websearch_adapter` |
| F25-SEC-01 | Carried critical, open, confirmed; no duplicate count. | `WorkerRuntime#session_for`; `challenge-profile-authority.md` |
| F22-SEC-01 | Carried major, open, confirmed; no duplicate count. | `Session#guard_state!`; `F22-agent-session.md` |
| F18-SEC-01 | Carried major, open, confirmed; no duplicate count. | MCP sidecar policy/source digest; `F18-capabilities.md` |
| F09-SEC-01 / F09-SEC-02 | Carried major/critical, open, confirmed; no duplicate count. | MCP planning/evidence boundary; `F09-mcp.md`, `challenge-mcp-websearch.md` |
| F10-SEC-01 / F10-SEC-02 | Carried major/minor, open, confirmed; no duplicate count. | websearch endpoint and result-count bounds; `F10-mcp-websearch.md` |
| F18-SCL-01 | Carried minor, open, confirmed; no duplicate count. | aggregate MCP server/descriptor bound; `F18-capabilities.md` |

## Blind spots and verdict

- The combined profile-plus-MCP probe was in-process and used a fake source; no
  real MCP server, provider, or model was called.
- The worker HTTP test could not bind a local socket under the sandbox; this is an
  environment limitation, not a passed real-server proof.
- No concurrent profile reload/restart race, egress DNS rebinding run, catalog
  growth run, or sustained subprocess/provider load was performed.
- No production code, tests, configuration, or generated artifact was changed.

**IMPROVE** under `BAR.md`: all six lenses and the end-to-end authority/egress
trace are reviewed, but this flow carries the confirmed critical/major profile,
MCP, session, and websearch findings listed above. CF05 contributes no duplicate
machine-counted finding; the own contract lead is retained as an open info-level
documentation decision until the conflicting authority language is reconciled.
