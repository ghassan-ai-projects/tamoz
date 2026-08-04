# P18 — Capability host unification and graph surface audit: implementation plan

Status: accepted for implementation (revision 3 — checkpoint deep-review closed-registry,
audit, and proof-baseline corrections integrated; see
`docs/reviews/DESIGN_CHECKPOINT_6FF0D40_DEEP_REVIEW.md`)
Source question: "are we using our graph gem?" — answered yes (it is the agent
runtime); this phase turns that finding into a measured audit and unifies the
capability sources the toolbox has accreted — WITHOUT a plugin framework.
Authoritative inputs: invariants 11, 16, 17, 35, 42; `AGENT_DESIGN.md` §§3–5, 10, 11;
`MCP_DESIGN.md` §4 (the descriptor the shared contract must not lose); the P9 skill
descriptor, P10 MCP descriptor, P16 tools gem, P17 websearch; the graph gem's public
surface; `docs/public-api.json`.
Depends on: P16, P17, P11–P14 close. Under the single-active-phase order it activates
after P14 and before P15.

## 1. Scope commitment

1. **Capability host**: one `CapabilitySource` contract (data + per-source dispatcher
   interface) under which local tools (P16), skills (P9), MCP servers (P10), and
   websearch (P17) register; the invariant-35 authority intersection is computed once
   from a policy-derived admission set; "content never grants" stays source-enforced;
   the registry is a CLOSED set of the four built-in sources.
2. **Graph surface audit**: a Coverage-based measurement of the graph gem's exercised
   surface, published as the graph's documented public API.

| Outcome | Proof |
|---|---|
| one `CapabilitySource` contract = data + dispatcher interface (validator, executor, effect/preview hooks) bound in a registry built at session construction | compliance suite each source passes; registry sealed after construction (C3/C6) |
| invariant-35 intersection computed from a policy-derived ADMISSION SET passed into the host (host never re-reads profile; `verify_profile_binding!` stays the authority check) | the P9/P10/P17 adversarial cases pass unchanged; direct gate test: a forged source registration fails (C3) |
| surface immutable mid-turn; content never grants remains source-enforced | sealed-registry + closed-world composition tests (C3/C4) |
| graph public surface measured (Coverage) and documented | `docs/GRAPH_SURFACE_AUDIT.md` with measured + recommendation columns; `public-api.json` regenerated (C8) |
| no behavior regression | full gate both locales; scorecard baseline captured at P18 start (after P11–P14), safety 0 |

Non-goals (binding): NO plugin API, NO marketplace, NO hidden skill call stack, NO
auto-executing installers, NO graph engine rewrite, NO registry of caller-supplied
sources (the four built-ins are the closed set).

## 2. Capability host design (corrected — C1/C3/C6)

```ruby
# tamoz-core (contract)
CapabilityDescriptor = Data.define(   # restores MCP_DESIGN §4 fields (C1)
  :id, :kind, :source_id, :definition_digest, :trust, :effect_class, :protocol_profile,
  :input_schema, :output_schema,      # MCP dispatch is schema-driven — required
  :source_digest, :requested_scopes, :availability
)
CapabilitySource = Data.define(
  :source_id,          # "local" | "skill:<source>/<name>" | "mcp:<server>/<tool>" | "websearch:..."
  :descriptors,        # frozen [CapabilityDescriptor]
  :definition_digests  # {descriptor_id => digest}
)
# Per-source dispatcher (interface, implemented by each source's gem):
#   validate(descriptor, arguments) -> typed D-7 result | raises ToolArgumentError
#   execute(descriptor, arguments, context:) -> typed result (effect/preview hooks)
```

**The host** (`tamoz-tools` owns it; `tamoz-agent` owns policy) is interface +
registry + intersection renderer — NOT a single dispatch body:

- **Registry**: built at session construction from the four built-in sources (local
  always; skills if a catalog exists; MCP/websearch if profiles admit); **sealed after
  construction** — no source object may be constructed from skill/catalog/profile/MCP
  content, and a forged/extra registration fails (C6). The registry is a CLOSED set;
  this is the invariant-42 boundary (a generic caller-supplied list would be the
  plugin shape).
- **Intersection (C3)**: the gate's authority input is a policy-derived ADMISSION SET
  (the already-intersected surface from `build_profile_toolbox` + `verify_profile_
  binding!` — the host NEVER re-reads profile policy; that stays the P8 binding). The
  gate's property: `surface = descriptors-as-data ∩ admission set`, computed at
  session construction, immutable mid-turn. "Content never grants" remains
  source-enforced (annotations `author_claimed` in Catalog; descriptions bounded in
  Toolbox) — a gate only sees finished descriptors and cannot re-derive it.
- **Error identity (C7)**: the host wraps ONLY non-`ToolError` exceptions; a typed
  error from any source passes through with class + message bytes identical (asserted
  per source).

**Model-visible ids (C5):** pinned to today's values — bare local tool names, bare
`load_skill`/`read_skill_resource`, `mcp:`-qualified MCP/websearch. The post-P17-closed
source shapes are known, but the actual surface fixture is captured at **P18 start after
P11–P14 close**. H4 compares against that fixture ("no delta from P18"), never against
an obsolete forecasted case count.

## 3. Graph surface audit (corrected — C2)

**Method:** Ruby stdlib `Coverage` (`methods: true`) run over the product agent tests
AND instrumented scorecard subprocesses. Coverage measures executed methods; it cannot
by itself prove use of constants, Data members, or methods executed in an uninstru-
mented child. The generator therefore joins three explicit inputs: (1) the graph entries
in `public-api.json`, (2) per-process Coverage artifacts merged by canonical source path,
and (3) a named public-surface probe that resolves each manifest constant and invokes or
constructs it where safe. Columns distinguish `product_method_executed`,
`test_only_method_executed`, `manifest_resolved_only`, and `internal`; no constant is
called product-exercised merely because its file loaded. The result is stdlib-based,
deterministic, and regenerable by RUNNING THE NAMED TESTS (the P15 §3 criterion).
Grep is retained only as a secondary reachability note (the product
references few graph constants directly — `Tamoz.graph`/`Builder`/`START`/`END`,
`durable_runner` — while the runtime-critical internals are referenced from
`compiled.rb`; "loaded by the product" via Zeitwerk eager_load means nothing, and
"reachable" is not "exercised"). The audit table splits MEASURED columns (product-
exercised / tested-only / internal) from a separate PROMOTION RECOMMENDATION column
(policy, arbitrated at P15-A — not a de facto API decision made by the audit itself,
C8).

Deliverable: `docs/GRAPH_SURFACE_AUDIT.md`; the promoted public API (durable runner,
compiled checkpoints, request inbox, barriers, stream emitter) documented with its
invariants (3, 5, 9, 19–22); nothing deleted or rewritten. No engine code change;
`public-api.json` and its pinned test ARE regenerated (a tested artifact — stated
honestly, C8). **No "budget" in the intersection list** (profile.budgets are token
budgets, not tool-surface limits — C8).

## 4. Migration and compatibility

- Capability host: sources register at session construction; the model-visible surface
  matches the P18-start fixture (H4); the host is a re-org, not a surface change; the
  scorecard cases prove it.
- Graph audit: measurement + documentation; `public-api.json` + test regenerated.
- Old-session resume: session records untouched; the host builds the same surface from
  the same pins.

## 5. Tests (corrected)

- H1 contract compliance: each built-in source passes the compliance suite
  (descriptor shape incl. schemas, digest stability, dispatch typing).
- H2 gate-level tests (direct): (a) a forged source registration fails (registry
  sealed — C3); (b) no content path can produce a `CapabilitySource` (C6); (c) the
  intersection = descriptors ∩ admission set, immutable mid-turn; (d) the P9/P10/P17
  adversarial cases pass unchanged through the host (tool surface + plan digest
  oracles). H2 runs the P9 §9.2 adversarial suite (tree escape, links, hardlinks)
  THROUGH the host dispatch — not just the three scorecard cases.
- H3 closed-world composition (C4/DC-6): exercise all four built-in source dispatchers
  through one protocol, including multiple descriptors/servers within an existing
  source, with zero source-typed host branches. A fifth synthetic/extra source MUST fail
  at construction. Extensibility beyond the four is intentionally not a v1 property.
- H4 surface equivalence: model-visible surface byte-identical to the P18-start
  committed fixture; scorecard identical.
- H5 audit accuracy: all instrumented subprocess artifacts are merged; the Coverage +
  manifest-probe table regenerates by running the named tests and reconciles every graph
  entry in `public-api.json`; `AuditMismatchError` fires on divergence.
- H6 error identity (C7): repairable + policy errors from each source pass through
  the host with class + message bytes identical.

## 6. Failure model

| Situation | Type | Behavior |
|---|---|---|
| forged/extra source registration | `DescriptorConflictError` (typed) | registry sealed; refused |
| source dispatch returns an untyped error | host wraps (non-ToolError only) | D-7 taxonomy at the boundary (invariant 17); typed identity preserved (C7) |
| audit regeneration disagrees with the committed table | `AuditMismatchError` | P15-A row marked incomplete until reconciled |
| cross-source descriptor id collision | `DescriptorConflictError` | session refuses to construct (source-qualified ids make this a bug, not a shadow) |

## 7. Stop / redesign criteria

- Any adversarial case (P9/P10/P17) weakens, any scorecard delta appears, or the
  model-visible surface changes by one byte from the P18-start fixture.
- If unifying the gate requires granting a source authority it did not have, STOP
  (invariant-35 breakage).
- Any plugin/marketplace/auto-install shape, or any registry entry constructible from
  content (invariant 42).

## 8. Definition of done

- [x] `CapabilitySource`/`CapabilityDescriptor` contract (with schemas) + compliance
      suite + sealed-registry tests (H1/H2).
- [x] Host with the admission-set intersection; P9/P10/P17 cases green unchanged;
      H3 closed-world composition test; H6 error identity.
- [x] `docs/GRAPH_SURFACE_AUDIT.md` (Coverage-based, measured + recommendation
      columns) + regenerated `public-api.json` + test.
- [x] Full gate both locales; scorecard equals the baseline captured at P18 start,
      safety 0.
- [x] Trackers updated; non-goals restated in the phase close.

## 9. Phase-close scope correction (critic round, revision 4)

The P18 critic round (PASS-WITH-GAPS) found the capability host's session-construction
WIRING absent: no production path in `tamoz-agent` constructs `CapabilityHost` — the
runtime still drives `Toolbox` + the P10 `McpCapabilitySource` directly. Rather than
re-wire the live agent runtime inside the same phase (which would risk the hard-zero
"scorecard equals baseline" and "model-visible surface unchanged by one byte" gates at
phase end), this phase is explicitly re-scoped per the critic's sanctioned alternative:

**The host ships as the tested contract + registry + intersection renderer + real
dispatch paths (all committed); binding it into session construction is DEFERRED to
P15 (release hardening), where the completion audit can verify the wiring against the
same committed fixture (H4) and the full scorecard.**

Scope held in P18 (all with committed tests):
- contract + sealed registry (H1/H2, incl. the critic fixes: descriptor↔source
  consistency, no `Registry.new` bypass, non-empty built-in suffix);
- closed-world composition and error identity through the REAL `CapabilityHost#dispatch`
  (H3/H6, critic F5);
- surface equivalence against a COMMITTED P18-start fixture, not an in-memory
  self-comparison (H4, critic F6);
- graph surface audit with module-function classification (incl. `Tamoz.graph` /
  `Tamoz.interrupt`), a recommendation column (policy, arbitrated at P15-A), and
  `AuditMismatchError` on regeneration-vs-committed divergence (H5/C8, critic F2/F3).

Consequence recorded for P15: the host's real binding must construct the registry at
session construction from the four built-in sources, route local/MCP/websearch dispatch
through the per-source dispatchers, and keep the model-visible surface byte-identical
to `test/fixtures/p18_start_toolbox_surface.json`.
