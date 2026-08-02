# DR-2 — Durable circuit record: one type, four scopes

Status: design round — revision 3 (checkpoint deep-review corrections integrated;
see `docs/reviews/DESIGN_CHECKPOINT_6FF0D40_DEEP_REVIEW.md`)
Origin: P12 plan review C1; P13 plan review C6; verified: no durable circuit exists in
`tamoz-sqlite`; the P10 supervisor circuit landed in-memory at `534a502` and the
invocation slice is wiring it now; `pool.rb` has a permanent process-local circuit with
no reset path (deliberately NOT an instantiation of this record — process-local thread
liveness is not a scope health condition and operator-evidence reset is meaningless
there; stated so the second-engine automatic-fail cannot fire on it later).
Authoritative inputs: `SELF_HEALING_DESIGN.md` §10, `SCHEDULER_DESIGN.md` §10,
`P10_MCP_PLAN.md` §8, invariants 17, 18, 32, 33, the Store CAS machinery, and the
StateCodec constraints (symbols unsupported; object keys sorted; 4 MiB default cap).

## 1. Problem

P10 (supervisor transport), P12 (rule/target conditions), P13 (scheduler failures), and
P17 (egress health) all need "a durable circuit". If each builds its own, that is the
"second engine" the handover protocol forbids. None exists today; P10's landed
supervisor circuit is in-memory (`534a502`), and the invocation slice (in flight) is
wiring it. The record's shape must be decided before that freezes.

## 2. Design decision

ONE durable `CircuitRecord` per scope, persisted as a **string-keyed Hash** in
the already-migrated Store (namespace `tamoz.circuit.<scope_type>`, key `<scope_digest>`;
no new table, no schema change — the Store tables are already migrated, invariant 18
codec). Symbols are unsupported by StateCodec; the Hash's sorted object keys give
canonical serialization for free.

`<scope_digest>` is the domain-separated digest of the canonical typed
scope identity, not raw `rule_id/target` concatenation. The bounded human-readable
identity remains inside the record. This avoids delimiter collisions, leaks through key
enumeration, and `MAX_NAME_BYTES` failures.

```ruby
# stored shape (string keys):
{
  "scope_type" => "server" | "rule_target" | "schedule" | "egress",
  "scope_id"    => "<server_id>" | "<rule_id>/<target>" | "<schedule_id>" | "<egress_profile_id>",
  "state"       => "closed" | "open",
  "threshold"   => <integer per scope type>,
  "owners"      => {                            # bounded, stable policy identities
    "<owner_id>" => {"failures" => ..., "conditions" => ...}
  },
  "conditions_met" => [ <typed evidence digests, ring-buffered, C8> ],
  "opened_at_wall_ms" => <backend wall time>,
  "probe_window_ms" => <duration, not absolute>,
  "reset_authority" => "owner" | "tamoz-evals" | "human_approved_plan",
  "last_reset_at" => nil | <ms>,
  "last_reset_evidence" => nil | <digest of the reset command/plan/eval evidence>
}
```

**Atomicity (C1):** every `record_failure`/`record_success` is ONE atomic CAS
read-modify-write (`Store#put if_version`) that evaluates the threshold INSIDE the
write: update the addressed owner sub-state, then
`new_state = any_owner_predicate_met? ? "open" : state` (or the C3
window/rate predicate). State is written through per event; the in-memory copy is a
read-cache only. Read-time rule: a closed record whose counter/sub-state satisfies the
open predicate is treated `open` and self-healed (same append) — a crash can never lose
an open that the evidence says should exist.

**Multi-owner semantics (C2, corrected):** owner state is a bounded map INSIDE the one
scope record. Owner ids are stable deployment/policy identities supplied by the caller,
never random process UUIDs; restart cannot bypass or orphan evidence. **Any owner whose
counter/window satisfies the predicate opens the same scope record**, observed by all
owners.
A healthy owner's success resets only ITS OWN counter and can never mask another
owner's accumulating failures (P13's 2–50 pollers and P10's two-supervisor cases are
the mandated scenarios). `MAX_CIRCUIT_OWNERS` is explicit (minimum 64 for the P13
proof); overflow fails closed and requires evidence-bearing owner retirement. Two-owner
interleave (fail/fail/success/fail) is a named test.

**Window/rate conditions (C3):** three P12 design-§10 conditions are NOT consecutive:
verification-fails-twice-in-window, same-fingerprint-thrice-in-run, failure-rate/
cost/latency-over-budget. The record carries per-condition accumulator/window sub-state
(`{"kind" => "window", "window_ms" => ..., "events" =>
[{"digest" => ..., "observed_at_ms" => ...}], "predicate" => ...}`)
evaluated inside the same atomic append; if a scope's conditions are evaluated
in-process instead, that is DOCUMENTED and the record persists only the open verdict +
evidence (the durable claim is then partial for that scope — recorded, not silent).

## 3. Scope conditions and thresholds

| Condition (design §10) | P10 server | P12 rule/target | P13 schedule | P17 egress (provisional — see below) |
|---|---|---|---|---|
| consecutive transport failures ≥ threshold | yes (3) | — | — | yes (connect failures) |
| verification fails twice in window | — | yes (window sub-state) | — | — |
| one compensation/rollback fails | — | yes | — | — |
| same fingerprint thrice in one run | — | yes (window sub-state) | — | — |
| unknown effects > 0 for safe-retry rule | — | yes | — | — |
| failure rate/cost/latency over budget | — | yes (rate sub-state) | yes (rate sub-state) | yes (budget) |
| detector precision/confidence below gate | — | yes | — | — |
| evaluator/rule artifact unverifiable | — | yes | — | — |
| consecutive scheduler/execution failures | — | — | yes | — |

Note: the P13 budget row EXTENDS `SCHEDULER_DESIGN.md` §10 (which names consecutive
failures only) — flagged as an addition, not a mapping. The `:egress` scope is
PROVISIONAL: no reviewed input yet names an egress circuit (the P17 plan proposes it);
it is marked provisional in the registry until P17's source is accepted.

## 4. Semantics

- `open` disables mutation: P10 → no MCP calls to that server (typed-unavailable);
  P12 → no remediation mutation by that rule/target; P13 → no new claims by that
  schedule; P17 → no outbound calls on that profile.
- **Open-vs-in-flight (C10):** opening NEVER blind-cuts an already-dispatched
  non-idempotent effect — per design §7, an in-flight effect at open is journaled
  `:unknown` and reconciled (never aborted silently, never retried blindly). Per scope,
  the transition rule is pinned: complete-and-journal vs abort-to-unknown.
- Time alone never resets: `probe_window_ms` permits probe/observation; returning to
  `closed` requires the reset authority path (below).
- Success resets the OWNER's counter/sub-state only; it does NOT close an open circuit
  (only the authority path closes it).
- **Corruption (C6/DC-2b):** a corrupt record fails closed (scope treated `open`,
  observation only) AND reset-with-authority is PERMITTED. Public `Store#get` cannot
  return the version when payload decode fails, so ordinary get→put CAS cannot repair
  it. The injected `CircuitStore` contract includes
  `repair_corrupt(scope:, evidence:, expected_payload_digest:)`; the sqlite
  implementation reads the raw head/version inside one transaction, verifies the
  observed corrupt digest and reset authority, and appends a canonical closed repair
  record. No generic raw-Store overwrite is exposed. The notification/
  escalation owner per scope is named: P10 → operator command channel; P12 → the
  escalation record (`tamoz.escalations.<id>`); P13 → the schedule owner; P17 → the
  egress profile owner.

## 5. Reset authority (C4)

- `closed → open`: the owning component writes the open transition with
  `conditions_met` evidence. No human gate to OPEN (circuits must open automatically).
- `open → closed`: ONLY the authority in `reset_authority`, with per-scope evidence
  weight:
  - `:server` → `owner` = a caller-command record (operator command digest + identity);
    the P10 §8 "until the caller resets" contract, NOT a plan review.
  - `rule_target` → `tamoz-evals` or `human_approved_plan` with plan/eval evidence.
  - `schedule` → `owner` or `tamoz-evals` with eval evidence.
  - `egress` → `owner` with the operator command record.
- The evidence gate lives on the RECORD WRITE (`put if_version` with `reset_evidence`
  validated), so no in-process caller can bypass it. The Supervisor API is
  `reset(evidence:)` — the in-flight slice-3 builder has been instructed to freeze
  this form now (evidence-free resets bake in a bypassable gate).
- A component cannot reset its own circuit: the adversarial test runs against the
  Supervisor API (not just the record) and asserts refusal.

## 6. Failure model

| Situation | Type | Behavior |
|---|---|---|
| call into an open circuit | `CircuitOpen` (single pinned class — P12/P13 already name it; `CircuitOpenError` was a variant name, now retired) | typed-unavailable / observation-only per scope |
| concurrent writes (two failures, or fail/success race) | Store `CheckpointConflictError` | merge protocol (C7): read version → merge → CAS; on conflict re-read + retry, bounded; on exhaustion escalate and drop NO evidence silently |
| unauthorized reset attempt | propagates as a policy violation | refused; adversarial test asserts |
| corrupt record | fail closed `open` | observation only; scoped `CircuitStore#repair_corrupt` with authority + observed digest repairs; escalation owner notified |
| clock rollback during probe window | duration-derived window (C10) | probe eligibility uses elapsed monotonic evidence in-process and conservative backend-wall recovery after restart; rollback never enables mutation early |
| owner map full / unstable owner id | typed configuration/policy failure | fail closed; retire an owner only with evidence |

## 7. Tests (DR-2 acceptance)

- D1 each scope's open conditions individually — INCLUDING the non-consecutive window
  pair (verification fail → success → fail in-window → open) and a budget-rate case
  (C3); never only the consecutive happy path.
- D2 open-disables-mutation per scope type.
- D3 time-alone-never-resets; probe window derived from duration (C10).
- D4 reset-requires-authority with per-scope evidence weight; adversarial self-reset
  against the Supervisor API refused; corrupt-record repair path (D7 sub-probe).
- D5 owner-scoped success-resets-counter-only: one owner's success does not mask
  another's failures (C2); state unchanged if open.
- D6 concurrent writes: one winner; merge protocol deterministic (evidence deduped by
  digest, sorted); BOTH digests present after a two-writer race (C7).
- D7 corrupt record fails closed; ordinary `Store#get` decode failure cannot bypass;
  scoped authorized repair with wrong digest refuses and exact digest recovers;
  escalation owner notified.
- D8 two-owner interleave test (fail/fail/success/fail → the failing owner still opens
  the scope).
- D9 crash-between-increment-and-open: the atomic-append predicate + read-time
  self-heal rule (C1) — a crash after `failures=3` with `state=closed` still results in
  `open` on the next read/append.
- D10 restart identity + bound: a restarted component reuses its stable owner id; UUID
  churn is rejected; the 65th owner fails closed until evidence-bearing retirement.

## 8. Consuming phases

- P10 slice-3/slice-4: supervisor circuit interface frozen (`open?`/`record_failure`/
  `record_success`/`reset(evidence:)`); caller-injected duck-typed `CircuitStore` seam
  (tamoz-mcp stays sqlite-free); the re-home contract is recorded in
  `GAUNTLET_PROGRESS.md` at slice-3 close (the ledger currently does not contain it).
- P12-H3: rule/target circuit on this record (P12 plan §2/§5 reference this DR).
- P13-E: scheduler circuit on this record (P13 plan §2/§11 reference this DR).
- P17: egress circuit (scope marked provisional until P17's source is accepted).

## 9. Review checklist (re-review)

1. Is the atomic-append predicate (C1) implementable on `Store#put if_version` with
   the threshold evaluated inside the write?
2. Does the single scope record atomically preserve every bounded owner sub-state, and
   do stable owner identities survive restart without bypass?
3. Are the window/rate sub-states bounded and serialized within the 4 MiB codec cap
   (conditions_met ring-buffered)?
4. Does `reset(evidence:)` at the Supervisor API surface match the P10 §8 "caller
   reset" contract without widening authority?
5. Do D1–D10 catch the deep-review probes (crash-between-increment-and-open,
   two-owner interleave, non-consecutive window, corrupt-record repair, in-flight
   effect at open, same-process reset bypass, restart identity, owner overflow)?
