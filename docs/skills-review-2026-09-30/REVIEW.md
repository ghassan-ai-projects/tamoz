# Skills capability — deep review (2026-09-30)

Scope: everything that makes a skill reach the model — the compiler and catalog
(`gems/tamoz-tools/lib/tamoz/tools/skills*`), the toolbox tools `load_skill` /
`read_skill_resource`, the capability binding, every route that builds a prompt, every entry
point that builds a toolbox, the stream `SkillSet`, the tests, the eval, and the docs. Measured
against the open Agent Skills specification (<https://agentskills.io/specification>, read
2026-09-30) and Tamoz's own design (`documentation/design/skills.md`, ADR-033/034,
`docs/P9_EVALUATED_SKILLS_PLAN.md`).

## Verdict

The **containment** engineering is excellent and should be kept as is: compiling is inert, a
skill is identified by a tree digest over every byte, skill text is fenced as untrusted and
grants nothing, reads are pinned to the compile-time digest, collisions never pick a silent
winner, and a resumed session refuses a changed tree. 91 tests (5 files) pass, including a
37-case adversarial matrix.

As a **capability** it was not usable. No CLI command (`ask`, `code`, `investigate`,
`deep-research`) showed a skill to the model — the one path that did is a `tamoz worker` with
no profile, in legacy routing, with the `skills` source enabled — and the compiler rejected practically every skill written to the public specification, operators could
not see what was rejected, and nothing measured whether a skill helps. World class needs five
things; Tamoz had the first:

| Property | Before | Findings |
|---|---|---|
| Safe (contained) | **yes** | — |
| Reachable (a user can use one) | no | S1, S2, S3, S19 |
| Portable (spec skills load) | no | S4, S5, S6, S10 |
| Operable (operator can see and check) | no | S7, S8, S9 |
| Measured (does it help, at what cost) | no | S12 |
| Exemplified (a real, hard skill ships) | no | S15 |

## Strengths (keep)

- **Inert compile.** `lstat`, `Dir.children`, `realpath`, `NOFOLLOW` reads; `Psych.safe_load`
  with zero aliases after an event-level scan; no `eval`/`require`/subprocess.
- **Content identity.** `tree_digest` covers path, kind, bytes and executable bit of every
  entry; the catalog digest and epoch bind sources, records, collisions and rejections.
- **No authority from content.** `allowed-tools` is an author's upper bound rendered as
  `effective_tools = requested ∩ available`; it never reaches the tool set.
- **Attribution fence** derived from the tree digest (deterministic, unforgeable because the
  compiler refuses bodies containing the sentinel).
- **TOCTOU-guarded resource reads** with pinned digest and realpath checks on both sides.
- **Zero silent shadowing** and **exact-digest resume** (`SkillSnapshotUnavailableError`).

## Findings

Severity: critical = the capability does not work for users; high = common real skills or
setups fail; medium = operability/correctness gap; low = drift or polish.

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| S1 | critical | **The CLI never loads skills.** `tamoz ask`, `code`, `investigate` and `deep-research` build their toolbox without a `skills:` snapshot, so every CLI session is skill-free. Only `WorkerRuntime` compiles skills (worker, Telegram), and only when the runtime config enables the `skills` source; the stream worker takes a separate JSON map (S11). | `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:689-708` (`build_toolbox`, `build_profile_toolbox`), `cli.rb:185` (`Agent.build`); `worker_runtime.rb:909` |
| S2 | critical | **The work loop never shows the catalog.** Stage 1 of progressive disclosure exists only in the legacy plan route. The work loop (what `tamoz code` and chat run) exposes `load_skill` with no list of names, so the model can only guess. | catalog injected only in `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb:155`; `gems/tamoz-agent-session/lib/tamoz/agent/work_context.rb:81` (`opening`) has no skill entry |
| S3 | high | **A profile cannot allow skill tools.** `KNOWN_TOOLS` omits `load_skill`/`read_skill_resource`, so a profile-bound session (every scheduled or chat worker with a profile) is skill-free. P9 deferred this until P8-E; P8-E has landed (P9 plan §11), so the blocker is gone. | `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:65` |
| S4 | high | **`allowed-tools` is parsed comma-separated; the spec says space-separated.** Any spec skill naming two tools (`Read Grep`), or a scoped tool (`Bash(git:*)`), is rejected whole. | `gems/tamoz-tools/lib/tamoz/tools/skills/frontmatter.rb:148`; `TOOL_PATTERN` at `skills.rb:58` is lowercase-only, so even the spec example `Read` fails; probe below |
| S5 | high | **Files beside `SKILL.md` and extra directories are rejected.** The spec allows "any additional files or directories" (e.g. `LICENSE.txt`, a root `forms.md`, `templates/`). Most published skills ship a root `LICENSE.txt`. | `gems/tamoz-tools/lib/tamoz/tools/skills/walk.rb:158` (`validate_layout!`) |
| S6 | medium | **A dotfile rejects the whole skill.** A Finder `.DS_Store` makes a skill vanish. | `walk.rb:141` (`validate_component!`) |
| S7 | medium | **A rejection names the offending file, not the skill.** The operator sees `LICENSE.txt: skill_layout_invalid` without knowing which skill it came from. | `walk.rb:186` (`reject!` uses the entry path as the label) |
| S8 | medium | **Rejections are invisible to the operator.** `WorkerRuntime#skill_rejections` has no caller; only the model sees a one-line count in the catalog. No command lists skills, digests or rejections, or checks a skill before use. | `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:972`; `catalog.rb:110` |
| S9 | medium | **Selection is not attributable and cannot be user-driven.** Design §5 says explicit user invocation wins and selection is recorded (user / rule / model); neither exists. | `docs/P9_EVALUATED_SKILLS_PLAN.md` §12.3 |
| S10 | medium | **Limits disagree with the spec in both directions.** Tamoz accepts `pdf--tools` and a `compatibility` of up to 512 bytes (spec: 1–500 characters), so a Tamoz skill can fail elsewhere; and it counts **bytes** where the spec counts **characters** (description 1024, compatibility 500), so a spec-valid non-ASCII description is rejected. | `skills.rb:53` `NAME_PATTERN`; `frontmatter.rb:44`, `LIMITS[:max_description_bytes]` |
| S11 | medium | **Two skill identities.** The stream `SkillSet` digests `sha256(rendered text)` and reads skills from a JSON map passed to `bin/tamoz-stream-worker`; the agent path digests the whole tree. The same skill has two different "tree digests". The wire field is shared with the Go authority, so changing it is a cross-repo contract change. | `gems/tamoz-agent-kernel/lib/tamoz/agent/skill_set.rb:81`; `bin/tamoz-stream-worker:104` |
| S12 | medium | **Nothing measures whether a skill helps.** Only containment is tested (`agent.skill-no-authority`, scripted model). The measurement plan (`docs/eval-improvement/measurement-plans/04-skills.md`) and P9-E were never built: no with/without comparison, no selection rate, no cost. | `gems/tamoz-evals/suites/agent/smoke/15_skill_no_authority.case.json` |
| S13 | low | `tamoz.eval-suite` is accepted and consumed by nothing. | `frontmatter.rb:25` |
| S14 | low | **Docs drift.** The design page says skills live in `tamoz-agent`; ADR-033/034 "Verification" say the code is in `tamoz-agent-capabilities` (it is in `tamoz-tools`); the design page describes install/quarantine, script execution, visibility filtering and catalog search in the present tense — none exist. | `documentation/design/skills.md`; ADR-033/034 |
| S15 | low | **No skill ships.** There is no example or bundled skill, and the `bundled` trust class has no source. | — |
| S16 | info | **No script execution path** (P9-C). The operator-configured check (`--check name=argv`, run by `run_check`) is an existing, reviewed seam that already runs an operator-chosen command — a bundled script can run through it without new machinery. | `toolbox.rb` `run_check` |
| S17 | low | Resource reads are UTF-8 text only, max 16 KiB, no ranged read; a larger reference is indexed but unreadable. | `skills.rb` `LIMITS[:max_read_bytes]` |
| S19 | medium | **The catalog can be shown with no way to load from it.** The legacy route adds the catalog whenever the snapshot is non-empty, but a profile-bound toolbox drops `load_skill` (S3), so a profile-bound legacy worker sees skills it cannot open. | `deliberation.rb:156`; `tool_catalog.rb:113` |
| S18 | design | **Gem home.** Skills are a full capability — compiler, catalog, identity, rendering, and now lint and operator helpers — living inside the tools gem. ADR-033 kept them out of a gem while they were "a recipe concern". Owner decision (2026-09-30): extract `tamoz-skills`. | ADR-033 |

### Probe for S4–S6

Four skills written to the public spec, compiled with the current compiler
(`Tamoz::Tools::Skills::Compiler`, operator source):

```text
accepted: []
rejected .DS_Store:  skill_path_invalid    - .DS_Store is not a valid component
rejected LICENSE.txt: skill_layout_invalid - LICENSE.txt is not allowed beside SKILL.md
rejected sk-a:       skill_field_invalid   - allowed-tools entries must be tool names   (Bash(git:*) Read)
rejected sk-d:       skill_field_invalid   - allowed-tools entries must be tool names   (read_file search_text)
```

`sk-d` names only Tamoz's own tools, space-separated as the spec says — and is still rejected.

## Disposition

Every finding is either fixed in this change or recorded with a reason in
[PLAN.md](PLAN.md); the status of each is in [STATUS.md](STATUS.md). S11 is recorded, not
changed: the digest is a wire contract with the Go authority (ADR-055) and needs a paired
change there.
