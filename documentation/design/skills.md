# Portable Agent Skills

Tamoz implements the open Agent Skills specification directly: a skill is a directory containing `SKILL.md` and optional `scripts/`, `references/`, and `assets/`, consumed through progressive disclosure with immutable identity and no implicit authority. Source: [`docs/design-v0.1/SKILLS_DESIGN.md`](../../docs/design-v0.1/SKILLS_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## What a skill is — and is not

A skill supplies instructions and resources. It is not a tool, plugin, credential bundle, policy, or sandbox; it is not a permission grant; it is not trusted because it is local; it is not automatically correct because its syntax validates; and it is not mutable during an execution. Skills live in `tamoz-agent`; the reusable contracts are the skill source, the catalog, and content-addressed skill snapshots.

## Format and frontmatter

Tamoz accepts the specification's required `name` and `description` plus optional `license`, `compatibility`, `metadata`, and experimental `allowed-tools`:

```yaml
---
name: release-ruby-gem
description: Prepare and verify a Ruby gem release. Use for versioning, changelog, build, and release checks.
license: Apache-2.0
compatibility: Requires Ruby, Bundler, Git, and network access for publishing.
metadata:
  author: example
  version: "1.2.0"
  tamoz.risk: guarded
  tamoz.eval-suite: release-ruby-gem-v3
---
```

Tamoz extensions use flat `tamoz.*` keys inside `metadata` with string values (the portable metadata contract is string-to-string); the portable base format remains valid in other compatible agents. The `allowed-tools` field is interpreted only as the skill author's requested **upper bound** — it never pre-approves anything. The effective tool set is:

```text
agent grant ∩ task/plan grant ∩ schedule/parent grant ∩ skill requested maximum
```

Unknown portable fields are retained for round-trip compatibility and ignored for authority; unknown `tamoz.*` keys fail validation until the extension version declares them.

## Snapshots and immutable identity

Source content compiles into an immutable `SkillRecord`: source-qualified id, version, source and revision, **tree digest** (over `SKILL.md` and every reachable bundled file, using canonical relative paths, content digests, file types, and executable bits), manifest and description digests, trust, requested capabilities, risk, compatibility, license, resource index, evaluation evidence, and install time. FIFOs, devices, sockets, hard-link escapes, absolute paths, `..`, case-fold collisions, unsafe symlinks, and oversized/deep trees are rejected.

The execution identity is `(source, name, tree_digest)` — not a mutable path or self-claimed version. Version is display metadata; it cannot prevent a same-version content swap.

## Sources, scope, and collision

Configured sources may include workspace/project skills, operator-managed skills, personal skills, bundled skills, and explicitly installed registry or Git artifacts — each with an owner, scope, trust, read roots, update policy, and precedence. Discovery never silently resolves same-name collisions across trust boundaries; a collision requires an explicit source-qualified binding or a recorded override decision, so a workspace skill cannot impersonate a managed skill by using its name.

## Loading and progressive disclosure

Four bounded stages:

1. **discover** — inject or search source-qualified names, descriptions, version, risk, and availability;
2. **load** — `load_skill` returns the delimited `SKILL.md` body and immutable identity;
3. **read** — `read_skill_resource` reads one indexed reference/asset on demand (canonical relative path, realpath checked on every access, digests verified, bytes and MIME bounded);
4. **execute** — a bundled script may run only through an ordinary authorized execution tool.

The model may select a skill, but explicit user invocation wins when authorized; selection records the considered candidates, reason, selected digest, and who invoked (user, rule, or model). A skill's body is attributed untrusted instruction content below system/application policy.

## Catalog and cache epochs

At a turn boundary the catalog compiler discovers configured sources without following untrusted escapes, parses YAML safely (no object deserialization or aliases), validates the schema and extension version, computes content digests and compatibility, applies binding/visibility/trust/policy, and emits a canonical snapshot with a catalog digest. The snapshot is pinned by the behavior version and prompt-cache epoch. File watchers, installs, updates, or remote availability produce a candidate next snapshot; they never replace the body or resources of a loaded skill mid-turn. Resume requires the exact tree digest or stops with `skill_snapshot_unavailable`.

## Compilation never executes

Loading a skill never executes installation hooks, scripts, or commands — **compilation is inert**. A script request passes through the same lifecycle as any other action:

```text
accepted plan → exact script digest → interpreter/tool policy → sandbox/preflight
              → effect classification → approval if required → execute → verify
```

Scripts receive an explicit working directory, arguments, input files, environment allowlist, egress policy, time/output/resource budgets, and credential handles; secrets are injected by the execution boundary only when policy permits and never substituted into skill text. Remote skill resources are staged and content-addressed before activation; Tamoz does not fetch mutable remote code during skill execution.

## Supply-chain promotion (installation and updates)

Installation is a staged workflow: resolve an immutable source, download to quarantine, verify expected digest/signature/provenance when available, unpack with size/path/link limits, validate license/manifest/resources, run a static security review and capability diff, evaluate, obtain human/policy approval, install atomically as a content-addressed artifact, and emit a candidate catalog epoch. Registry verification or a trusted publisher raises provenance confidence; it does not make instructions or code safe. Updates display semantic and byte-level changes; auto-update is allowed only for content-only, capability-nonwidening artifacts under an explicit operator policy, and activation remains a new digest/epoch. Generated skills are candidates: promotion requires validation, held-out trigger/evaluation, injection/path/secret/escalation tests, baseline comparison, and human approval for scripts or capability widening — and the agent cannot use a candidate's own instructions to evaluate or approve it. Uninstall tombstones the binding and preserves provenance/audit evidence.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`./mcp.md`](./mcp.md) — the sibling capability surface (MCP)
- [`../guides/agent-operator.md`](../guides/agent-operator.md) — managing skills as an operator
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract
- [`../../docs/design-v0.1/SKILLS_DESIGN.md`](../../docs/design-v0.1/SKILLS_DESIGN.md) — the authoritative design record
