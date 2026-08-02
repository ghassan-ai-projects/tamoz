# P16 tools gem plan review

Verdict (revision 1): **REJECT as written** — two blocking design decisions missing
(the skills seam creates a runtime agent dependency inside tamoz-tools; class-name
serialization and rescue ancestry break byte-identity). Verdict (revision 2):
re-review ACCEPT-WITH-REQUIRED-CORRECTIONS (C1–C6, integrated into revision 3).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02), two
passes.

## Revision 1 rejection — verified findings

1. **The skills seam is a blocking runtime dependency**: the Toolbox constructor
   default `skills: Skills::Snapshot.empty` (toolbox.rb:131), the hard type check
   `skills.is_a?(Skills::SkillSnapshot)` (135-136), `Skills::Catalog.new` (142), and
   `Skills.render_load/render_resource/read_resource/read_resource_entry!` in the
   execution paths (466-478) are RUNTIME references to `Tamoz::Agent::Skills` — the
   "requires only stdlib" claim is load-time-true, runtime-false.
2. **`skill_epoch` → `SessionRecords::LEGACY_SKILL_EPOCH`** (toolbox.rb:220) is an
   agent constant referenced by the moved class — a NameError on the empty-snapshot
   branch, and `session_nodes.rb:88` calls `toolbox.skill_epoch` on EVERY intake.
3. **Class-name serialization breaks byte-identity**: `error.class.name` at
   `effect_dispatcher.rb:188`, `session_nodes.rb:306`, `runtime.rb:401` would emit
   `Tamoz::Core::ToolError` — aliases cannot fix `.name`.
4. **Rescue ancestry drift**: in core the taxonomy subclasses `Tamoz::Error`; the
   `rescue Tamoz::Agent::Error` sites at `cli.rb:51` (bad-root) and
   `agent_smoke_corpus.rb:1382` silently stop catching the ToolError family.
5. **The shim must be a constant rebinding**, not a subclass/delegation wrapper
   (class identity + `MAX_*` constants in ~20 test files).
6. **T4's "16 cases, 13 successes" is a forecast** — today's baseline is 15/12; the
   comparison must be against the measured P16-start baseline.
7. **MCP-descriptors-in-Toolbox is P18 over-scope** and contradicts P10's caller-
   supplied boundary.

## Revision 2 — corrections integrated

Skills-seam decision = option 1: the skills descriptor surface (Snapshot, Catalog,
render/read functions) moves into tamoz-tools; `LEGACY_SKILL_EPOCH` moves to
tamoz-core; agent re-exports. The class moves WHOLESALE (approval/preview surface
included — the right column is consumers, not content). Class-name mapping at the
three serialization sites + probe; rescue sites updated + probe; constant-alias shim
with the full alias list; T1 digest matrix (skills × allow_changes × checks ×
approval_required); T2 clean-env runtime harness (executes, not just loads); T4 vs
measured baseline; P18 creep cut; plumbed files enumerated (GEM_ROOTS, packaging
install names, dependency isolation, gemspec).

## Revision 2 re-review — verified fixes + corrections (integrated into revision 3)

Verified FIXED in rev2: constructor/type-check/seam references; alias mechanism
(constant rebinding necessary and sufficient — tests use MAX_* constants +
`assert_instance_of Tamoz::Agent::CheckReceipt` + harness `Tamoz::Agent::Toolbox.new`);
the three class-name serialization sites (dedup keys hash kind/tool/reason/arguments —
no class name, so the mapping cannot churn dedup); the two rescue sites (repo-wide
grep); the measured-baseline T4; P18 creep cut; plumbing claims.

Corrections (C1–C6, integrated into revision 3):

| # | Sev | Finding | Disposition (rev 3) |
|---|---|---|---|
| C1 | Blocking | The skills split is incoherent as enumerated — the descriptor surface is interleaved with the compiler and Data types in ONE file (skills.rb); an enumerated split creates two SkillSnapshot types and breaks every intake | skills.rb moves WHOLESALE to Tamoz::Tools::Skills (compiler + types + LIMITS + render/read); "binding machinery stays" = session.rb verification only; `Skills = Tamoz::Tools::Skills` added to the alias list |
| C2 | Blocking | `Skills.canonical` → `Deliberation.canonical` (skills.rb:177 → deliberation.rb:187) is a runtime agent reference inside the moved surface | `canonical` is pure — moved to tamoz-core; Deliberation delegates; Skills.canonical resolves in-tools |
| C3 | Med-High | T2 cannot catch the `skill_epoch` NameError (only called from agent side; a read-only clean-env execute never calls it) | T2 enumerates the FULL surface (both skill_epoch branches, all execute tools incl. load_skill/read_skill_resource, run_check with a real check, preview, effect_intent, a tempdir mutation); assertion = `refute defined?(Tamoz::Agent)` after successful execution + $LOADED_FEATURES scan |
| C4 | Medium | T1 matrix misses two digest inputs (`check_safeties`, `allowed_tools`); `maximum_effect_output_bytes` wrongly implied as a digest input | Both axes added; maximum_effect_output_bytes explicitly excluded |
| C5 | Medium | cli.rb:51 fix must not widen to `rescue Tamoz::Error` (StoreError/LeaseLostError/ConfigurationError would change behavior); LEGACY_SKILL_EPOCH has other consumers | Explicit `Tamoz::Agent::Error, Tamoz::Core::ToolError`; StoreError-path probe added; consumers enumerated (toolbox.rb:220, session.rb:149, session_records.rb:23,251) |
| C6 | Low | public_api_test is a pinned hash (not a flat list); version-equality test; gemspec "=" dep; alias inventory unasserted | All plumbed; alias-inventory probe added |

## Held-out probes (revision-2 re-review)

Empty-snapshot `skill_epoch` in the clean env (T2 as amended); `Tamoz::Agent.build`
with the agent-side Snapshot post-move (whole-module move passes); missing Skills
alias NameError (alias-inventory probe); widened rescue converting StoreError
backtraces (explicit rescue + probe); check_safeties digest drift (T1 axis);
run_check execution in the clean env (T2 surface).

## Status

Revision 3 in `docs/P16_TOOLS_GEM_PLAN.md` (C1–C6 integrated) — ACCEPTED.
