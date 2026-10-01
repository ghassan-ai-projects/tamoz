# tamoz-tools

Workspace tool primitives for Tamoz: the Toolbox, including the skill tools over tamoz-skills.

```ruby
require "tamoz/tools"

toolbox = Tamoz::Tools::Toolbox.new(root: ".", allow_changes: true, checks: {"verify" => ["echo", "ok"]})

digest = toolbox.catalog_digest
preview = toolbox.preview("apply_patch", {"path" => "a.txt", "before" => "1", "after" => "2"})
receipt = toolbox.execute("run_check", {"name" => "verify"})

snapshot = Tamoz::Skills.empty
toolbox.skill_epoch # => "none"
```

The Toolbox owns approval normalization, preview/effect-intent preflight, atomic IO,
UTF-8 policy, path/root/symlink validation, compound replacements, and the configured
`run_check` child-process surface, and `load_skill` / `read_skill_resource` over a
`Tamoz::Skills` snapshot.

Depends on `tamoz-core`, `tamoz-cancellation` and `tamoz-skills`. The `Tamoz::Agent`
namespace re-exports the toolbox classes as constant aliases.
