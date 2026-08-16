# P5 — Implementation plan: skills + memory in the frame

Status: **draft v2 — implemented** (gap + completeness findings integrated:
the recall channels were relaxed from immutable to once-written-by-the-node;
recall runs once (the node), the runner no longer seeds or re-calls it;
ground_evidence! admits tool:/memory:/skill: refs and `skill` was added to
REF_PREFIXES; skill resolution reuses the operator-approved source seam (the
compiled Skills::Snapshot is the production source, a fixture map in tests);
skill_set_sha256 derives from wire-carried refs + compile-time constants so
live/replay agree; the empty-memory case is covered; the citation line names
all four prefixes).

Bar: PHASE_P5_SKILLS_MEMORY.md exit gates 1–6. Bars: B6, B8, B9. Claim:
**"New domains are authoring-only"** (jointly with P4). Level 4 of 6.

## Architecture (delta from P4)

The model sees digest-pinned skills and situation memory as attributed,
untrusted evidence. Nothing untrusted can change authority, name hidden
tools, or leak truth.

- **Skills on the wire.** `cognition.executor.skills` = ordered
  `{name, tree_sha256}` refs, bound in the compiled spec and the request.
  `EpisodeRequest` gains `skill_refs_json` (the ordered ref list). The worker
  resolves each skill's TEXT only from the operator-approved directory (the
  configured/`test/support/skills/` root) and requires the tree digest to
  match — an unknown ref or digest mismatch fails typed BEFORE any model call
  (build_frame).
- **`skill_set_sha256`.** The worker computes the digest of the canonical
  ordered list — `[{name, source_class, tree_digest,
  rendering_protocol_version}]` — and the manifest's `skill_set_sha256`
  (currently nil) carries it. The rendered skill bytes are retained (P3 store)
  and verified.
- **Attributed frame.** `EpisodeFrameBuilder` gains one untrusted section with
  fenced + attributed entries: `skills` (SKILL <name>: <text>), `memory`
  (MEMORY <digest>: <statement>), alongside the existing facts/tool_results/
  repair_directive. The trusted system section is unchanged (objective,
  prompt, catalogs). Skill/memory/snapshot/correction/tool text are all
  untrusted by the same rule.
- **`recall` node.** Situation-scoped recall moves from the runner's
  pre-compute into a graph node between intake and build_frame: the node calls
  the injected situation_recaller port (caller/tenant verified as today),
  writes `situation_memory` + `memory_record_digests` channels, and fails
  typed on a recaller error (never silent). The runner no longer seeds those
  channels. RECONSIDER-kind stays intake-refused (P6).
- **Memory as evidence.** Recalled items carry stable evidence ids
  (`memory:<digest>`); `ground_evidence!` admits `memory:` refs backed by the
  frame's memory entries (alongside `fact:` and `tool:`); a fabricated
  `memory:` ref fails validation exactly like a fabricated `fact:`.
- **Injection corpus.** A fixture corpus (skills/memory/snapshot strings/
  corrections/tool results) that attempts: reveal-truth, change-authority,
  tool-name smuggling, hidden-file requests, risk-lowering. Each is rendered
  into the frame and validated — all must fail closed (the attacker text never
  changes the system section, never names a tool outside the catalog, never
  cites an ungrounded ref, never lowers a risk label).

## Exit gates mapped to tests

1. **Skill swap changes frame + manifest digests, nothing else** — two runs
   with different skills (or skill text) → different frame digest + different
   manifest `skill_set_sha256`, identical decision shape otherwise.
2. **Injection corpus passes** — the corpus assertions above, end to end
   through the fixed graph.
3. **Unknown skill ref / digest mismatch → typed failure before any model
   call** — zero endpoint hits; the envelope or build_frame raises.
4. **Recalled memory in frame + citable; fabricated refs fail** — a
   recall-enabled run shows `memory:<digest>` in the frame; the document can
   cite it; a document citing a non-recalled `memory:` ref is repaired-once
   then FAILED (same as fabricated `fact:`).
5. **Joint level-4 gate** — the climate domain gains digest-pinned skills +
   a recalled memory; the fixed graph produces the verified decision with
   zero new production Ruby.
6. **Repository gates green** (final, at the finished line).

## Tasks

### T1 — Wire + skill refs (both repos)
- `runtime-v1.proto`: `EpisodeRequest` gains `bytes skill_refs_json = 65`
  (the ordered `[{name, tree_sha256}]` list). Regenerate both bindings.
- The Go assembler compiles `cognition.executor.skills` into the payload
  (`skill_refs`), like the intent catalog (digest-bound by the spec digest —
  the skill refs are part of the compiled spec, so the SPEC digest binds
  them; no new digest on the wire, the worker verifies tree digests).
- The Ruby envelope/payload carries `skill_refs_json`; DIAGNOSE requires the
  skill refs section (may be empty) — an EMPTY skill set is valid.

### T2 — SkillResolver (tamoz-agent, mirrors the catalog pattern)
- `gems/tamoz-agent/lib/tamoz/agent/skill_resolver.rb`: resolves
  `{name, tree_sha256}` → text from the operator-approved root (injectable
  path; tests use `test/support/skills/<name>/<tree>.md`).
  - unknown name → typed `SkillError` (fail closed, before any model call);
  - tree digest mismatch → typed `SkillError`; the digest covers the skill's
    exact rendered bytes.
  - canonical skill-set digest: `digest("situation-runtime/skill-set/v1\n",
    [{name, source_class, tree_digest, rendering_protocol_version}])` (JCS
    order-bound).
- `verify_wire(skill_refs_json)` mirrors the catalog intake: strict-parse,
  bound (max 32 refs, bounded names/digests), fail closed.

### T3 — Frame attribution + memory evidence (tamoz-agent)
- `EpisodeFrameBuilder`:
  - `build(snapshot:, prompt:, ..., skills: [], memory: [], tool_results: [],
    repair_directive: nil)` — the untrusted user section gains `skills`
    (`SKILL <name>: <text>`, fenced, digest-attributed) and `memory`
    (`MEMORY <digest>: <statement>`, fenced).
  - `Frame` gains `skill_ids`/`memory_ids` so grounding can admit the refs.
- `ground_evidence!` admits `memory:<digest>` + `skill:<name>` refs backed by
  the frame; the system prompt's citation line names the three prefix kinds.
- The frame digest covers the skills + memory sections (a skill swap changes
  the digest — gate 1).

### T4 — recall node (tamoz-agent graph + runner)
- New node `recall` (after intake, before build_frame): reads the episode/
  snapshot/wire, calls the injected `situation_recaller` port (caller/tenant
  verified), writes `situation_memory` (projections) + `memory_record_digests`
  (digests); a recaller error → typed graph failure (never silent).
- The runner stops seeding the two channels; the graph declares the recall
  node's wiring (port injection at composition like the decision builder).
- `build_frame` consumes `state[:situation_memory]` → frame memory entries
  with `memory:<digest>` ids.

### T5 — Injection corpus (tests)
- `test/support/injection_corpus.rb`: fixture attacker texts for each vector
  (reveal truth / change authority / tool-name smuggling / hidden-file /
  risk-lower) embedded in skills, memory, snapshot strings, corrections, and
  tool results.
- `test/stream_episode_injection_test.rb`: each vector through the fixed
  graph → zero authority change (the decision's risk/intents unchanged), zero
  tool smuggling (the tool catalog gates execution), zero holdout access
  (validate refuses ungrounded refs; the capability host allows only
  permit-listed tools).

### T6 — skill_set_sha256 in the manifest (tamoz-stream)
- `build_artifact_manifest` sets `skill_set_sha256` from the resolved skill
  set (instead of nil); retention stores the rendered skill bytes (P3 store)
  keyed by tree digest.

### T7 — Joint level-4 gate (climate + skills + memory)
- `test/support/climate_domain.rb` gains digest-pinned skills (a fixture
  skill) + a recalled memory fixture; the fixed graph produces the verified
  decision end to end (zero new production Ruby).

## Test mode labeling

All P5 gate tests are fixture-labeled; the injection corpus is test data; no
real model is called.

## Deferred

- Learning writes (channel-B experience admission) — out of scope.
- New skill sources (operator directory only).
- Skill rendering protocol versions beyond v1.
