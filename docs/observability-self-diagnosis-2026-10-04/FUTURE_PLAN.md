# Deferred: regulatory evidence and the rest of observability — future plan

**Set:** 2026-10-04 · **Why deferred:** owner rule (`AGENTS.md`, "Defer complexity to a future plan"):
*"if EU AI Act is too complicated do not implement it, just make it as a plan for the future"*;
*"anything that adds complexity now we should defer"*. · **Built now:** [`PLAN.md`](PLAN.md).

Each item below is a design ready to pick up: the requirement it serves, the smallest design that
meets it, the tests that would prove it, and the owner decisions it needs first. Nothing here is
built. Legal references are pointers for the owner's counsel, not legal advice.

**Applicability.** None of these obligations attaches to Tamoz as such. The AI Act articles bind
providers and deployers of a *high-risk* system (Annex III, or Annex I products) — for example a
deployment that is a safety component of critical infrastructure; NIS2 / BSIG §32 binds entities
the law classifies as important or essential; GoBD covers tax-relevant records only. Tamoz can only
make the evidence such a deployer needs exist and be trustworthy. The Digital Omnibus timeline was checked against the European Commission on 2026-10-04
(primary source below). Deployment applicability and reporting exceptions still need counsel review.

## 0. What the regulation asks, and what exists today

| Source (where it applies to a deployment in Germany) | Requirement, paraphrased | Built today | Deferred item |
|---|---|---|---|
| EU AI Act Art. 12 — high-risk Annex III obligations apply from 2 Dec 2027 after the Digital Omnibus (in force 27 Jul 2026) | Automatic recording of events over the system's lifetime, enough to identify risk situations and monitor operation | The durable record; `RecordReader`; `diagnose`, `explain` | F1 seal chain |
| AI Act Art. 19 (providers), Art. 26(6) (deployers) | Keep the automatically generated logs ≥ 6 months | Nothing beyond normal backups (`documentation/operations/operations.md`) | F1, F2 retention |
| AI Act Art. 13, 14, 86; DSGVO Art. 15, 22 | Transparency, human oversight, an explanation of an individual decision | `tamoz explain` (decision record with approvals and actor evidence) | F4 approval identity |
| AI Act Art. 72, 73 (serious incident: 15 days; 2 days critical infrastructure or widespread; 10 days death); Art. 73(6) no alteration before the cause is evaluated | Post-market monitoring, incident reports | `tamoz diagnose`, `tamoz postmortem` (read-only by construction) | F3 reporting clocks |
| NIS2UmsuCG / BSIG §32 (in force 6 Dec 2025) | Early warning ≤ 24 h, notification ≤ 72 h, final report ≤ 1 month after the notification | Postmortem timeline | F3 |
| DSGVO Art. 5(1)(f), 5(2), 32; BSI IT-Grundschutz OPS.1.1.5 | Integrity of logs; accountability; logging as a security measure | Digests on every durable row; no tamper evidence | F1 |
| DSGVO Art. 17 vs. retention | Erasure must not read as tampering, and erased content must not survive in evidence | Deletion receipts (`tamoz_deletion_receipts`) | F1 erasure reconciliation |
| GoBD (Nachvollziehbarkeit, Unveränderbarkeit) | Traceable, unalterable records | — | F1 |
| BetrVG §87(1) no. 6 | Works-council co-determination over technical monitoring of employees | Approval actor evidence is a closed symbol set (`cli_tty`, chat), not a person | Owner decision O1 |

**Never supplied by Tamoz** (deployer or provider work): a risk-management system (Art. 9), data
governance (Art. 10), conformity assessment and CE marking, a QMS, BSI portal submission, the
decision whether an incident is reportable, WORM storage, qualified timestamps.

## F1. Tamper-evident sealed audit trail — `tamoz audit seal|verify`

**Serves:** Art. 12, 19, 26(6); DSGVO Art. 5(1)(f), 32; GoBD; BSI OPS.1.1.5.

**Design (no table, no migration, no writer on the runtime database):**

- **Projection.** Every audit-relevant row (requests, request and effect transitions, effect
  attempts, approval decisions and mode switches, tombstones, deletion receipts, occurrences)
  becomes one canonical record of its *settled* fields: write-once fields always, lifecycle fields
  only once the row is terminal. Digests, never content (ADR-046). Reuses `RecordReader`.
- **Seal.** `tamoz audit seal` writes `seal-<n>.ndjson` (sorted canonical records) and `seal-<n>.json`
  (sequence, previous seal digest, sealed-at, sources, counts, records digest, seal digest) to an
  audit directory. A full snapshot each time: each seal stands alone; the chain links them. Report
  files Tamoz wrote (postmortems) are sealed by digest. Run it from cron or a schedule.
- **Verify.** `tamoz audit verify` checks each seal against its manifest, the chain, consecutive seals
  (a record may only *settle* — gain lifecycle fields — never change or vanish unless its thread was
  purged under a deletion receipt, matched by the deleted-thread digest that only `tamoz-sqlite`
  computes), and the latest seal against the live database. Output: `intact`, or the exact records
  modified, removed or forged.
- **ADR.** A new Tier F ADR ("the audit trail is the durable record, sealed"); amends ADR-045's "the
  journal is not an audit log" by naming the sealed record as the audit log. The journal stays lossy.

**Tests:** a tamper matrix (modify, delete, forge a row; edit seal records; edit a manifest; break and
reorder the chain), each detected with the exact record; settlement and erasure-under-receipt verify
`intact`; a purge without a receipt does not; the database is byte-identical after seal and verify.

**Residual risk to state:** rows altered before the first seal are undetectable; a seal kept on the
same disk as the database proves little — anchoring (WORM, a second machine, a qualified timestamp) is
the deployer's job.

## F2. Retention

**Serves:** Art. 19, 26(6). Retention is keeping seal files for the period; Tamoz can report coverage:
`tamoz audit verify --retention 6mo` names the oldest seal and whether the retained chain spans the
period. Pruning or purging the database stays independent because seals are self-contained.
**Tests:** a chain whose oldest seal is younger than the period reports the gap; deleting the oldest
seals reports where the verified chain now starts, never `intact` for the missing span.
**Decision O2:** the default period Tamoz documents (AI Act floor: 6 months).

## F3. Reporting clocks in the postmortem

**Serves:** AI Act Art. 73; BSIG §32. `tamoz postmortem --aware-at T --regime nis2|ai_act_73` adds the
deadlines computed from the declared awareness time. Deadlines are data
(`gems/tamoz-observability/diagnosis/regimes.yaml`, digest-recorded), never Ruby literals. Tamoz never
decides that an incident is reportable; it states the clock *if* it is.
**Tests:** deadlines from data; an edited regime changes the digest; no regime → no clock section.

## F4. Approval decisions bound to a thread and request

**Serves:** Art. 14, 86; DSGVO Art. 22 (explanation of an individual decision). Today
`tamoz_approval_decisions` carries an approval session (`interactive`, `profile:<id>`), so in a shared
worker database `explain` links approvals to a turn by time (`"link": "time_window"`): an approval from
any turn that overlapped in time is shown with the turn being explained. **Design:** a migration adding `thread_id` and
`request_id` columns written at append (pre-1.0: fresh schema, no backfill, ADR-059), and `explain`
selecting by identity. **Tests:** two concurrent turns (same profile and different profiles) each explain only their own
approvals. **Decision:** none beyond the migration ordinal.

## F5. `tamoz trace` from the durable record

Merge durable spans (requests, effect attempts with started/completed times, approval waits) with
journal spans, each marked by source; count a journal span with no durable counterpart as divergence
(invariant 61). Retires the journal-only limitation in `documentation/limitations.md`.
**Tests:** a paused-and-resumed turn is one trace with an ordering-only approval span; a journal
signal dropped under load shows as divergence, never as a missing span. **Decision:** whether the
`TelemetryReader` contract grows a per-execution query or `trace` reuses the per-thread reads.

## F6. Durable model usage (tokens, cost)

Token and cost values are journal-only and lossy today, so `diagnose` cannot report spend. A
separately authorized persistence change (ADR-045 already requires that) would store usage on the
model effect's receipt; `diagnose` would then report spend per operation and window.
**Tests:** usage survives a `kill -9` between the call and the journal flush; a cost carries its
basis (measured or estimated). **Decision:** whether usage belongs on the receipt (changes its
digest) or beside it (a column and a migration) — ADR-045 already requires the owner to authorize it.

## F7. Alerting and automated response (ADR-050)

`diagnose` already computes conditions. Wiring a rule to *notify* (stderr, file, comms control
delivery) or to *ask* (enqueue an investigation request whose id derives from rule and window) is
ADR-050's phase 5 and needs its fault-injection proof first. No actuator in observability, ever.
**Tests:** ADR-050's own list (a degraded window blocks a response; flapping produces one request).
**Decision:** ratify ADR-050 first.

## Owner decisions

| # | Decision | Default if undecided |
|---|---|---|
| O1 | May operator identifiers (actor evidence today is a symbol class; a future chat user id would be personal data) stay in sealed evidence for the retention period? Works-council review (BetrVG §87(1) no. 6) and DSGVO Art. 17(3)(b) | Keep symbol classes only |
| O2 | Default retention period documented | 6 months |
| O3 | Which regimes the postmortem clock ships with | NIS2 (BSIG §32) and AI Act Art. 73 |
| O4 | Order: F4 (cheapest, closes a real traceability gap) → F1 → F3 → F5 → F6 → F7 | as listed |

## Sources

- [EU AI Act Art. 26 (deployers; Art. 26(6) log retention)](https://artificialintelligenceact.eu/article/26/)
- [AI logging under the EU AI Act (Art. 12, 19)](https://www.datenschutz-notizen.de/ai-logging-under-the-eu-ai-act-the-compliance-infrastructure-behind-high-risk-systems-4458904/)
- [European Commission: AI Omnibus entry into force and high-risk timelines](https://digital-strategy.ec.europa.eu/en/news/ai-omnibus-enters-force)
- [BSIG §32: statutory reporting duties and ongoing-incident exceptions](https://www.gesetze-im-internet.de/bsig_2025/__32.html)
- [NIS2UmsuCG obligations and dates](https://www.advisori.de/blog/nis2-umsetzungsgesetz-nis2umsucg)
