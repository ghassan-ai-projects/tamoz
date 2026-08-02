# P18 capability host plan review

Verdict: accept-with-required-corrections (revision 2 integrated C1–C8).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/P18_CAPABILITY_HOST_PLAN.md` revision 1 against the four
source-phase plans, `MCP_DESIGN.md` §4, the invariants, the toolbox, the graph gem
surface, the product load paths, and the corpus.

## Findings and dispositions

| # | Sev | Finding | Disposition (rev 2) |
|---|---|---|---|
| C1 | High | The 7-field `CapabilityDescriptor` cannot express MCP dispatch (no schemas, no dispatch handle, no runtime state — MCP needs a live Supervisor + pinned snapshot); local tools' validation is imperative, not schema-driven | Restored the MCP_DESIGN §4 fields (input/output_schema, source_digest, requested_scopes, availability); the host is interface + registry + intersection renderer with per-source dispatcher objects (validator, executor, effect/preview hooks) bound at session construction; dependency graph asserted |
| C2 | High | Grep-based graph audit cannot classify "product-loaded" (runtime-critical internals are referenced from compiled.rb, not product files; Zeitwerk eager_load makes "loaded" meaningless) and cannot back the P15-A row | Ruby stdlib `Coverage` (methods: true) over product tests + scorecard, intersected with graph constants — regenerable by RUNNING the named tests (the P15 §3 criterion); grep demoted to a reachability note |
| C3 | High | "One gate enforces invariant 35" mislocates the intersection (today: `build_profile_toolbox` + `verify_profile_binding!`); H2 doesn't test the gate | The gate's authority input is a policy-derived ADMISSION SET passed into the host (host never re-reads profile; the P8 binding stays); content-never-grants remains source-enforced; direct gate tests: sealed registry, forged registration fails |
| C4 | High | "No source-typed `when`" asserts syntax, not the property (case/hash/respond_to/validator-object dispatch all evade it) | H3 is an extension test: a fifth synthetic source composes with ZERO host edits + the sealed-registry assertion |
| C5 | Medium | Source-qualified `skill:` ids contradict byte-identical surface (bare skill/local ids today); baseline unpinned (P10 slice 4 + P17 add tools) | Model-visible ids pinned to today's values; post-P17-closed head captured as a committed fixture; H4 compares against it ("no further delta from P18") |
| C6 | Medium | Source-registry authority boundary unstated (invariant-42 escape: a generic contract + caller-supplied list is the plugin shape) | Closed registry of the four built-ins; no source object constructible from content; tests for both |
| C7 | Medium | A wrapping boundary endangers D-7 error identity (class + message bytes are session-visible) | Host wraps only non-`ToolError` exceptions; H6 asserts class + message byte-identity per source |
| C8 | Low | "Documentation-only" false for `public-api.json`; "budget" in the intersection list is category confusion (token budgets ≠ surface limits); "promoted" mixes measurement with policy | "No engine code change; public-api.json + test regenerated"; budget dropped from the intersection; audit table split into measured + recommendation columns (arbitration at P15-A) |

Over-scope/duplication findings: plugin-framework drift is real and closed by C6;
no second engine confirmed; egress enforcement must consume P17's admission record
(one reader); the intersection must not duplicate `verify_profile_binding!` (C3);
the P9 §9.2 adversarial suite must run through the host dispatch (added to H2).

## Held-out probes

Forged-descriptor injection (invisible-equivalent case — closed by the sealed
registry); skill resource read bypassing the host gate (P9 suite through the host);
new source post-P18 skipping compliance (closed registry); audit table disagreeing
with actual load (Coverage method — closed by C2); typed-error double-wrap (H6);
source-qualification forgery across servers (P10 §10.2 row added to the compliance
suite).

## Status

Corrections integrated in `docs/P18_CAPABILITY_HOST_PLAN.md` revision 2.
