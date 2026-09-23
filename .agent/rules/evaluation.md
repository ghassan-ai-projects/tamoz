# Evaluation — grade the decision, not the narration

Learned building the `agenteval` framework (docs/eval-improvement/). These apply to any
harness that scores an agent.

- **Never grade the agent's wording.** A pass/fail rule over the model's prose scored 73% of
  naturally-worded *correct* refusals as failures, while a do-nothing agent that appended one
  keyword beat most of the cells it guarded. If an oracle can decide it, the oracle decides
  it; keep the answer text as diagnostic detail only.
- **A status the runtime produces is not a status the measurement can read.** This agent
  exits non-zero precisely when it declines, so "non-zero means crashed" scored every correct
  refusal as a failure. Read the semantics from the adapter's contract, never from a guess
  about what an exit code usually means.
- **A control that cannot fail is not evidence.** If a control's expected verdict and its
  actual verdict derive from the same predicate, a degenerate agent passes by construction.
  Prove it by swapping in the degenerate strategy and watching the suite object.
- **"N cells, zero disagreements" is a claim about those strategies only.** It did not catch a
  broken grader and it did not catch a reopened defect. Keep a separate, committed repro of
  each fixed defect — it is the only artefact that asserts the old behaviour is gone, and it
  caught a regression the control suite, the validator, and the unit tests all missed.
- **A fix can reintroduce the defect it fixes.** Re-run the repro after every change to the
  scoring path, not just the first time.
- **Prefer an observation to a comparison.** A read-only check built on content digests could
  not see a write that was undone; modification time could. Ask what the agent *did*, not only
  what state it left.
- **A missing number must stay missing.** A cost field the transcript does not carry is
  absent, never zero.
- **Separate "never acted" from "acted and failed."** One `failed` bucket hid that 28 of 28
  failures were a single abort and 8 of the "solves" were the same abort.
- **A scripted loop is not a working loop; run one real task before claiming it.** The work
  loop passed every scripted test, yet its first real `tamoz code` run (a Game of Life, over
  OpenRouter) hit three defects no fake could: a model answer with `—` crashed the work step
  (HTTP bodies are ASCII-8BIT, the JSON parser kept them binary, the state codec refused them), every approval preview
  printed twice, and a 41-call turn hit the graph's 200-step backstop before the loop's own
  60-call budget could hand off. Fakes answer in ASCII, in few steps, without a terminal.
