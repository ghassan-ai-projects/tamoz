# Audit 068 — `gems/tamoz-agent-session/lib/tamoz/agent/session_adaptive.rb`

Rank 68 · 536 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major) · Bar fails: SIZE

Graph transitions correctly route through SessionEffects, but the node methods and the event
builder blow through the size/param ceilings under a blanket six-cop RuboCop disable.

## Findings

- **[major][SIZE]** `dispatch` (~64 lines, 114-177), `decide` (~47, 38-84), and `observe` (~39,
  179-217) exceed the 30-line hard ceiling under a class-wide disable of
  MethodLength/AbcSize/CyclomaticComplexity/PerceivedComplexity/ClassLength/ParameterLists (line
  10). Owning seam: receipt/observation/lifecycle-triplet assembly in SessionRecords or evidence
  helpers, so each transition reads as its boundary. (session_adaptive.rb:10-13, 114-217)
- **[major][SIZE]** `lifecycle_event` takes 3 positional + 9 optional params = 12, with
  ParameterLists disabled. Owning seam: a LifecycleEvent builder/value on SessionRecords.
  (session_adaptive.rb:516-532)

## Resolution — 2026-09-11

Measured past the file's blanket six-cop inline disable (by stripping the disable comments on a
scratch copy) so the real numbers are on record: `decide` 43/20, `dispatch` 58/20, `observe`
37/20, three more methods 21-31/20, and `lifecycle_event` ParameterLists **12/5**.

- **[major][SIZE] fixed (lifecycle_event).** `lifecycle_event` took 3 positional + 9 optional
  keywords. Its nine optionals were only ever "merge this field if it was supplied", so it now
  takes `**details` — 5 parameters, at the ceiling — guarded by an explicit
  `LIFECYCLE_DETAIL_KEYS` allowlist that raises `ArgumentError` on an unknown key. That keeps the
  typo protection the explicit keyword list gave (a `**` splat alone would have silently accepted
  any key, a safety regression) while leaving all nine call sites unchanged. The file now has
  **zero** ParameterLists violations even with the disable stripped.
- **[major][SIZE] node methods — not changed, and deliberately so.** `decide`/`dispatch`/`observe`
  are over the ceiling, but the disable at the top of this class carries an explicit written
  justification: "The graph-node methods keep each durable transition visible and ordered;
  splitting one transition across helper objects would obscure its checkpoint boundary and make
  the protocol harder to audit." That is exactly the named exception the repo's quality program
  asks for, and it is a defensible one: each of these methods IS one durable transition, and the
  audit's own remedy concedes the split would move assembly into other objects. Overriding a
  documented architectural decision to satisfy a line count is not an improvement I should make
  unilaterally from an audit pass — it needs the owner's call. The `lifecycle_event` fix above was
  taken precisely because it reduces a real violation WITHOUT touching any transition's control
  flow, honouring that justification.
