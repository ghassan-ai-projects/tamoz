# Round 3 — Discussion agenda, one ADR at a time

Use this to walk the corpus with the owner. Part 1 lists the decisions only the owner can make (D1–D22), most
consequential first, each with a recommendation. Part 2 goes ADR by ADR: the rule in one line, what
round 3 changed, and what is open. "Keep" means the rewrite is believed correct and needs only a
yes.

Lenses applied to every ADR: truth against code · claim scope · authority and threat · credible
alternative · cost and proportionality · implementation status · one decision per record · evidence
quality (every cited test name now checked mechanically).

## Part 1 — Owner decisions

| # | Decision needed | ADRs | Recommendation |
|---|---|---|---|
| D1 | Chat can approve **every** asked action, because `evidence.approve` is document-wide and profiles cannot change it. No tool is classified `destructive` or `external_publish`, so destructive MCP tools are unclassified `local_execute`. The prompt pins the evidence of the *first* pending interrupt but the decision answers all of them. The prompt TTL is operator-set with no upper bound. Keep? | 049, 053 | Three changes together: evidence per tier in policy data (`filesystem_operator` for `destructive`/`external_publish`); a way to classify tools into those tiers (or D4's separate fallback tier); and the delivery sink pinning the strictest evidence across all pending interrupts. Rename surface mode `deny_only` (it shows Approve today) — `affirmative` already exists for role-based approval, so pick a name that does not collide, e.g. `buttons`. |
| D2 | The coding work loop lets reads, web research, and read-only delegation run before any accepted plan; ADR-022 says no task action runs without one. | 022 | Narrow ADR-022 to effect-bearing actions (mutate, execute, publish, delegate-with-effects) and govern reads by approval tier + egress; amend invariants 25/55 to match. The alternative (gate reads behind a discovery plan) costs a model round-trip per task. |
| D3 | `product.md` and the README promise "nothing changes a file without an approval you granted for that exact diff", but base policy allows `workspace_write` without asking. | 053, 022 | Decide which is true. If the plan review counts as that approval, reword the promise to say so; if not, set `workspace_write: ask` in base. |
| D4 | Under the `auto` profile, unclassified tools — including unclassified MCP tools — run without asking (fallback tier is `local_execute`). Separately, operator runtime config (`read_only_tools`) moves a classified MCP tool to tier `read`, outside policy YAML — against the `AGENTS.md` rule that approval lives only in policy data. | 053, 030 | Give unclassified tools their own fallback tier that no profile can set to `allow`; move `read_only_tools` into policy data or have the engine refuse a runtime read-only claim the policy does not list. |
| D5 | `test/legacy_session_resume_test.rb` requires reading a pre-P8 database, which is the read-time tolerance `AGENTS.md` forbids. | 059, 019 | Keep the typed refusal, delete the tolerance and its fixture. |
| D6 | ADR-052 now says a concern becomes a gem only when it needs its own dependency boundary (was: every agent concern is a gem). | 052 | Confirm. It matches how 056 was argued and costs nothing today. |
| D7 | The episode worker has no transport authentication. Both transports bind insecure gRPC ports; the worker does not set socket permissions (umask decides); TCP mode binds `0.0.0.0`, and nothing stops `--port` in production. Code comments claim mTLS. | 055 | Have the worker create the socket in a 0700 directory and refuse TCP unless an explicit development flag is set (or bind TCP to 127.0.0.1); remove the mTLS claim. Small code change in `tamoz-stream`. |
| D8 | CI tests only Ruby 3.3.11; 3.4 and 4.0 are untested "primary targets". | 010 | Before the first release, either add a non-pinning 3.4/4.0 job (with sealed-build pins keyed by Ruby version) or drop the promise. |
| D9 | `Cancellation::Stops` is a process-global registry, against invariant 14. | 057 | Inject it as a worker-owned service so it is not ambient; until then, record the exception in invariant 14. |
| D10 | The gateway and worker share one SQLite file; a compromised gateway can write approval decisions directly. | 042 | Accept for a single-operator host and say so in the security model; revisit with separate OS users if Tamoz runs multi-user. |
| D11 | Skill install has no comparative evaluation (ADR-034 promised one). | 034 | Keep as Partial; build it with the skills optimizer work, or drop the clause if the two-person install is judged enough. |
| D12 | Cron with an IANA timezone is not built. | 032 | Keep as Partial; decide at release whether the scheduler ships without cron (the requirements audit already lists INV-39 as a gap). |
| D13 | Tamoz ships no encryption codec for sensitive store values. | 020 | Ship one (AES-256-GCM via OpenSSL, key from a credential reference), or state that sensitive values are unsupported without operator code. |
| D14 | Invariants 44, 51, 58 still describe the retired Ruby stream plane and "v1 accepts denial only". | 036, 049, 055 | Amend `INVARIANTS.md` through an ADR (it is change-controlled); this round did not touch it. |
| D15 | Three newer gems have no ADR: `tamoz-context-engine`, `tamoz-harness`, `tamoz-research`. | 009, 024 | ADR-009 now covers the frozen header and append-only surface. Write one ADR for research evidence integrity (citations numbered by the gem, never the model; a source is accepted only when its excerpt is on a page that was read) — that is a load-bearing honesty rule. |
| D16 | Requirements-manifest rows for ADR-041/042/044–047 still say "pending, lands with the gems", though the gems and tests exist. | 041–047 | Convert them to direct evidence using the tests now cited in those ADRs. |
| D17 | No real-provider run yet meets the benchmark protocol. | 024 | Keep ADR-024 Partial until one does; it is the honest state. |
| D18 | The graph definition digest covers node names and declared versions, not code: a node body changed without a version bump resumes old checkpoints silently. | 019 | Add a test that fails when a node's source changes without a version bump (digest the source in a test fixture), or accept the residual explicitly. |
| D19 | Session grants come back after a mode round-trip (implement → review → implement), because grants are keyed by policy revision. | 053 | Purge a session's grants on any rebind; a mode switch is a moment to re-ask. |
| D20 | The human gate for improvement candidates is a caller-asserted string (`human:<actor>`), not an authenticated identity. | 023 | Bind it to the same evidence lattice as approval (`filesystem_operator`). |
| D21 | ADR-055 bundles three choices (authority split, Go, second repository). | 055 | Keep one record: the language and repository were chosen once, together, as consequences of the authority split; split them only if one is revisited. |
| D22 | `.github/workflows/ci.yml` ignores `docs/**` and `documentation/**`, so an ADR-only change runs no CI at all, even though `rake ci` now runs `adr:validate` and `adr:verify`. | all | Add a small workflow job that runs only the ADR and documentation checks on those paths. |

## Part 2 — ADR by ADR

### Identity, packaging, evolution

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 001 | One name: `Tamoz`, `tamoz-*`, `tamoz` CLI | Dropped `Tamoz::App` (does not exist) and the stale gem count; moved the trademark action to the roadmap | Keep |
| 010 | Ruby 3.3 floor; 3.4/4.0 targets | Implementation: Partial — CI runs only 3.3.11; recorded the sealed-build reason | D8 |
| 013 | Vocabulary is a budget, not a cap | Tightened; inclusion rule stated | Keep |
| 014 | Extensions are first-party adapter gems, not plugins | **Retitled and widened**: now owns the extension rule for sources, transports, exporters; credible alternative (versioned third-party adapters) argued; reopen bar written | Confirm the widening |
| 040 | One monorepo, independently publishable gems | Amended by 055 recorded both ways; stale audit note removed | Keep |
| 052 | A gem owns one dependency boundary, reached only through its facade | **Rule change proposed** (D6) and marked as such; facade-only rule moved in from `AGENTS.md`; the evals-runner → CLI dependency named | D6 |
| 056 | Skills are a gem behind one facade | Amends 033 both ways | Keep |
| 059 | No backward compatibility before 1.0 | **New**, from `AGENTS.md`; Partial | D5 |

### Graph runtime and state

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 005 | Interrupt by `throw`, caught in the worker | Corrected where the `catch` lives (the pool, not the executor) | Keep |
| 006 | Plain Hash state, explicit reducers | Added the conflicting-write rule and the rejected alternatives `design-refusals.md` claimed | Keep |
| 007 | State is frozen at commit | Replaced the fan-in "proof" with codec tests | Keep |
| 008 | `:threads` default, `:inline` in tests | Removed the false three-pool equivalence; fibers are refused | Keep |
| 009 | The request prefix is byte-stable within a cache epoch | **Retitled** from "is invariant 16"; now cites the context-engine header and series | Keep |

### Durability and effects

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 011 | SQLite default persistence | Deployment envelope stated (one host, local FS, `synchronous=FULL`); alternatives added | Restore procedure is undocumented |
| 015 | Durable = synchronous barrier commit | Rejected alternatives and crash tests added | Keep |
| 016 | Every effect is journaled; ambiguity stops as `:unknown` | **Retitled** (old title "at-least-once" misled for unsafe effects); absorbed the `EffectDispatcher`, request-keyed identity, and immutable-receipt rules | Keep |
| 017 | One fenced writer per namespace | Threat model with the honest residual (file access bypasses fencing) | Keep |
| 018 | Sequence separate from identity | Evidence sharpened | Keep |
| 019 | Resume is graph-version checked | Separated from the database no-compat rule (059); residual corrected — the digest does not see node code; no migration tool exists | D18 |
| 021 | Resume keeps execution identity; fork changes it | Worked rules and tests | Keep |
| 057 | A user stop ends the turn, never aborts the graph | **New**, from `AGENTS.md` | D9 |

### Agent authority

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 022 | Every task action needs a reviewed, digest-bound plan | Implementation: Partial (work loop); the cheaper alternative is now argued honestly | **D2** |
| 030 | One catalog; the application assigns authority | Threat model; amended-by 054 both ways | D4 |
| 053 | Approval policy is data, decided by `tamoz-approval` | Profile names corrected; who enforces evidence stated; `auto`, `workspace_write`, and `read_only_tools` residuals stated; grant round-trip stated | **D1, D3, D4, D19** |
| 049 | Chat approval is evidence-gated, bound to one prompt | **Rewritten** to the live policy: removed "residual risk is zero"; profiles cannot change evidence; absorbed 043 | **D1** |
| 029 | MCP through the official SDK; Tamoz owns safety | Supersedes 012 both ways; threat model | Keep |
| 054 | Websearch = reserved MCP server with governed egress | Stale "030 was never updated" removed; query-text exfiltration stated as unmitigated | Keep |
| 033 | Skills: open format, inert recipe | Removed false capabilities-gem attribution; amended by 056 | Keep |
| 034 | Skill identity = tree digest; install is promotion | Implementation: Partial (no comparative evaluation); ownership corrected | D11 |

### Data protection

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 020 | Secrets refused by type, never scrubbed by name | **Retitled**; scoped to the swept surfaces; Marshal refusal recorded; Partial (no codec shipped) | D13 |
| 046 | Content capture off by default, restricted refused | Classification ranks named | Keep |

### Memory and learning

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 026 | Experience → Knowledge → Wisdom | Reframed as authority levels; the unified-typed-store alternative argued | Keep |
| 027 | Retrieval authorizes before ranking | Facade and deletion evidence; residual (artifacts outside memory) | Keep |
| 023 | Self-improvement is promotion, never live mutation | Partial: heuristics get the holdout; profile/skill/config get human approval only; code has no path | Should non-heuristic candidates need a holdout? D20 |
| 028 | Healing is bounded remediation | Lifecycle evidence; threat model | Keep |

### Evaluation and evidence

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 024 | "Smart" is measured; only real-provider runs count | Absorbed "real model for real runs"; Partial | D17 |
| 025 | Evaluation is outside the runtime | Evals vs evals-runner split stated | Keep |
| 058 | Domain knowledge is digest-pinned data | **New**, from `AGENTS.md`; Partial (loader still has domain branches) | Clean the loader |

### Scheduling

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 031 | Scheduler materializes occurrences, never runs agents | Tier C (no authority of its own) | Keep |
| 032 | Time and delayed authority are explicit | Partial: no cron/IANA | D12 |

### Model boundary

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 048 | Tamoz owns the model boundary: one OpenAI-compatible transport | **Absorbed 051**; credible alternative (SDK behind a Tamoz projection) argued; threat model | Keep |

### Channels

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 041 | Contract gem plus per-transport gems | Defers the extension argument to 014 | D16 |
| 042 | Gateway is a separate process | Shared-database residual risk stated plainly | D10 |

### Observability

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 044 | Contract gem plus per-exporter gems | Egress rules evidenced | D16 |
| 045 | No telemetry table; the journal is lossy | Journal described as bounded and lossy | D16 |
| 047 | Never sampled at record time; reserved lane | **Retitled**; "records everything" removed; loss paths and how each is (or is not) counted listed | D16 |
| 050 | Automated responses act only on durable evidence | Still Proposed; clause 62 is proposed, not counted | Keep proposed |

### Streaming and physical action

| ADR | Rule | Round 3 | Open |
|---|---|---|---|
| 036 | Cognition sees only a sealed snapshot | **Retitled; absorbed 035**; digest proves consistency, not origin | D14 |
| 038 | Physical action = typed intent + current-state policy | Intent catalog as pinned data; Go-side limit stated | Keep |
| 039 | Tamoz is supervisory | "Impossible to weaken" scoped to a deployment requirement | Keep |
| 055 | Go continuous plane; Tamoz is the episode worker | **Absorbed 037**; authority, language, and repository argued separately; Partial — no transport authentication; journal scope corrected | D7, D21 |

### Retired this round

004 (withdrawn), 035 → 036/055, 037 → 055, 043 → 049, 051 → 048. Earlier: 002 → 052, 003 → 048,
012 → 029. Confirm each retirement, or say which should come back as its own record.
