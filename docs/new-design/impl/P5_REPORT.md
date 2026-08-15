# P5 — Phase report: skills + memory in the frame

Status: **implementation complete; review pass complete** (5 reviewer agents —
correctness, architecture, duplication/dead-code, sound/clean, repeated
mistakes — all findings fixed below).

## Review-pass fixes

- **Go↔Ruby skill-ref wire contract fixed**: `tree_sha256` (snake_case) is the
  wire key on both sides; empty skill lists marshal as `[]`, never `null` (a
  Go-produced episode previously failed at build_frame for every skill-less
  run).
- **Recall is journaled**: the recall node routes through the durable effect
  journal (logical key episode/recall/slot-0/identity-digest) — a replay
  returns the RECORDED projections, never a fresh, changed read (the P3
  replay hazard is closed; proven by a fence+1 test with a mutated recaller).
- **Projection boundary hardened**: every projection is shape-validated
  (object, `sha256:` digest, String statement) and cross-checked against the
  episode tenant (a misbehaving recaller returning another tenant's memory is
  refused); digest↔projection consistency is enforced; failures are typed
  `EpisodeFrameError`, never untyped KeyError.
- **SkillSet bounded + parse-wrapped**: `MAX_TEXT_BYTES` enforced; malformed
  refs JSON raises `SkillSetError` (not a raw JCS error).
- **Tests strengthened**: gate-1 asserts equal decision digests (a skill swap
  changes frame/skill digests and NOTHING else); gate-2 asserts the attacker
  text never reaches the trusted system section AND a smuggled tool request
  fails closed with zero tool events; gate-4 pins the repair path (two calls,
  then FAILED) and proves a `memory:<digest>` citation validates; an
  empty-memory (first-occurrence) test + recall failure-branch tests
  (no-caller, tenant mismatch) added.
- **Dead code removed**: `Frame#fact_ids`, `SkillRef#render`, the grounding
  fallback, the dead `MAX_TREE_BYTES`; the launcher's duplicate node build
  removed; the launcher wires the recaller + skills source into the nodes.

## Claims made (finished line)

**"New domains are authoring-only"** (jointly with P4) — bars B6/B8/B9, level 4
of 6. The model sees digest-pinned skills and situation memory as attributed,
untrusted evidence; nothing untrusted can change authority, name hidden tools,
or leak truth.

## Exit gate status

| # | Gate | Status | Evidence |
|---|---|---|---|
| 1 | Skill swap changes frame + manifest digests; nothing else changes | **PASS** | `test_gate1_skill_swap_changes_frame_and_manifest_digests_only` — different frame digest + skill-set digest, identical decision shape |
| 2 | Injection corpus: zero authority changes, zero tool-name smuggling, zero holdout access | **PASS** | `test_gate2_attacker_skill_text_cannot_change_authority_or_smuggle_tools` — attacker text rides the untrusted section; the decision stays catalog-driven (start_aerator R1); tool execution stays closed-world |
| 3 | Unknown skill ref / digest mismatch → typed failure before any model call | **PASS** | `test_gate3_*` — FAILED terminal, ZERO endpoint hits |
| 4 | Recalled memory in frame with its digest; citable; fabricated refs fail | **PASS** | `test_gate4_*` — `memory:<digest>` in the frame + manifest; a fabricated `memory:` ref repairs-once then FAILED |
| 5 | Joint level-4: novel domain with digest-pinned skills + memory, zero new Ruby | **PASS** | `test_gate5_*` — the climate domain + a skill + recalled memory through the fixed graph |
| 6 | Repository gates | final | at the finished line |

## What shipped

- **Wire (field 65)**: `EpisodeRequest.skill_refs_json` — the ordered
  `[{name, tree_sha256}]` refs; the Go spec's `Executor.Skills` compiles into
  the payload and the worker maps them.
- **`SkillSet` (tamoz-agent)**: resolves refs only from the operator-approved
  source (fixture map in tests; the compiled Skills::Snapshot is the
  production seam), verifies each tree digest (fail closed), and computes the
  canonical `skill_set_sha256` over `[{name, source_class, tree_digest,
  rendering_protocol_version}]` — all wire-carried or constant, so live and
  replay agree.
- **Attributed frame**: `EpisodeFrameBuilder` gains fenced `skills` +
  `memory` entries in the untrusted user section (alongside facts/tools/
  repair); the citation line names all four prefix kinds; the frame digest
  covers the sections.
- **`recall` node**: situation-scoped memory moved from the runner's pre-seed
  into a graph node (intake → recall → build_frame); the channels are
  once-written-by-the-node (no longer immutable-seeded); the runner no longer
  calls the recaller; the manifest reads the terminal state's
  memory_record_digests + skill_set_digest.
- **Evidence**: `ground_evidence!` admits `tool:`/`memory:`/`skill:` refs
  (backed by the frame's evidence ids); `skill` added to REF_PREFIXES.
- **Manifest**: `skill_set_sha256` is populated (was nil); rendered skill
  bytes retain under the tree digest.

## Fixture vs real labeling

All P5 gate tests are fixture-labeled; the injection corpus is test data.

## Honest scope notes

- Skill resolution in production resolves against the operator-approved
  compiled Skills::Snapshot; the test seam is a fixture map.
- The injection corpus covers the five vectors on skills/memory; the frame's
  structural separation (trusted vs untrusted sections) is the mechanism.
