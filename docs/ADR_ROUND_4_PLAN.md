# ADR round 4 — what to revise, merge, retire, and add

Date: 2026-10-02. Input: the round-3 rewrite (PR #64), its independent review, and
[`round-3-discussion.md`](adr-review-2026-09-29/round-3-discussion.md) (owner decisions D1–D22).
Round 3 made implementation gaps and residual risks explicit. Round 4 strengthens the decisions,
preserves their evidence, and closes selected gaps. Consolidation is useful when it removes duplicate
ownership; fewer ADRs is not a quality target. This plan proposes work, not acceptance of D1–D22.

Plan-edit quality bar: [ADR_ROUND_4_PLAN_BAR.md](ADR_ROUND_4_PLAN_BAR.md).

## Verdict in one paragraph

The current corpus has 59 numbered records: 50 Accepted, 1 Proposed, and 8 Retired. The previous
51-record working set included Proposed 050; it was not 51 accepted decisions. Retain the useful
boundaries, consider the consolidation candidates below, and record the missing authority/evidence
choices. Neither a target record count nor a target script count determines success.

## 1. Separate decision changes from implementation repairs

Recommendations below require owner acceptance where they change a rule. Keep accepted intent and
`Implementation: Partial` until the relevant behavior is implemented and checked. Changing a shared
facade still requires cross-gem interface approval.

| ADR / agenda | Kind | Recommended disposition and required evidence |
|---|---|---|
| **049 — D1** | Authority decision | Consider evidence per tier, `filesystem_operator` for destructive/publish tiers, trusted policy classification, and the strictest evidence across all pending interrupts. Prove a mixed-evidence batch cannot be released by the weakest prompt; missing/unclassified evidence fails closed. Resolve surface-mode naming and prompt lifetime as part of D1. |
| **022 — D2** | Authority decision | Decide between reviewed discovery and bounded pre-plan reads. Narrowing to effect-bearing actions is an option, not a settled rewrite. Identify every permitted pre-plan tool, trusted local classification, data scope, destination/content limits, delegation and budget bounds, and the residual exfiltration risk. Egress destination checks alone do not protect sensitive query text. External/non-deterministic calls still use ADR-016. Amend clauses 25/55 in the same decision package. |
| **053 — D3** | Product/authority decision | Resolve the exact-diff approval promise versus base `workspace_write: allow`. Distinguish plan review from human effect approval; update product/README claims and policy only according to the accepted answer. |
| **053 / 030 — D4, D19** | Authority decision | Consider an unclassified fallback that profiles cannot allow, policy-owned read-only classification, and invalidation of grants on rebind. Prove unknown-tool refusal, attempted classification downgrade, and implement→review→implement does not restore revoked grants. Preserve recorded decisions and explain revocation separately from replay. |
| **019 — D18** | Compatibility decision | Define whether the requirement is explicit version discipline, a development check, or automatic runtime rejection of changed implementation. Prefer the existing implementation/version contract unless a stronger need is established. A node-body digest misses helpers, dependencies and captured configuration; a file digest rejects harmless edits. Do not promise semantic identity from either. Distinguish graph-state migration from ADR-059 database reset; remove or retain the hypothetical migration clause only by an explicit scope decision. |
| **059 — D5** | Implementation repair | Preserve the no-compatibility rule. Delete the legacy read tolerance and obsolete positive fixture test, retain meaningful typed refusal, and mark Complete only after the relevant tests pass. This does not require rewriting the accepted rule. |
| **055 — D7** | Implementation repair / deployment choice | Preserve the external authority split. Define production local-caller trust: private owner-validated directory (0700), restrictive socket permissions, and creation without an exposure window. Refuse unauthenticated production TCP; loopback development mode must be explicit and retain its residual risk. Remove the false mTLS code claim. Prove permissions, rejected production binding and successful permitted transport before updating implementation status. |

## 2. Consolidation candidates — preserve the complete contract

These may duplicate another record or belong in a policy/design document. Before retiring one, map
every decision clause, refusal, enforcing seam and verification row to its retained home. If a distinct
contract cannot be preserved clearly, keep the ADR. A successor and its retirement land together.

| ADR | Weakness | Action |
|---|---|---|
| **041** Comms = contract gem + transport gems | An application of 014 (extensions) and 052 (gem boundaries); no choice of its own left | **Retire into 014.** Move the `DeliverySink`/null-sink fact into `documentation/design/comms.md` |
| **044** Observability = contract gem + exporter gems | Same pattern as 041; its one real rule is exporter egress | **Retire into 014**; its egress rules move to the new egress ADR (§4) |
| **054** Websearch is a reserved MCP server | Its load-bearing part is egress governance, shared with otel and MCP elicitation | **Consider merging into the new egress ADR**; preserve reserved-id/MCP reuse, opt-in source identity, authority and epoch bindings, budgets and verification, not just destinations |
| **047** No record-time sampling; reserved lane | A refinement of 045 (the journal is lossy; truth is the durable record) | **Merge into 045** as one "telemetry observes and may lose; it never decides" ADR |
| **050** Automated responses (Proposed) | Its true-today rule — observability has no actuator — is verifiable now; the rest waits on a phase nobody has scheduled | **Fold the current no-actuator boundary into 045**; withdraw the proposed automation separately and retain its deferred scope in the roadmap/tombstone. Do not promote proposed clause 62 into an accepted guarantee |
| **056** Skills are a gem | A packaging instance of 052; the facade rule is 052's | **Retire into 033** (skills) — one line there names the gem and facade |
| **024** "Smart" means … | Product philosophy plus a metric list; its only enforceable rule is evidence honesty | **Rewrite as "Agent-quality claims require a real-provider run under the frozen protocol"**; move the definition of "smart" to `documentation/overview/product.md` |
| **013** Vocabulary budget | A review policy with no enforcement and no runtime effect | **Retire**; move the rule to `docs/CODING_STANDARD.md` (public API section) |
| **010** Ruby support | Release/support policy, not architecture | **Retire**; `documentation/overview/compatibility.md` owns supported versions; D8 decides the matrix |

Considered for retirement and **kept**: 001 (names are expensive to change), 008 (owns the no-async-API
refusal), 018 (small but a real correctness rule), 040 (repository topology is distinct from gem
boundaries), 031 (delivery vs execution is distinct from 032's authority rules).

## 3. Retain the decisions — implementation and owner choices remain open

001, 005, 006, 007, 008, 009, 011, 014, 015, 016, 017, 018, 020, 021, 023, 025, 026, 027, 028, 029, 030, 031,
032, 033, 034, 036, 038, 039, 040, 042, 045, 046, 048, 052, 057, 058.

Open items on these are implementation gaps already named in their `Implementation:` lines
(020 codec D13, 023 human gate D20, 032 cron D12, 034 comparative evaluation D11, 042 shared DB D10,
057 global registry D9, 058 loader cleanup); 052 waits on D6 (confirm the dependency-boundary rule).
Retaining these records does not pre-accept those answers. D11/D13/D20 can alter an existing obligation
rather than merely close a gap; document that choice if taken. Carry the undocumented SQLite restore
procedure into the operations follow-up (011).

## 4. Missing — decisions the code makes with no ADR

| New ADR | Why it is a decision | Source of truth today |
|---|---|---|
| **Two task paths: managed actions run through deliberation; coding tasks run through the harness work loop** | The biggest unrecorded architectural fact: two execution paths with different gates (this is what D2 is really about) | `tamoz-agent-session` (`session_work.rb`, `work_gate.rb`), `tamoz-harness`, `tamoz-context-engine` |
| **Network egress has explicit destination, content and authority constraints** (may absorb 054 and 044's egress) | Inventory model providers, websearch, OTLP, MCP transports/elicitation, Telegram, redirects, and configured command/tool networking. Distinguish destination checks from payload disclosure and process-level containment. One governing decision can retain multiple existing mechanisms; uncovered paths stay Partial | `tamoz-mcp-websearch` egress, `tamoz-otel` egress, `mcp` elicitation URL checks |
| **Harness research/review sub-agents are read-only roles defined as data** | Scope this to harness roles, not every Tamoz child task. Name parent/child authority intersection, tool classification and call/byte/budget limits; refusal at role load is only one enforcing seam | `gems/tamoz-harness` `SubagentRoles`, `prompts/subagent_roles.json`, `test/subagent_spec_test.rb` |
| **Authority is pinned by digest at bind time** | `AGENTS.md` rule ("pin authority; never re-derive it by id"); profiles, policy revisions, catalogs, and egress all follow it, but no ADR owns it | `WorkerRuntime#child_profile_for`, `validate_thread_profile`, approval session binding |
| **Research evidence integrity** | Citations are numbered by the gem, never the model; a source counts only if its excerpt is on a page that was read — an honesty rule as load-bearing as 024 | `gems/tamoz-research` (`sources`, `citations`, `report`), `test/research_spec_test.rb` |

## 5. Simplify tooling after mapping consumers

| Script | Produces | Who reads it | Verdict |
|---|---|---|---|
| `script/adr_validate.rb` | pass/fail | `rake ci` | **Keep.** Cheap, and it catches the structural drift that went unnoticed before |
| `script/adr_verify.rb` | pass/fail | `rake ci` | **Keep.** The only check that ties a record to the code: every cited path and test name must exist, so a moved file or renamed test fails CI |
| `script/adr_catalog.rb` → `catalog.json` | committed JSON | Parser is used by the validator; committed JSON feeds graph/staleness checks | **Candidate: remove the committed view**, keep parsing/relations in the existing validator library. Preserve numbering, uniqueness and reciprocal amendment/supersession checks; update templates, lifecycle, rubric and tooling fixture tests atomically |
| `script/adr_traceability.rb` → `traceability.md` | committed matrix | No runtime consumer identified; it attributes tests by searching for explicit "adr-NNN" mentions, while the evidence register links claims to named evidence | **Candidate: retire.** Register entries link claims to evidence directly. Confirm human navigation needs and preserve invariant/evidence coverage before deleting links and the task |
| `script/adr_graph.rb` → `relationships.md` | committed Mermaid | No runtime consumer identified; 11 edges, all visible in headers and the README's Retired table | **Candidate: retire.** No runtime reader does not prove no human reader. Preserve discoverable relationships and graph-validation coverage in retained tooling |

The simplification target is less maintenance with the same validated relationships and evidence,
not exactly two files: the parser still has to live somewhere. Keep `design-refusals.md` and migrate
its owning links with retirements. Citation existence/name checks remain structural checks, not
proof that the behavior passed.

Retirements and new Accepted records also change `script/generate_requirements_manifest`'s explicit
ADR evidence mappings and the derived manifest/audit. Move evidence to successors, replace stale
pending claims only with scoped checks, regenerate through existing scripts, and run
`test/requirements_manifest_test.rb`. Do not lose a release requirement by retiring its ADR.

## 6. Dependency order and atomic packages

1. **Owner agenda:** record answers to D1/D2/D3/D4/D7/D18/D19, plus D6/D8/D21 and any changed
   obligations in D11/D13/D20. D5 is enforcement of the standing rule. Keep remaining choices open
   with an owner and an explicit follow-up; an agenda entry is not an accepted decision.
2. **Documentation CI (D22):** add the bounded ADR/documentation path-triggered gate before relying
   on documentation-only PR validation. Preserve existing lane budgets and test trigger coverage.
3. **Governing decisions:** record the two task paths and the permitted pre-plan contract together
   with D2/ADR-022; establish egress scope before absorbing 054/044. Write the harness-role,
   authority-pinning and research-evidence decisions, using current free numbers at authoring time.
4. **Authority packages:** bind D1/D3/D4/D19 answers to 049/053/030, their policy/code/tests and product
   consumers. A documentation-first decision may remain Partial with a linked implementation task;
   never describe the proposed behavior as shipped. Amend affected invariants in that same decision
   package. D14 covers stale clauses 44/51/58; review 25/55 with D2. There is no final invariant-only
   cleanup phase that leaves an intervening contradictory contract.
5. **Implementation repairs:** D5 legacy tolerance and D7 worker transport each get a focused tested
   change against the retained ADR; D18 implementation follows only the accepted compatibility choice.
   Prioritize the transport/approval risks over editorial consolidation.
6. **Consolidation packages:** successor content, source tombstone/RETIRED row, amendment relations,
   index/design/refusal links, applicable invariant changes, and manifest/evidence migration land
   together. This includes policy-doc moves for 010/013 and real-provider evidence rules for 024.
7. **Tooling simplification:** remove selected views/tasks only after the consumer/coverage map is
   complete. Update parser/validator fixtures and every affected workflow/template/link in the same
   change. Until then regenerate the retained committed views normally.

**Remaining agenda coverage:** D9 cancellation ownership, D10 shared-DB compromise acceptance,
D12 scheduler release scope, D15 new authority/evidence decisions, D16 release-manifest evidence,
D17 qualifying real-provider result, and D20 improvement identity/holdout scope must have explicit
outcomes or tracked residuals. D11/D13 may remain deferred only without a completion claim. The
program is not a command to implement every deferred feature in this round.

Each implementation package sets its own quality bar before edits, maps the existing seam with
Enola where structural, and runs the applicable gates. Use a fresh reviewer before every commit;
fix critical/high findings, retain no-backward-compatibility and facade boundaries, and report
real-model evidence separately from plumbing. No new parallel mechanism is implied by a new ADR.

## 7. Done when

- Every retired rule, invariant link and verification obligation has a retained home or an explicit
  owner-approved withdrawal; no release requirement silently disappears.
- Each accepted authority change has a dated decision/history entry, coherent invariants and
  consumers, and discriminating evidence for implemented behavior.
- A Complete label is supported by checks run for that change. Remaining Partial obligations name
  an owner, a tracked task and a release disposition; scheduling alone does not make them pass.
- D1–D22 have recorded answers or explicit residuals; the missing decisions are recorded, or their
  obligations incorporated into an existing owner with a stated reason.
- Retained ADR tooling preserves identity, lifecycle/relations, link and citation checks. Relevant
  documentation, tooling, manifest and implementation gates pass at the applicable scope; D22
  ensures ADR-only PRs actually run their checks.
- The final quality-bar iteration changes nothing and has no FAIL/OPEN row; any deferred behavior
  remains clearly outside that completed package's scope, or is explicitly waived by the owner.

Record/script counts are reported after the work, not acceptance thresholds. This plan edit changes
no accepted rule and closes no implementation gap.
