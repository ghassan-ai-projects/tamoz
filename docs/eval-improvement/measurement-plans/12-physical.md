# Physical loop — measurement plan

Two layers, kept separate. tamoz is the brain (recommendation); the dispatcher (Go) actuates.

## 12a. Recommendation competence & fitness (brain — no hardware)
**Now:** property spec — evidence-fitness family is a pending gap (0/8: unusable quality,
stale-by-age, out-of-range all yield an R2 recommendation); brain/hardware boundary is a green
guarantee; risk-ceiling demotion is a guarantee. Fixture-driven.
**Unknown:** with a real model, does the brain recommend the right typed intent across real sensor
situations (this is [06 Decision](06-decision.md)'s thermal tournament).
**Owner decision (O1):** add a recommendation-time evidence-fitness gate (defence in depth) so the
brain won't propose actuation on unfit evidence, or accept the gap. Closing it flips the pending
evals to real passes.
**Done:** the tournament's real-model result (06) + O1 resolved.

## 12b. Dispatch-time physical safety & actuation claim (needs hardware)
**Now:** unexercised by any tamoz eval — the dispatch gate lives in the Go authority; the
`m0/11-physical-evidence-gate` is a declarative contract case, not a live gate. Verdict
`inconclusive`; `physical_claims_allowed` false.
**Unknown:** does the *system* fail closed on weak/stale/contradictory evidence before actuating,
observed by an **independent instrument** (not the device's own ack).
**Measure (hardware):** one immutable bench run with the `arduino-bench-v1` manifest gates p0–p8
filled from measured values, independent-instrument feedback; `physical_claims_allowed` flips only
on that evidence. This tests the dispatcher, not the brain.
**Done:** a bench artifact that licenses the actuation claim — or an explicit recorded refusal.
