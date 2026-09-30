# tamoz-skills

Portable Agent Skills for Tamoz: directories holding a `SKILL.md` plus optional resources,
following the open specification at <https://agentskills.io/specification>.

Compiling a skill executes nothing, a skill's content grants no authority, and a skill's
identity is the digest of its whole tree. Depends on `tamoz-core` only.

The facade is the module `Tamoz::Skills`; other gems never name its inner classes (guarded by
`test/skills_boundary_test.rb`).

- `compile(sources:, bindings:, limits:)`: compile skill sources into an immutable `SkillSnapshot`.
- `operator_snapshot(root:, workspace_root:, bundled:)`: the snapshot an operator configured —
  the skills Tamoz ships (`bundled_root`), one operator directory, or both. An operator root
  inside the workspace is refused (`outside_workspace!`).
- `empty`: the snapshot when no skills are configured.
- `Catalog.new(snapshot)`: resolve a name and render the catalog the model sees.
- `render_load`, `read_resource`, `render_resource`: what `load_skill` and `read_skill_resource`
  return, fenced as untrusted author content.
- Value types: `SkillSource`, `SkillRecord`, `SkillResource`, `SkillSnapshot`, `SkillCollision`,
  `SkillRejection`, and `Error`.
