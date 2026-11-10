# Acting under an uncertain cause — future plan

Status: future plan, not scheduled (owner, 2026-11-10). Written under the owner rule "defer complexity to a future
plan"; nothing here is built.
Origin: live conveyor runs in a caller (agentic-stream with streams-simulator, GLM 5.3 Flash, 2026-11-09/10).

## 1. Problem

When the evidence points at a family of causes but not at one cause, Tamoz answers `unknown` and recommends only a
watch. A caller whose right move is the same whatever the cause (reduce load, make safe) gets no step. In the live
runs the model did this on 3 of 3 rows; the caller had to work around it:

- a symptom-level code in its own catalog (a broader code that the cause codes refine), so a step has a diagnosis;
- its own loop to wake the model when a watch fires and to retry a failed episode.

The behaviour is designed in, not a model quirk:

- the frame says "If the evidence still cannot settle it, put most probability on unknown"
  (`episode_frame_builder.rb` ~34);
- the selected code is the argmax of the model's distribution (`ReasoningDocument#select_argmax`), so 0.45 / 0.35
  split between two causes selects neither when `unknown` holds more;
- under `unknown`, `refuse_action_without_diagnosis!` allows only a watch or an R0 intent;
- a catalog entry carries only `code` and `description` (`diagnosis_catalog/unknown_entry_key` refuses anything
  else), so a caller cannot say that two codes share a parent.

The `unknown` rule is a good safety rule and stays. The gap is that Tamoz has no level between "one cause" and "no
idea".

## 2. Plan, in order (each step measured before the next)

1. **Measure first.** An "act under uncertainty" case family in Tamoz's own evaluation domains
   (`test/fixtures/domains/`, never a caller's): cases where a cause-independent step is right, cases where it is
   wrong (a transient, a look-alike), and cases where the cause is clear. Score: step taken when right, withheld when
   wrong, cause named when clear. Controls as in the rule-proposal scorecard (oracle, always-act, never-act). Run it
   against the real model by the documented operator run; record the baseline. This also answers whether a stronger
   model than GLM 5.3 Flash changes the picture.
2. **Hierarchical diagnosis.** A catalog entry may carry `refines: <code>` (data from the caller, one level, no
   cycles, the parent must exist). Selection: if no leaf clears the selection rule but a parent's summed probability
   does, select the parent. A step under a parent is allowed like any named code; `unknown` keeps its rule. The frame
   lists the hierarchy. Catalog digests change only for catalogs that use the field.
3. **Expected step per phase.** The caller may mark an allowed intent as `expected` for the episode (cause-independent).
   The frame presents it as the default; the model confirms it or vetoes it with a reason and evidence. Validation is
   unchanged (risk ceiling, allowed types, approval policy).
4. **Watches from the model's own gaps.** `evidence_gaps` already says what would settle the cause. Return it in a
   shape a caller can turn into a watch condition (feature, comparison, threshold), so the wake-up is the model's
   question rather than a fixed preset. Tamoz does not install it; the caller does.

Each of 2-4 is kept only if step 1's score improves on its cases without losing on the "withhold" cases.

## 3. Bar (per step)

- Generic only: no caller domain in Tamoz code, fixtures or tests (AGENTS.md, ADR-058).
- The `unknown` rule and every refusal stay; a change never lets an R1+ step through without a named code.
- Tests at the layer they prove; the eval's controls discriminate offline before any real-model run.
- ADR: steps 2 and 3 change decided rules (catalog shape, selection), so each updates its ADR in the same change.
- Digests: catalogs and prompts that do not use a new field keep their pinned digests.

## 4. Open decisions

- The selection rule for a parent (summed probability above what threshold; tie order).
- Whether `expected` (step 3) is still needed once step 2 exists.
- Whether `evidence_gaps` needs a stricter shape (step 4) or a caller can map today's text.

## 5. Out of scope

Retrying, waking and phase logic stay with the caller. Tamoz decides one episode; when to ask again is the caller's
loop (agentic-stream already does it).
