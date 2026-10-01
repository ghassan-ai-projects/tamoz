# ADR-030 — One local capability catalog governs all sources

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Amended by:** [ADR-054](./adr-054-websearch-capability-source.md) (websearch is the fourth source)
**Relates to:** [ADR-014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) (the source set is closed), [ADR-053](./adr-053-approval-gem.md) (approval policy reads the application-assigned class)

Every capability — local tool, skill, MCP tool, websearch — is a content-addressed descriptor in one
local catalog. The application, never the source, assigns trust, effect class, and scope; effective
access is the intersection of every limit that applies.

## Context

Tools arrive from different trust boundaries: Tamoz's own toolbox, operator-installed skills,
remote MCP servers, the web. Each carries metadata that could claim authority ("read-only", an
`allowed-tools` list). Without one authority model, a remote server or a skill could grant itself
access by describing itself.

## Decision

- Each capability is a source-qualified descriptor whose definition digest covers every policy and
  schema field. An unknown effect class or policy value fails closed.
- Only the application assigns trust, effect class, scope, and authority. MCP annotations, skill
  `allowed-tools`, memory, and model output may request or narrow, never grant.
- Effective access = application ∩ agent profile ∩ accepted plan ∩ parent or schedule ∩ source
  limits. Revoking any one revokes access. (In the coding work loop the accepted plan constrains only
  its plan-bound tools; ADR-022.)
- The source set is closed at four: local tools, skills, MCP, websearch (ADR-054). The catalog for
  a turn is sealed at session construction; a change takes effect only at an explicit turn
  boundary as a new epoch.

## Consequences

One place answers "may this call happen". **Cost:** a source can only narrow authority, so a
well-behaved MCP server's "read-only" claim still needs the operator to classify it.

## Invariants

- 35 — capability authority is local, intersected, and content-addressed.
- 36 — catalog snapshots are explicit and pinned.

## Threat model

**Asset:** what tools the agent may call and with what effect. **Adversary:** a malicious MCP
server, skill author, or injected model output.

| Threat | Mitigation |
|---|---|
| A source declares itself read-only to dodge approval | Application assigns the class; unclassified tools fall to the fallback tier (ADR-053), which asks — except under `auto`, where it allows |
| A skill's `allowed-tools` widens access | Request-only; intersection can only narrow |
| A tool is swapped mid-turn | Catalog sealed per turn; changes are a new epoch |
| A descriptor is edited after review | Definition digest verified against every field |
| A bound thread resumes under a widened profile | Refused by profile digest (ADR-053) |

**Residual risk:** the operator's own classification can be wrong — classifying a dangerous MCP
tool as `read` grants it.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Import MCP annotations or skill `allowed-tools` as permissions | Content from another trust boundary can only request or narrow |
| One catalog per source with its own policy *(retrospective, 2026-10-01)* | Authority logic drifts per source; the intersection rule needs one place |

## Reopen when

A fifth source kind is needed, or a source offers authenticated, operator-pinned capability
metadata that could safely pre-fill classification.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Four sources dispatch through one protocol | `gems/tamoz-tools/lib/tamoz/tools/capability_host.rb` | `test/capability_closed_world_test.rb` — `test_four_built_ins_dispatch_through_one_protocol` | — |
| Descriptor digests cover every field; unknown classes fail closed | descriptor contract | `test/capability_descriptor_contract_test.rb` — `test_definition_digest_is_verified_against_all_descriptor_fields`, `test_unknown_effect_class_and_policy_values_fail_closed` | — |
| A widened profile is refused for a bound thread | worker runtime | `test/agent_worker_profile_digest_test.rb` — `test_a_widened_on_disk_profile_is_refused_for_a_bound_thread` | — |
