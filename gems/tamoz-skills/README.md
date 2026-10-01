# tamoz-skills

Portable Agent Skills for Tamoz: directories holding a `SKILL.md` plus optional resources,
following the open specification at <https://agentskills.io/specification>.

Compiling a skill executes nothing, a skill's content grants no authority, and a skill's
identity is the digest of its whole tree. Depends on `tamoz-core` only.

The facade is the module `Tamoz::Skills`; other gems never name its inner classes (guarded by
`test/skills_boundary_test.rb`).

- `compile(sources:, bindings:, limits:)`: compile skill sources into an immutable `SkillSnapshot`.
- `operator_snapshot(root:, workspace_root:, bundled:)`: the snapshot an operator configured —
  the skills Tamoz ships (`bundled_root`), one operator directory, or both.
- `disjoint!(root, workspace_root)`: a skills root and the workspace may not contain one
  another, in either direction; raises `Error`.
- `empty`: the snapshot when no skills are configured.
- `Catalog.new(snapshot)`: resolve a name (`resolve`) and render the catalog the model sees (`render`).
- `render_load`, `read_resource`, `read_resource_entry!`, `render_resource`: what `load_skill`
  and `read_skill_resource` return, fenced as untrusted author content. `scripts/` is indexed
  for identity and never readable.
- `lint(record)`: the authoring bar (Q1–Q5); one line per issue, empty means it is met.
- `scaffold(name, parent)`: write a new skill directory that meets the bar.
- `stage_candidate(directory, created_by:, source:)`: pin a drafted skill that meets the bar by
  its tree digest in `<directory>.candidate.json`.
- `install_candidate(directory, skills_root:, approver:)`: install a staged candidate for a
  named approver other than its creator; refuses a changed tree, keeps the previous version
  in `.retired/`, logs to `.promotions.jsonl`.
- Value types: `SkillSource`, `SkillRecord`, `SkillResource`, `SkillSnapshot`, `SkillCollision`,
  `SkillRejection`, and `Error`; constants `LIMITS` and `NAME_PATTERN`.

Bundled skills live in `skills/`: `evidence-audit` (findings that cite file, lines and a
verbatim quote, with `scripts/verify_findings.rb`) and `skill-authoring` (drafts a skill from a
verified trajectory). Specification-written skills load: `allowed-tools` may be space- or
comma-separated, extra files are allowed, and dotfiles are ignored.
