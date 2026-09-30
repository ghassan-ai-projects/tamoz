# Round 2 — Repair order and acceptance bar

Date: 2026-09-29. Status: proposed documentation repair program; the review itself is complete.
Scope: current ADR corpus, governance documents, and existing ADR tooling. No runtime redesign is authorized by this plan.

## Target outcome

A maintainer can determine the current rule, authority owner, credible alternatives, accepted costs, failure behavior, and exact evidence without reconciling contradictory pages. A record of accepted intent must not be silently rewritten to approve whatever the code currently does.

The job is not to make every ADR longer. Preserve narrow decisions; link detailed designs; write missing analysis only where it changes the reader's ability to assess the decision.

## Why the defects recur — five whys

1. **Why do current ADRs mislead?** Claims survived after policy, API, ownership, and telemetry behavior changed: 008/010/033/034/036/043/049 are direct examples; 047 overstates loss protection.
2. **Why did the record not change with the implementation?** Changes updated a status or a design while dependent claims remained in abstracts, consequences, rejection tables, and other ADRs. The 049 amendment and 040/055 edge make that visible.
3. **Why did verification not catch it?** Automated checks resolve a subset of paths and section names. The prose consistency test samples status and an invariant phrase, not the zero-risk claim.
4. **Why was green interpreted as sufficient?** LIFECYCLE explicitly equates green checks with meeting a broader semantic bar; verification citations do not carry proof scope.
5. **Why is future decision quality still weak even after fixing drift?** The rubric rewards a rejected row and applicable headings, but does not require comparing credible executable alternatives, separating assumptions from measurements, or bounding ownership/operational costs.

Steps 1–4 are grounded in inspected text/code and executed checks. Step 5 is the reviewer's causal interpretation. It should be challenged during the repair review, rather than promoted to a proven historical explanation.

## Wave 1 — Correct materially false or ambiguous current claims

| Change group | Records | Concrete completion condition |
|---|---|---|
| Chat approval | 043/049/053; quality-bar reference claims; comms design/guide consumers | Every current-policy statement agrees with global chat_bound default and profile overrides; original deny-only posture is labeled historical; current blast radius and unresolved change-bar analysis are stated |
| Observability guarantee | 045/047/050 and traceability | Sampling, drops, retention, reconstruction, and proposed automation are distinct; no loss-free claim remains without evidence; clause 62 stays proposed |
| Composition and pools | 004/008 | Canonical API existence/intent is resolved; only inline/threads are described as supported; no invented seq API or fiber implementation is added |
| Version support | 010 | Current pinned CI and accepted support intent are distinguished; any change to the supported-version decision is explicitly ratified |
| Skills and streaming owners | 033/034/036/052/055 | Compiler, kernel recipe, promotion, snapshot consumption and external admission are correctly attributed; host isolation does not deny runner model journals |
| ADR navigation | 029/035/037/040/048/054 and index/derived views | Actual amendment/replacement edges agree; resolved audit notes are removed or marked historical; current-tense stale claims are corrected |

**Guard:** owner-authorized current policy is evidence of intent, not an error to revert by default. Preserve the exact-plan, evidence-binding, effect, and external-control invariants. No cross-gem interface change is needed to correct documentation.

**Evidence:** use existing behavior tests, including the tests run in this round. Add a new discriminating test only where a real contract is uncovered. Do not alter a test to pin a misleading paragraph. Review all consumers of the changed rule, not just its originating file.

## Wave 2 — Make the acceptance process honest and reproducible

Use the existing `ADR_QUALITY_BAR.md`, `_TEMPLATE.md`, `LIFECYCLE.md`, README, and scripts.

1. Agree on canonical state, revision history, and relation semantics. Keep generic dependencies directional; make replacement/amendment relationships explicit and reciprocal.
2. Narrow automated-green claims to actual check coverage. Add a required semantic review result before accepted-quality sign-off.
3. Repair duplicate-number detection before hash indexing; support the documented retirement/state choices or simplify the documented choices coherently.
4. Enforce objective tier-applicable metadata/structure with fixture tests. No regex claiming to prove a safety guarantee.
5. Run the bounded ADR/document gate for documentation-only changes. Keep lane budgets and avoid adding the full runtime suite to every prose edit.

**Completion condition:** a minimal valid record, missing applicable section, duplicate identity, revised record, retirement without successor, dead anchor, stale catalog, and contradictory verification-scope claim each have an explicit expected outcome. Mechanical fixtures exercise mechanical rules; semantic contradictions remain reviewer obligations.

## Wave 3 — Repair load-bearing arguments and proof scope

Start with 015/016/017/019/020/021/022/023/027/030/032/034/038/039/042/046/048/049/053/055.

For each contract:

- Define the enforcing owner and caller surfaces.
- State the adversary/failure assumptions, credible failure, refusal, and residual harm.
- Link inspected negative-scenario tests with their scope and date/revision.
- Distinguish intended guarantee, observed implementation, and unresolved evidence.
- Define a reopening trigger that tests whether the original forces still hold; do not write a circular bar that merely requires the existing decision again.

**Completion condition:** no load-bearing “impossible,” “every,” “zero risk,” “never lost,” or “verified” claim exceeds its stated assumptions and evidence. Existing tests can cover the invariant; a new test is needed only where the invariant has no meaningful discriminator.

## Wave 4 — Challenge structural choices and product cost

Reassess 013/014/022/024/025/026/028/040/041/044/048/051/052/054/055 through D2–D8.

Compare credible simpler alternatives under the same safety requirements. Separate package/module/process/repository/language decisions. Record the measurement behind performance or simplicity benefits, or label those benefits as unmeasured expectations. Make operator friction, one-step overhead, release coordination, adapter onboarding, and recovery effort explicit costs.

**Completion condition:** every challenged choice has a fair option comparison and a falsifiable reopening trigger. A decision may remain unchanged after analysis. Do not merge gems, move repositories, add provider transports, or open adapter registration without a separately accepted decision and interface approval where applicable.

## Wave 5 — Close missing decisions and editorial debt

- Record user-stop versus executor-abort semantics through the existing cancellation seam. Allocate the next free number at authoring time; 056 is only a candidate today.
- Record data-authored domain knowledge and pinned evidence/parity obligations under the appropriate evaluation/design decision. Do not promise zero domain literals before auditing the loader violation noted in the evidence report. 057 is not reserved by this plan.
- Extend effect/evaluation/facade decisions for terminal receipt immutability, request-key dedup, real-model evidence honesty, and facade-only ownership where appropriate.
- Remove repetitive release boilerplate, unopenable fan-in snapshot counts, duplicate links, orphaned implementation checklists, and formatting-only inconsistencies.
- Do not invent original dates, rejected alternatives, or acceptance history. Label retrospective analysis with its actual review date.

**Completion condition:** no shipped architecturally significant rule remains only in an agent instruction file; simple records remain concise; each number has one canonical home; generated outputs are current.

## Delivery and verification

Keep independent root causes in focused changes. Preserve unrelated working-tree changes. After canonical edits, regenerate through existing scripts; never hand-edit generated catalog/graph/traceability files. Inspect generator consumers before moving/removing documentation.

For documentation changes, run ADR catalog/validate/verify, relevant design/documentation checks, and a local link/coverage check. For tooling/workflow changes, read the coding standard, map the existing seam with Enola, set a baseline, add meaningful isolated fixture tests, and run the applicable everyday/expanded gates. Check architectural delta after a structural change. This review did not perform those implementation gates.

A final repair report must name each resolved finding, unchanged accepted choice, unresolved decision, executed test/gate, and evidence limitation. Do not mark the corpus accepted-quality merely because every file has the expected headings.
