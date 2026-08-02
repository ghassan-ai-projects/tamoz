# Design rounds registry

Status: active
Purpose: cross-cutting machinery that more than one phase consumes, or framework
surgery that needs its own design-review cycle, gets a dedicated design round (DR).
A DR produces `docs/DR<n>_<TOPIC>_PLAN.md` + `docs/reviews/DR<n>_<TOPIC>_PLAN_REVIEW.md`
and is committed as a design checkpoint before any consuming phase implements against it.

Source-of-truth order (unchanged): design-v0.1 > phase card > DR > handover plan >
roadmap. A DR may amend a phase plan only in the direction the phase card allows.

| DR | Topic | Consumed by | Design status | Implementation status |
|---|---|---|---|---|
| DR-1 | BehaviorTransition + behavior/cache epoch (shared promotion machinery) | P11-W, P12-I, P16 | **rev4 accepted** | pending; P11 must implement the shared machinery before Wisdom activation |
| DR-2 | Durable circuit record (one type, four scopes) | P10 supervisor, P12-H3, P13-E, P17 | **rev3 accepted** | **egress scope complete via P17 (`78041fc`)** — both open conditions + authority-gated reset; the P10-supervisor/server/rule/schedule scopes' durable record remains for P12-H3/P13-E |
| DR-3 | Memory evaluation substrate (treatment harness) | P11-ED/P11-E, P15-F | **rev2 accepted** | **complete** (`b6c379c`); P11 integrates its production memory adapter into the existing harness |
| DR-4 | Stale durable-request framework fix (D-6 + `:retry`) | P7/P8/P9 runtime, P15-B | **rev3 accepted** | **complete** (`c627aec`); critic 39/39 and gate 857/0 in both required locales |
| DR-5 | P8 §5.3/§5.4 profile machinery completion | P8-F round, P15-B | **rev3 accepted** | **complete** (`be84e8e`); re-adjudication passed |

## Phase-card mapping for the new phases

| Phase | Topic | Source question | Depends on | Status |
|---|---|---|---|---|
| P16 | Tools gem extraction (`tamoz-tools`; D-7 taxonomy to `tamoz-core`) | Q1 (extract tools to a gem?) | P10 close (MCP integration settled), DR-1 | **complete** (`38d2e94` merge; critic PASS-WITH-GAPS + LOAD_PATHS fast-follow) |
| P17 | Websearch capability + egress policy (governed, no raw fetch) | Q2 (websearch for the agent?) | P10 close (MCP capability plane), DR-2 (circuit for egress health), P16 descriptor shape | **implemented (`78041fc`); critic round in flight** |
| P18 | Capability host unification + graph surface audit | Q3 (graph gem usage; growing toolbox special-casing) | P16, P17, P11–P14 close | pending |

Constraint in force for every DR and phase: design and review only until the owning
phase activates; no implementation begins before its design checkpoint is committed and
its phase card is active.

Single-active-phase order from this checkpoint: P17 (critic) → P11 (implementing DR-1
before Wisdom activation) → P12 (incl. the DR-2 supervisor-scope durable record) → P13 →
P14 → P18 → P15. This order is authoritative for scorecard baselines and
SQLite migration allocation; numeric forecasts in older review records are historical.
