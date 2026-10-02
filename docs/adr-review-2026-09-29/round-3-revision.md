# Round 3 — Revision of the ADR corpus

Date: 2026-10-01/02. Rounds 1–2 reviewed; this round **rewrote** the corpus, raised the bar, and
upgraded the tooling. Every ADR was re-read against the code it describes. Decisions that changed
meaning are flagged for the owner in [round-3-discussion.md](./round-3-discussion.md); nothing here
changes runtime behavior or approval policy.

## What changed, in one table

| Area | Before | After |
|---|---|---|
| Bar | v1 (2026-08-29): sections present, Verification names a gem or symbol | v2: truth (A4), claim scope (A6), policy honesty (A7), credible alternative (E3), reopen trigger (E6), proof table with evidence kinds and limits; acceptance needs a semantic review, not just green tooling |
| Shape | Numbered and unnumbered variants; boilerplate (`Current version`, fan-in counts, tier links, duplicate Next reads) | One header (`Status`, `Date`, `Tier`, `Implementation`, relations) and one section order for every ADR |
| Honesty about gaps | Present tense for unbuilt parts | `Implementation: Partial — <gap>` on 10 ADRs; nothing unbuilt is described as shipped |
| Relations | Status-line verbs (revised, extended, instantiated, completed) | `Amends`/`Amended by`, `Supersedes`/`superseded by`, all reciprocal and checked |
| Corpus size | 55 numbers, 52 in force | 59 numbers, 51 in force (50 accepted, 1 proposed), 8 retired |
| Catalog | Flat list by number | Grouped by area; Tier and Implementation per row |
| Home | ADRs mixed with the 2026-08-29 audit and the 4,000-line approval redesign study | ADRs and their rules only; the audit moved to `docs/adr-audit-2026-08-29.md`, the study to `docs/approval-policy-redesign-2026-08-22/` |

## Retired or merged (5)

| ADR | Into | Why |
|---|---|---|
| 004 `Tamoz.seq` | withdrawn | The API was never built; composition is the graph plus plain Ruby |
| 035 Streaming runtime | 036 + 055 | Its surviving rule (evidence becomes a sealed Situation first) is 036's; the runtime moved to Go |
| 037 Event-time contracts | 055 | Those contracts are `agentic-stream`'s; 055 states that Tamoz computes none |
| 043 Telegram deny-only | 049 | Deny-only ended; the reference-binding rule lives in 049 |
| 051 RubyLLM removed | 048 | One decision with the model transport |

## New ADRs (3) — rules that lived only in `AGENTS.md` or code

| ADR | Rule |
|---|---|
| 057 | A user's stop ends the turn; it never aborts the graph |
| 058 | Domain knowledge is digest-pinned data, never code |
| 059 | No backward compatibility before 1.0 |

The gem-facade rule ("nobody reaches past a gem's facade") moved from `AGENTS.md` into ADR-052; the
effect-journal rule (request-keyed identity, immutable terminal receipts, `EffectDispatcher.run` for
every non-deterministic call) into ADR-016; "real model for real runs" into ADR-024.

## Corrections found by reading the code (round 3)

Beyond rounds 1–2, this pass found:

| Finding | Where it now shows |
|---|---|
| Profiles **cannot** change approval evidence (`apply_profile` allows only tier defaults, timeout, simulations). ADR-049's status line said a profile could require `filesystem_operator`. | ADR-049 Decision |
| Evidence is document-wide: every `ask` — including `destructive` and `external_publish` — is approvable from chat. | ADR-049 Threat model, discussion D1 |
| The surface mode named `deny_only` shows Approve **and** Deny under today's policy. | ADR-049, comms design §8 |
| Base policy allows `workspace_write` without asking; the product page promises "nothing changes a file without an approval you granted for that exact diff". | ADR-053 residual risk, discussion D3 |
| Under the `auto` profile, unclassified tools (including unclassified MCP tools) run without asking, because the fallback tier is `local_execute`. | ADR-053 residual risk, discussion D4 |
| The coding work loop plan-gates only `apply_patch`, `create_file`, `run_check`; reads, web research, and read-only delegation run before any plan. | ADR-022 Implementation, discussion D2 |
| The episode worker binds insecure gRPC ports on both transports; there is no mTLS, despite code comments and ADR-055. Socket permissions are the only authentication. | ADR-055, discussion D7 |
| Skill install is two-person and digest-pinned, but the "comparative evaluation" ADR-034 promised is not built. | ADR-034 Implementation |
| Cron/IANA scheduling is not built (ADR-032 described it as decided behavior). | ADR-032 Implementation |
| Tamoz ships no protection codec; sensitive store values fail closed unless the operator supplies one. | ADR-020 Implementation |
| `test/legacy_session_resume_test.rb` requires reading a pre-P8 database — the read-time tolerance `AGENTS.md` forbids. | ADR-059 Implementation, discussion D5 |
| `Cancellation::Stops` is a process-global registry (invariant 14 forbids mutable globals after boot). | ADR-057 Residual risk, discussion D9 |
| No sampling code exists anywhere; ADR-047 described "export-time sampling" as shipped. | ADR-047 rewritten |
| `Tamoz::App`, named in ADR-001 as the home of application code, does not exist. | ADR-001 rewritten |

## Tooling

| Tool | Before | After |
|---|---|---|
| `rake adr:validate` | Context/Decision/Consequences present; status prefix; duplicates checked after hash collapse | Status grammar; Date/Tier/Implementation (a Partial must name its gap); required sections and order per tier; a `**Cost:**` in Consequences; banned boilerplate; relation headers linked and reciprocal; duplicate headers; tombstones keep a Date and no sections; duplicate numbers checked before indexing; links and anchors outside code; README index coverage; catalog sync |
| `rake adr:verify` | Existence of backticked `gems/`, `docs/`, `documentation/` paths; not in `rake ci` | Also `test/` paths, and every cited `test_*` name must be defined in a test file cited on the same row; absence wording exempts only its own table cell; now runs in `rake ci` (441 citations hold) |
| `rake adr:catalog` | Parsed status-line verbs | Parses header relations and `Implementation` |
| `rake adr:trace` | Invariants only from "invariant N" prose | Also from the `Invariants` section |
| Tests | none for the tooling | `test/adr_tooling_test.rb`: 15 tests, one failing case for every validator and verifier rule |

The validator still cannot judge truth. A record can pass every check and be wrong; that is what
the semantic review in the bar's §7 is for.

## Consumers updated

`documentation/design/comms.md` (§8 and the decision list), `documentation/roadmap.md`,
`test/comms_adr049_consistency_test.rb` (now pins ADR-049 to the live `evidence.approve` in
`base.yaml`, so the drift that happened on 2026-09-24 would fail CI), `test/documentation_test.rb`
(ADR count), `script/generate_requirements_manifest` (rows for 056–059 and the missing
`tamoz skills` row that kept it red at HEAD; rows for retired ADRs removed), and every link to a
renamed ADR file across `docs/` and `documentation/`.

Not updated, and why: `docs/design-v0.1/INVARIANTS.md` clauses 44, 51, and 58 still describe the
retired Ruby stream plane and "v1 accepts denial only". The invariants change only through an ADR
with conformance tests, so they are discussion item D14.

## Verification run (2026-10-02, Ruby 3.3.11)

| Command | Result |
|---|---|
| `ruby script/adr_catalog.rb --check` | up to date, 59 ADRs |
| `ruby script/adr_validate.rb` | passed, 59 ADRs, next number 60 |
| `ruby script/adr_verify.rb` | 441 citations hold (paths, gems, and `test_*` names) |
| `ruby -Itest test/adr_tooling_test.rb` | 15 runs, 58 assertions, 0 failures |
| `ruby -Itest test/comms_adr049_consistency_test.rb` | 4 runs, 16 assertions, 0 failures |
| `ruby -Itest test/documentation_test.rb`, `documentation_tree_test.rb`, `documentation_surface_test.rb` | 3 / 7 / 9 runs, 0 failures |
| `ruby -Itest test/requirements_manifest_test.rb` | 11 runs, 0 failures (4 failures at HEAD before this change) |
| `script/generate_requirements_audit --jobs 4` | ran 305 named cases: 551 rows pass, 0 failing; 14 release-blocking rows are pre-existing `missing` (ADR-041/042/044–047, INV-39, INV-56–61, OBJ-7) |
| `rake ci` | design and ADR validation pass; `test_fast`: 309 files, all passed; then stopped at `stream:proto:check` because the local `grpc_tools_ruby_protoc` binary is the wrong CPU type — an environment problem unrelated to this change |
| `rake quality:architecture` (run separately) | PASS — no structural regression |
| RuboCop on changed Ruby | 0 offenses in the rewritten `script/adr_*.rb` and new or edited tests; `adr_traceability.rb` unchanged at 54 pre-existing |

Deterministic tests only; no real model was called, and nothing here is evidence about agent
behavior. Two independent read-only reviewers checked the rewritten ADRs against the code; their
findings and what was done about them are in the next section.

## Independent review (2026-10-02)

Two reviewers, split by lens pair (truth + claim scope on the authority and durability ADRs;
soundness + organization on the rest, the bar, and the tooling), read every in-force ADR against
the code. Every finding was spot-checked and fixed in the ADR text or moved to the owner agenda:

| Kind | Fixed in the ADRs |
|---|---|
| Wrong owner named | 026 (Wisdom promotion is `Memory::Wisdom`, not `tamoz-evals`), 028 (stages are `RuleRegistry`/`PromotionGate`), 014 (closed source set is `Capability::Registry`) |
| Claims broader than the code | 016/021 (effect keys exclude the execution id; forks differ by request id), 019 (the digest does not see node code; no migration tool exists), 047 (disk-error loss is counted once, not per signal), 049 (approve and deny share binding; TTL is operator-set; prompt pins the first interrupt; no tool is classified destructive/publish), 053 (grants return after a mode round-trip; runtime `read_only_tools` bypasses policy data; profile simulations replace base's), 022/030 (plan intersection only for plan-bound tools), 023 (human gate is a caller-asserted string), 020 (only typed secrets are refused), 042 (worker can make the gateway send any text; credential split depends on env), 044, 052, 058 |
| Missing threat | 055 (TCP binds `0.0.0.0` unauthenticated; socket permissions left to umask) — now Partial |
| Weak citations | 008, 049, 057 (rows now say "source inspection" with the gap in Limit, or cite the right test); new rows for 027, 028, 033, 044, 049, 054 |
| Straw alternative | 026 (replaced with a real competing design) |
| Round-2 rule missed | Rejected alternatives written in this round are now marked *(retrospective, 2026-10-01)* — 53 rows; the bar requires the label |
| Tooling false greens | Absence wording exempted a whole row; bare `Partial`, unlinked relation headers, duplicate headers, tombstones with sections, missing Cost, and `adr:verify` outside `rake ci` all passed. All fixed and each has a failing-case test |

New owner items from the review: D18–D22. Deferred on purpose: a fixture for "contradictory
verification-scope claim" (round-2 wave 2) — that is a semantic judgment, which the bar assigns to
review, not to a regex.
