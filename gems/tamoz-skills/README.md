# tamoz-skills

Portable Agent Skills for Tamoz: directories holding a `SKILL.md` plus optional resources,
following the open specification at <https://agentskills.io/specification>.

```ruby
require "tamoz/skills"

source = Tamoz::Skills::SkillSource.new(id: "operator", root: "/opt/tamoz/skills", trust: "operator")
snapshot = Tamoz::Skills::Compiler.new(sources: [source]).compile
Tamoz::Skills::Catalog.new(snapshot).render
```

Compiling a skill executes nothing, a skill's content grants no authority, and a skill's
identity is the digest of its whole tree. Depends on `tamoz-core` only.
