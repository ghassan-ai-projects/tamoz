# P5 — Skills and memory in the frame

Bar rules exercised: B6, B8, B9.

## Goal

The model sees digest-pinned skills and situation memory as attributed, untrusted evidence.
Nothing untrusted can change authority, name hidden tools, or leak truth.

## In scope

- **Skill refs.** `cognition.executor.skills` = ordered `{name, tree_sha256}` refs, bound in the
  compiled spec and request. The worker resolves only from the operator-approved catalog and
  requires digest match. Mismatch fails before any model call.
- **`skill_set_sha256`.** Digest of the canonical ordered list: name, source class, tree digest,
  rendering protocol version. Rendered bytes retained and verified. (Today it is nil.)
- **Attributed frame.** One frame builder with two sections: trusted policy section (objective,
  prompt, catalogs) and untrusted section (skill text, snapshot facts, recalled memory, tool
  results). Untrusted text is fenced and attributed. Skills are not uniquely dangerous — snapshot
  strings, memory, and corrections get the same treatment.
- **`recall` node.** Situation-scoped recall (proven in rounds 2–3) becomes a graph node feeding
  `build_frame`. The §3.1 graph is now complete.
- **Memory as evidence.** Recalled items enter the frame with stable evidence ids
  (`memory:<digest>`). First-occurrence cells have empty memory.
- **Injection corpus.** Skills, memory, snapshot strings, corrections, and tool results attempt
  to: reveal truth, change authority, smuggle tool names, request hidden files, lower risk. All
  must fail closed.

## Out of scope

- Learning writes (experience admission stays on the channel-B path, already proven).
- New skill sources. Operator directory only, as today.

## Exit gate

1. Skill swap changes the frame and the manifest digests. Nothing else changes.
2. Injection corpus passes: zero authority changes, zero tool-name smuggling, zero holdout access.
3. Unknown skill ref or digest mismatch → typed failure before any model call.
4. A recalled memory item appears in the frame with its digest, and the model's `evidence_refs`
   can cite it; fabricated refs fail validation.
5. Joint level-4 gate with P4: a novel domain with digest-pinned skills and memory in the frame
   passes end to end through the fixed graph with zero Ruby.
6. Repository gates green.

## Allowed claim

**"New domains are authoring-only"** (jointly with P4). Level 4 of 6.
