# Skills

Portable procedural knowledge for Tamoz Agent, with progressive disclosure, immutable
identity, and no implicit authority.

## 1. Decision

Tamoz implements the open [Agent Skills specification](https://agentskills.io/specification)
directly. A skill is a directory containing `SKILL.md` and optional `scripts/`,
`references/`, and `assets/`. Tamoz extensions use flat `tamoz.*` keys inside `metadata`;
the portable base format remains valid in other compatible agents.

Skills remain part of `tamoz-agent`. A separate runtime gem would add packaging without an
independent execution abstraction. The reusable contracts are `SkillSource`,
`SkillCatalog`, and content-addressed `SkillSnapshot`.

A skill supplies instructions and resources. It is not:

- a tool, plugin, credential bundle, policy, or sandbox;
- a permission grant;
- trusted because it is local;
- automatically correct because its syntax validates;
- mutable during an execution.

## 2. Portable source format

Tamoz accepts the specification's required `name` and `description` plus optional
`license`, `compatibility`, `metadata`, and experimental `allowed-tools`.

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

The `allowed-tools` field is interpreted only as the skill author's requested upper bound.
It never pre-approves anything. The effective tools are:

```text
agent grant ∩ task/plan grant ∩ schedule/parent grant ∩ skill requested maximum
```

Tamoz extensions use flat `tamoz.*` keys with string values because the portable
`metadata` contract is string-to-string. Unknown portable fields are retained for
round-trip compatibility and ignored for authority. Unknown `tamoz.*` keys fail validation
until the extension version declares them.

## 3. Compiled skill record

Source content is compiled into an immutable local record:

```ruby
SkillRecord = Data.define(
  :id,                  # source-qualified name
  :name,
  :version,
  :source,
  :source_revision,
  :tree_digest,
  :manifest_digest,
  :description_digest,
  :trust,
  :requested_capabilities,
  :risk,
  :compatibility,
  :license,
  :resource_index,
  :evaluation_evidence,
  :installed_at
)
```

The tree digest covers `SKILL.md` and every reachable bundled file using canonical relative
paths, content digests, file types, and executable bits. FIFOs, devices, sockets, hard-link
escapes, absolute paths, `..`, case-fold collisions, unsafe symlinks, and oversized/deep
trees are rejected.

The execution identity is `(source, name, tree_digest)`, not a mutable path or claimed
version. Version is useful display metadata but cannot prevent a same-version content swap.

## 4. Sources, scope, and collision

Configured sources may include:

- workspace/project skills;
- operator-managed skills;
- personal skills;
- Tamoz-bundled skills;
- explicitly installed registry or Git artifacts.

Each source has an owner, scope, trust, read roots, update policy, and precedence. Discovery
does not silently resolve same-name collisions across trust boundaries. A collision requires
an explicit source-qualified binding or configured override decision that is recorded in
the catalog. This prevents a workspace skill from impersonating a managed skill merely by
using its name.

Visibility is separately filtered by agent, workspace, user, surface, and task policy.
Visibility is not execution authority. A shell-capable agent still needs OS/sandbox policy
because hiding a skill cannot stop it from invoking an accessible binary.

## 5. Progressive disclosure

Tamoz uses four bounded stages:

1. **discover** — inject or search source-qualified names, descriptions, version, risk, and
   availability;
2. **load** — `load_skill` returns the delimited `SKILL.md` body and immutable identity;
3. **read** — `read_skill_resource` reads one indexed reference/asset on demand;
4. **execute** — a bundled script may run only through an ordinary authorized execution
   tool.

Catalog descriptions have a fixed token/character budget. A small catalog is rendered in
stable id order. A large catalog moves behind deterministic search while keeping
`load_skill` visible. Truncation is explicit and observable.

The model may select a skill, but explicit user invocation wins when authorized. Selection
records considered candidates, reason, selected digest, and whether invocation was user,
rule, or model initiated. A skill's body is attributed untrusted instruction content below
system/application policy.

## 6. Catalog and cache epochs

At a turn boundary, the catalog compiler:

1. discovers configured sources without following untrusted escapes;
2. parses YAML safely without object deserialization or aliases;
3. validates the Agent Skills schema and Tamoz extension version;
4. computes content digests and compatibility/availability;
5. applies source binding, visibility, trust, and policy;
6. emits a canonical `SkillSnapshot` and catalog digest.

The snapshot is pinned by the behavior version and prompt-cache epoch. File watchers,
installs, updates, removals, compatibility changes, or remote availability produce a
candidate next snapshot. They never replace the body or resources of a loaded skill
mid-turn. Resume requires the exact tree digest or stops with
`skill_snapshot_unavailable`; it never reads changed files under the old identity.

## 7. Loading and resource safety

`load_skill` accepts a source-qualified id or an unambiguous catalog name. It returns
bounded text, source/trust/version/digest, requested capabilities, and resource inventory.
It does not add tools or environment variables.

`read_skill_resource` accepts only an indexed canonical relative path. It resolves the
realpath on every access, verifies file identity/digest, bounds bytes and MIME types, and
attributes the content. References may link only within the skill tree unless an explicit
ordinary read capability authorizes an external path.

Assets are data, not instructions by default. Templates and examples remain untrusted
content and cannot introduce approval or policy statements.

## 8. Scripts and dependencies

Loading a skill never executes installation hooks, scripts, or commands. A script request
passes through the same lifecycle as any other action:

```text
accepted plan → exact script digest → interpreter/tool policy → sandbox/preflight
              → effect classification → approval if required → execute → verify
```

The skill's compatibility text and dependency declarations are requirements, not permission
to install. Missing binaries or packages produce typed unavailable. Dependency installation
is a separate operator-authorized supply-chain action.

Scripts receive an explicit working directory, arguments, input files, environment allowlist,
egress policy, time/output/resource budgets, and credential handles. Secrets are injected
by the execution boundary only when policy permits and never substituted into skill text.

Remote skill resources are staged and content-addressed before activation. Tamoz does not
fetch mutable remote code or references during skill execution.

## 9. Installation and updates

Installation is a supply-chain workflow:

```text
resolve immutable source
  → download to quarantine
  → verify expected digest/signature/provenance when available
  → unpack with size/path/link limits
  → validate license, manifest, resources, and executable inventory
  → static security review and capability diff
  → evaluation
  → human/policy approval
  → atomic content-addressed install
  → candidate catalog epoch
```

Registry verification or a trusted publisher raises provenance confidence; it does not make
instructions or code safe. Updates display semantic and byte-level changes to description,
instructions, scripts, dependencies, capabilities, risk, and evaluation evidence.
Auto-update is allowed only for content-only, capability-nonwidening artifacts under an
explicit operator policy, and activation remains a new digest/epoch.

Uninstall tombstones the binding and preserves provenance/evaluation/audit evidence. An
in-flight execution may finish with its pinned materialized snapshot; new turns cannot load
the removed skill.

## 10. Skill creation and self-improvement

Tamoz may propose a new or revised skill from successful trajectories, corrections, or
repeated procedures. It writes a candidate artifact, never an active skill. The candidate
records source trajectories, redactions, intended trigger, boundaries, capability request,
examples, negative examples, evaluator version, and predicted benefit.

Promotion requires:

- spec validation and supply-chain checks;
- trigger/selection evaluation on held-out positive and confusable negative tasks;
- execution evaluation with declared tools and with tools denied;
- prompt-injection, path, secret, and capability-escalation tests;
- comparison against no-skill and current-skill baselines;
- human approval for scripts, capability widening, policy/prompt-hierarchy changes, or
  managed/shared scope.

The agent cannot use a candidate's own instructions, examples, or scripts to evaluate or
approve that candidate.

## 11. Evaluation model

`tamoz-evals` owns:

- Agent Skills format and canonicalization conformance;
- source/collision/scope and snapshot replay cases;
- selection precision, recall, abstention, and explicit-invocation correctness;
- progressive-disclosure token cost and load/resource limits;
- instruction-following task success versus no-skill and prior-skill baselines;
- script sandbox, dependency, secret, path, symlink, archive, and egress attacks;
- malicious descriptions, nested references, tool-output injection, and policy spoofing;
- capability intersection and denial behavior;
- install/update/uninstall crash consistency and provenance;
- candidate/holdout isolation and rollback.

Release gates are zero authority gained from skill content, zero resource escape, zero
silent same-name shadowing, exact digest replay, and statistically supported task benefit
without a safety/cost/latency regression.

## 12. Non-goals

A skill may package Situation interpretation guidance, schemas, and authoring examples. It
cannot register a channel, authenticate a sensor, change event-time/backpressure policy,
grant an effector, or raise physical risk authority.

- Tamoz does not invent a competing skill format.
- Skills do not replace deterministic Ruby APIs, tools, graphs, or application policy.
- A marketplace is not part of the framework.
- Skill composition is ordinary plan composition; there is no hidden skill-to-skill call
  stack.
- “Used a skill” is not evidence of success. Verification remains task-specific.
