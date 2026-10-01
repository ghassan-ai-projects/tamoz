# Portable Agent Skills

Tamoz implements the open Agent Skills specification directly: a skill is a directory containing `SKILL.md` and optional `scripts/`, `references/`, and `assets/`, consumed through progressive disclosure with immutable identity and no implicit authority. Source: [`docs/design-v0.1/SKILLS_DESIGN.md`](../../docs/design-v0.1/SKILLS_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## Built and designed

Built: the compiler and tree-digest identity, the catalog, `load_skill` and `read_skill_resource`, two skill sources (the skills Tamoz ships and one operator directory), the `tamoz skills` commands, `--skill` invocation, skills in chat, the authoring bar, and a staged-candidate path that installs only what a named person approved. Designed, not built, and marked as such below: catalog search, per-source visibility and update policy, model-run scripts, and install from a registry or Git. The sections below say which is which.

## What a skill is — and is not

A skill supplies instructions and resources. It is not a tool, plugin, credential bundle, policy, or sandbox; it is not a permission grant; it is not trusted because it is local; it is not automatically correct because its syntax validates; and it is not mutable during an execution. Skills live in the `tamoz-skills` gem (ADR-056); the reusable contracts are the skill source, the catalog, and content-addressed skill snapshots.

## Format and frontmatter

Tamoz accepts the specification's required `name` and `description` plus optional `license`, `compatibility`, `metadata`, and experimental `allowed-tools` (a YAML list, or a string separated by spaces or commas, so skills written for other agents load):

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

Unknown portable fields are retained for round-trip compatibility and ignored for authority; unknown `tamoz.*` keys fail validation until the extension version declares them. Extra files beside `SKILL.md` are allowed; dotfiles (`.DS_Store`, `.git`) are neither walked, digested nor readable. The limits (description, compatibility, body, tree size, entries, depth) are the `LIMITS` constant in `gems/tamoz-skills/lib/tamoz/skills.rb`.

## Snapshots and immutable identity

Source content compiles into an immutable `SkillRecord`: source-qualified id, version, source and revision, **tree digest** (over `SKILL.md` and every reachable bundled file, using canonical relative paths, content digests, file types, and executable bits), manifest and description digests, trust, requested capabilities, risk, compatibility, license, resource index, evaluation evidence, and install time. FIFOs, devices, sockets, hard-link escapes, absolute paths, `..`, case-fold collisions, unsafe symlinks, and oversized/deep trees are rejected.

The execution identity is `(source, name, tree_digest)` — not a mutable path or self-claimed version. Version is display metadata; it cannot prevent a same-version content swap.

## Sources, scope, and collision

Built: two sources, both chosen by the operator and never discovered from the workspace.

- `bundled` — the skills Tamoz ships in `gems/tamoz-skills/skills/` (`evidence-audit`, `skill-authoring`). CLI: `--bundled-skills`; chat: `sources.skills.bundled: true`.
- `operator` — one directory outside the workspace. CLI: `--skills DIR`; chat: `sources.skills.root` (default `skills/` in the runtime directory).

A skills root and the workspace may not contain one another, in either direction, and the bundled root counts: skills are instructions, and a checkout the agent can write must not be able to write its own instructions. The check is `Tamoz::Skills.disjoint!` and it fails before any turn.

A bare name resolves only when one source provides it; otherwise the catalog lists the collision and `load_skill` fails with `skill_name_ambiguous` until the model uses the source-qualified id (`operator/name`). A workspace skill cannot impersonate a managed one.

Designed, not built: personal skills, and explicitly installed registry or Git artifacts, each with an owner, scope, trust, update policy, and precedence.

## Loading and progressive disclosure

Four bounded stages:

1. **discover** — inject (built) or search (designed, not built) source-qualified names, descriptions, version, risk, and availability;
2. **load** — `load_skill` returns the delimited `SKILL.md` body and immutable identity;
3. **read** — `read_skill_resource` reads one indexed reference/asset on demand (canonical relative path, realpath checked on every access, digests verified, bytes and MIME bounded);
4. **execute** — a bundled script may run only through an ordinary authorized execution tool.

The work loop shows the catalog if and only if `load_skill` is offered. The operator can pin a skill with `--skill NAME` (`tamoz code`, `tamoz investigate`): it loads before the first model call and stays pinned for the thread. Every load appends a `skill_loaded` trace event with the skill id, its tree digest, and who chose it (`user` or `model`). `scripts/` files are indexed for identity only; `read_skill_resource` refuses them. Designed, not built: recording the considered candidates and the reason. A skill's body is attributed untrusted instruction content below system/application policy.

## Catalog and cache epochs

Built: the catalog is compiled once when the session is built, from the configured sources, byte-bounded (`MAX_CATALOG_BYTES`), deterministic, and carries a catalog digest; a loaded skill never changes underneath a turn. Designed, not built: catalog search, per-turn recompilation with a candidate next epoch, and `skill_snapshot_unavailable` on resume. The description below is the design.

At a turn boundary the catalog compiler discovers configured sources without following untrusted escapes, parses YAML safely (no object deserialization or aliases), validates the schema and extension version, computes content digests and compatibility, applies binding/visibility/trust/policy, and emits a canonical snapshot with a catalog digest. The snapshot is pinned by the behavior version and prompt-cache epoch. File watchers, installs, updates, or remote availability produce a candidate next snapshot; they never replace the body or resources of a loaded skill mid-turn. Resume requires the exact tree digest or stops with `skill_snapshot_unavailable`.

## Compilation never executes

Today a bundled script runs only when the operator wires it as a check (`--check`); no path lets
the model run a skill script. The execution lifecycle below is designed, not built.


Loading a skill never executes installation hooks, scripts, or commands — **compilation is inert**. A script request passes through the same lifecycle as any other action:

```text
accepted plan → exact script digest → interpreter/tool policy → sandbox/preflight
              → effect classification → approval if required → execute → verify
```

Scripts receive an explicit working directory, arguments, input files, environment allowlist, egress policy, time/output/resource budgets, and credential handles; secrets are injected by the execution boundary only when policy permits and never substituted into skill text. Remote skill resources are staged and content-addressed before activation; Tamoz does not fetch mutable remote code during skill execution.

## Authoring and promotion

Built, for a skill the operator authors or Tamoz drafts:

- `tamoz skills new NAME [--dir D]` writes a scaffold that already meets the authoring bar.
- `tamoz skills create NAME --from-session THREAD` runs a work turn guided by the bundled `skill-authoring` skill. The input is a trajectory written from a thread that finished verified (terminal reason `done`, checks satisfied); the draft lands in a private staging workspace under the session directory, never in a skills root. It is staged (`NAME.candidate.json` beside it) only if it meets the bar (`Tamoz::Skills.lint`, Q1–Q5: a "Use when" description within the catalog budget, a bounded body, no dangling or orphaned resource mentions, a declared `tamoz.risk`).
- `tamoz skills promote CANDIDATE_DIR --approver NAME --skills DIR` installs a candidate. It refuses when the approver is the recorded creator, when the tree digest differs from the one staged, or when the bar is no longer met. It copies exactly the digested files, re-digests the copy, moves any previous version into `.retired/`, renames atomically, and appends the decision to `.promotions.jsonl` in the skills root.
- `agenteval skills optimize` rewrites only `SKILL.md`, keeps a rewrite only if it beats the original on held-out scenarios, and stages it for `tamoz skills promote`.

The agent never installs or approves a skill, and the approver name is a record, not an authenticated identity: the digest pin is the gate.

## Supply-chain promotion (registry installation and updates) — designed, not built

None of this section exists yet: there is no download, quarantine, provenance check, or auto-update. See
`docs/skills-review-2026-09-30/PLAN.md` phases 9–11.

Installation from a registry would be a staged workflow: resolve an immutable source, download to quarantine, verify expected digest/signature/provenance when available, unpack with size/path/link limits, validate license/manifest/resources, run a static security review and capability diff, evaluate, obtain human/policy approval, install atomically as a content-addressed artifact, and emit a candidate catalog epoch. Registry verification or a trusted publisher raises provenance confidence; it does not make instructions or code safe. Updates display semantic and byte-level changes; auto-update is allowed only for content-only, capability-nonwidening artifacts under an explicit operator policy, and activation remains a new digest/epoch. Generated skills are candidates: promotion requires validation, held-out trigger/evaluation, injection/path/secret/escalation tests, baseline comparison, and human approval for scripts or capability widening — the part built today is the authoring bar, the held-out comparison in `agenteval skills optimize`, and the named human approval; the agent cannot use a candidate's own instructions to evaluate or approve it. Uninstall tombstones the binding and preserves provenance/audit evidence.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`./mcp.md`](./mcp.md) — the sibling capability surface (MCP)
- [`../guides/agent-operator.md`](../guides/agent-operator.md) — managing skills as an operator
- [`../adr/adr-056-skills-gem.md`](../adr/adr-056-skills-gem.md) — the `tamoz-skills` gem and its facade
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract
- [`../../docs/design-v0.1/SKILLS_DESIGN.md`](../../docs/design-v0.1/SKILLS_DESIGN.md) — the authoritative design record
