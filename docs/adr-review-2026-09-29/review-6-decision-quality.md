# Round 2 — Decision quality, product fit, and architectural economics

Date: 2026-09-29. Scope: all ADRs 001–055, including retired records.
Method: direct reading by the primary reviewer; these are separate analytical lenses, not independent reviewers.
Evidence scope and priorities: [round-2-evidence.md](./round-2-evidence.md).

## Verdict

The corpus records many useful constraints, but often explains why an obviously unsafe alternative loses rather than why the chosen architecture beats a credible simpler design. Several records document what the tree became and then treat that topology as a rule for future work. Better formatting will not repair that reasoning.

Preserve the durable effect, authority-intersection, authorization-before-retrieval, and supervisory boundaries. Reopen the assumptions behind package granularity, control-plane costs, and extension restrictions. Reopening an argument does not authorize changing its implementation.

## D1 — P1: Evidence of existence substitutes for evidence of enforcement

ADR-022 claims that every task action has an accepted review of the exact persisted plan. Its Verification cites `Deliberation` fan-in and then explicitly leaves the conformance citation as follow-up. ADR-023 has the same pattern for promotion and holdout isolation. ADR-026 and ADR-028 cite the presence of their owning gems. ADR-020 cites `Core.secret_shaped?` for a much broader encryption/redaction contract.

These are materially different propositions. A class can exist while an alternative execution path bypasses it. A test can exist while proving only a happy path. A metric can exist without establishing the behavior it names.

**Required repair:** split each strong statement into a claim, enforcing seam, adversarial scenario, expected refusal, and verification result. Show which surfaces the evidence covers: durable session, ephemeral runtime, scheduled work, delegated work, and stream episode. Cite uncovered surfaces as gaps. Do not expand prose to conceal missing evidence. See E1/E2 in [the evidence review](./round-2-evidence.md).

## D2 — P2: ADR-052 makes packaging expansion the default

ADR-052 §2 says: “a new agent concern is a new gem.” Its Context says one gem makes verticals impossible to test, version, or reason about in isolation. Those are three different problems. Modules can be tested within a package; separate package versioning is a distribution choice; authority isolation requires enforcing a boundary.

The rejected alternatives are a monolith, horizontal layers, and plugins. The missing credible alternative is **a small set of independently packaged components with internal vertical modules and mechanically enforced facade boundaries**. That alternative could keep the same runtime boundaries while reducing release overhead.

**Required repair:** distinguish independent installation, ownership, security, release cadence, dependency isolation, and internal organization. For each extracted gem, state which property required a package boundary. Compare the internal-module alternative. Name the compatibility/release cost, and define when a concern stays a module. Use measured changes in dependency closure, package load, or release effort if available; otherwise say those benefits are unmeasured. No gem merge is recommended solely from this review.

Affected records: 013, 025, 040–044, 052–053. The decision must comply with the existing facade-only rule in AGENTS.md; an internal-module alternative is not permission to access another gem's private stores.

## D3 — P2: ADR-055 conflates authority isolation with language and repository choice

The good decision is that Tamoz proposes and the external runtime owns acceptance, budget, and physical effect. Separate processes and restricted credentials can enforce that. A second repository and Go can have useful ownership and performance benefits, but do not themselves enforce authority.

ADR-055 §6 rejects one repository because co-location would blur the authority boundary. ADR-040 explicitly says repository proximity grants no runtime dependency. Those arguments need reconciliation. ADR-055 §1 also locates “hard real-time” in Go without a deadline or scheduling proof. ADR-039 keeps real-time and certified control external; using Go does not establish either guarantee.

**Required repair:** record separately the authority/process boundary, the language choice, and the repository ownership choice. Compare a two-process, two-language monorepo. State the actual latency/throughput constraints and measurements, or classify the language rationale as engineering judgment. Keep the current Go implementation and external control boundary as facts. Do not claim hard real-time capability from language selection. Do not infer a current defect in the sibling repository; it was not inspected here.

Affected records: 035–040, 055.

## D4 — P2: Extension closure has an incomplete cost argument

ADR-014 defers a plugin API until the core stabilizes. ADR-041 and ADR-044 go further: every transport/exporter addition requires a contract-gem release. Their alternatives are presented as untested lazy loading or an unversioned plugin API.

A versioned adapter protocol with a mandatory conformance suite is another credible design. It may still lose, but “plugin” does not imply “untested,” and a first-party package does not by itself prove safe egress. The refusal is valuable only when the actual authority and compatibility concerns are stated.

**Required repair:** separate dynamic untrusted code loading, discovery, adapter registration, wire compatibility, and transport/export authority. Explain which must remain closed, who can register an adapter, and why an externally packaged conforming adapter would or would not be sufficient. Identify the maintenance cost of releasing a contract gem for an implementation addition. Preserve the shipped closed sets unless a later decision changes them.

Affected records: 014, 029–030, 033–034, 041, 044, 054.

## D5 — P2: The uniform plan gate lacks a proportionality argument

ADR-022 has a defensible exact-plan binding rule. Its rejection of planning only high-risk actions is useful. But it declares the one-step plan cheap without a latency, token, storage, or human-attention budget. ADR-024 explicitly values proportional action and stopping at the definition of done.

**Required repair:** define which routes are tasks and which are conversation, distinguish deterministic review from model critic calls and human approval, and measure the gate's overhead for a one-step read, a workspace edit, and a delegated task. Compare a compact one-step plan representation within the same mandatory gate. No ungated action path is proposed. Define material change precisely enough that harmless evidence additions do not become accidental replanning triggers.

Affected records: 009, 013, 021–024, 028, 031–032, 049, 053.

## D6 — P2: Evaluation vocabulary is not an acceptance protocol

ADR-024 lists success, calibration, unnecessary actions, safety, latency, and cost. It does not state what observation establishes those properties, which model/tasks were evaluated, or how much evidence is enough. ADR-025 is a stronger architectural boundary: evaluation stays outside production dependencies and safety is a hard gate. That boundary does not establish that Tamoz is effective.

**Required repair:** link the existing benchmark protocol and distinguish deterministic plumbing tests from real-provider behavior results. State model/configuration, dataset/holdout lineage, baseline, repetitions, uncertainty, and stop criteria for any effectiveness claim. Put changing numerical targets in the evaluation protocol, not duplicated ADR prose. Record the “real model for real runs; fakes stay in tests” rule in the owning evaluation decision, if it is intended as a permanent architectural evidence boundary.

Affected records: 023–028, 034, 051–052. No real model was called during this review; the test results are plumbing evidence only.

## D7 — P2: Memory and healing records bundle multiple decisions

ADR-026 binds three named memory layers, record provenance, promotion, and evaluated behavior activation. ADR-027 binds authorization-before-ranking, injection policy, contradiction preservation, and deletion propagation. ADR-028 binds a failure model, reviewed remediation, staged rule promotion, compensation, and a durable circuit.

These are related, but they change for different reasons. A reader cannot easily see which rules are foundational and which are implementation choices. “Three layers” is less important than the authority transition between evidence, curated knowledge, and active behavior.

**Required repair:** keep stable identifiers and describe the distinct rules explicitly. Link lifecycle details to the owning design. Compare a unified typed store with separate authorization and promotion rules against physically separate layers. Give healing a complete triggering-failure → rule/preconditions → attempt → verified outcome → compensation/containment example. Split a record only if the constituent decisions need independent supersession; do not manufacture more ADRs just to shorten paragraphs.

## D8 — P2: Rejection ledgers include documentation maintenance as an architectural alternative

ADR-051 rejects “leave the removal implicit,” and ADR-054 rejects leaving ADR-030 stale. Those explain why a record was written; they are not alternative architectures. ADR-052's “untestable monolith” argument similarly assumes the rejected design has no enforceable internal boundaries.

**Required repair:** retain historical context briefly, but use alternatives to compare executable designs under the same requirements. For model transport, compare exact native projection with an SDK behind a Tamoz-owned projection. Explain which SDK behavior prevented the required fidelity, using local evidence or a clearly bounded historical rationale. A documentation hygiene row must not count toward architectural option analysis.

## Positive decisions to preserve

| Cluster | Useful rule | Improve the argument without discarding the rule |
|---|---|---|
| 005–007, 018 | Worker-scoped interrupt; immutable normalized state; ordering separate from opaque identity | Cite behavior tests; retain concise records |
| 015–017, 019–021 | Barrier commits, honest ambiguity, fences, checked resume, scoped execution identity | Define crash windows, fencing coverage, durability assumptions, and reconciliation authority |
| 022–023, 027–028, 030, 032, 034 | Authority never comes from model text, retrieved content, delay, or self-promotion | Map gates and evidence across actual execution surfaces |
| 038–039, 055 | Cognition proposes; independently governed control disposes | Bound process compromise and external verification claims |
| 045–047, 050 | Telemetry observes and does not acquire action authority | Separate no sampling from loss, rotation, reconstruction, and proposed automation |
| 048, 051, 053–054 | One model projection; policy as data; reuse MCP for websearch | State ongoing ownership costs and exact enforcement evidence |

## Exit criterion for this lens

A repaired ADR must let a maintainer answer: what forced the choice, what credible alternative lost, why the chosen seam is necessary, what cost was accepted, what evidence supports the benefit, and what new observation would reopen the decision. A completed template alone does not satisfy that criterion.
