# Episode frame builder slice

## Scope

Only `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb` is
writable in this slice. Callers and tests were inspected read-only. Existing
slice files, `BAR.md`, `SLICE-BAR.md`, and `TODO.md` remain untouched.

No tests, lint, Enola, provider, or live commands are run here.

## Candidate decisions

| Surface | Candidate defect | Decision | Risk |
| --- | --- | --- | --- |
| `Frame`, `FRAME_DOMAIN`, `MAX_FACT_BYTES`, `MAX_FACTS` | Stable value shape and deterministic frame limits/domain. | Leave stable. | High: wire/digest contract. |
| `initialize` | Stores the already-verified catalog and immutable objective; the construction story is explicit. | Leave stable. | High if freezing or stored values change. |
| `verify_prompt!` | Verifies the optional cross-repo prompt digest in a focused guard. | Leave stable. | High: error timing and prompt binding. |
| `build` | Coordinates prompt verification, fact collection, trusted/untrusted section construction, canonical-byte validation, evidence ordering, and frame projection. The sequence is already the frame workflow; the JCS call and digest inputs are intentionally adjacent to the projection. | Leave stable. | Very high: prompt bytes, evidence order, digest inputs, and validation timing. |
| `prompt_digest` | Names one cross-repo digest contract and has one responsibility. | Leave stable. | High: cross-boundary digest bytes. |
| `build_facts` | Validates and bounds snapshot facts while preserving source order. | Leave stable. | High: fact order, truncation, and error behavior. |
| `build_system` | Assembles the trusted system section from prompt, objective, catalog, evidence instructions, and protocol instructions. This is one coherent section. | Leave stable. | High: model-visible prompt bytes. |
| `build_user` | Mixes four evidence-domain projections, user-section insertion order, optional-section policy, and canonical serialization. | Refactor. Extract one named projection helper per evidence domain; retain assembly and serialization order here. | High: user bytes and optional-key order. |
| `build_user` situation projection | Facts become attributed `fact:<id>` entries. | Extract as `build_situation_entries`. | Medium: exact ids and values must remain unchanged. |
| `build_user` skill projection | Skills become attributed entries carrying name, tree digest, and text. | Extract as `build_skill_entries`. | High: skill evidence shape. |
| `build_user` memory projection | Memory becomes attributed digest/statement entries. | Extract as `build_memory_entries`. | High: memory evidence shape. |
| `build_user` tool projection | Tool results become indexed, digest-bearing summaries. | Extract as `build_tool_entries`. | High: index/order and digest fields. |

## Selected refactor

`build_user` will read as: build the four attributed evidence collections,
assemble the user sections in the existing order, then canonicalize the user
document. The new helpers are private and each names one evidence-domain
projection; they do not own optional-section policy or serialization.

No public API, signature, constant, output key, output byte, validation order,
error class/message, digest input, or evidence ordering is intentionally changed.

## Behavior contract

- Preserve `Frame` fields and all public methods/signatures.
- Preserve facts, skills, memory, and tool projection fields exactly.
- Preserve `user` insertion order: `situation`, optional `skills`, optional
  `memory`, optional `tool_results`, optional `repair_directive`.
- Preserve array coercion, `fetch` behavior, tool index assignment, and all
  exception timing/messages.
- Preserve `Tamoz::Core.jcs` invocation and the exact frame digest input in
  `build`; do not alter prompt or catalog bytes.
- Preserve evidence-id order in `build` and all fact limits/truncation behavior.

## Final diff concepts

Implemented only in `episode_frame_builder.rb`:

- `build_user` now states the user-frame workflow as projection of situation,
  skills, memory, and tools, followed by the existing optional-section assembly
  and JCS serialization.
- `build_situation_entries`, `build_skill_entries`, `build_memory_entries`, and
  `build_tool_entries` each own one unchanged evidence-domain projection.
- `build`, `verify_prompt!`, `prompt_digest`, `build_facts`, `build_system`,
  evidence-id construction, and frame digest construction were left unchanged
  to protect validation timing, ordering, prompt bytes, and digest inputs.
- Callers reread after extraction: `EpisodeNodes#build_frame` and
  `EpisodeNodes#rebuild_frame` still invoke the unchanged `build` seam; frame
  and evidence assertions in the inspected crash, replay, benchmark, and memory
  tests remain directed at the same public behavior.
- `git diff --check` was run. Tests and all repository quality/live gates were
  intentionally not run, so behavioral equivalence remains inspection-based in
  this slice.

## Unimplemented behavior-change proposals

None. A behavior change is not needed for this reading-order refactor.
