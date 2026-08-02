# tamoz-tools

Workspace tool primitives for Tamoz: the Toolbox and the skills descriptor surface.

```ruby
require "tamoz/tools"

toolbox = Tamoz::Tools::Toolbox.new(root: ".", allow_changes: true, checks: {"verify" => ["echo", "ok"]})

digest = toolbox.catalog_digest
preview = toolbox.preview("apply_patch", {"path" => "a.txt", "before" => "1", "after" => "2"})
receipt = toolbox.execute("run_check", {"name" => "verify"})

snapshot = Tamoz::Tools::Skills::Snapshot.empty
toolbox.skill_epoch # => "none"
```

The Toolbox owns approval normalization, preview/effect-intent preflight, atomic IO,
UTF-8 policy, path/root/symlink validation, compound replacements, and the configured
`run_check` child-process surface. The skills descriptor surface is the inert compiler
and its Data types (SkillRecord, SkillResource, SkillSnapshot, Catalog, …), which
execute nothing and grant no authority.

Depends on `tamoz-core` only. The `Tamoz::Agent` namespace re-exports these classes as
constant aliases.
