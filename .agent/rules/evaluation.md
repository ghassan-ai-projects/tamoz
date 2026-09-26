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
- **Grade the owner's install, not a clean room.** The Telegram eval passed 82/82 on a fresh
  runtime with hand-started gateway and worker; the owner's phone got "something went wrong" to
  every message. Their `~/.tamoz` had conversations bound to an older profile (re-running `setup`
  rewrote it) and an MCP server that was offline — neither exists in a fresh directory. Run the
  documented command itself (`tamoz telegram start`, not its children) and run it on a copy of the
  real runtime (`script/telegram_chat_eval --runtime-from ~/.tamoz`); a copy also carries state a
  stand-in must honour, such as Telegram's real update offset.
- **Exercise non-ASCII and length together, over many turns.** Two limits were enforced in bytes
  but sized in characters (history lines, reply parts); every ASCII scenario passed, and the
  owner's bot died after a few long replies containing a dash and emoji. A soak that runs a long
  conversation with multi-byte replies (`long_conversation`) found both in one run.
- **Ground a success in what the evidence said, not in the fact that something was cited.** The first
  active-investigation grader counted "correct cause + cites a non-error tool result" as success; a blind
  prober (useless filter, guessed cause, cited the empty reply) scored 0% fabrication, and the oracle still
  passed with a server that returned nothing. Give each cell a decisive-evidence marker as data and require a
  cited result that contains it; mutate the server to return nothing and watch the oracle fail.
- **Repeats of one input are not samples.** At temperature 0, "2 repeats x 4 seeds" of 6 cells is 6 samples,
  not 48; a Wilson interval over 48 overstates certainty about eightfold. Make seeds change the input, and put
  the headline over distinct cells.
- **Tell the model every rule the grader applies to its answer.** The investigation grader scores the alarm code
  (`low_dissolved_oxygen`) as "no answer", but the corpus prompt only said "most probable cause"; in the first
  real run that bucket was 72 of 232 episodes, the largest failure. A rule the prompt never states measures the
  prompt, not the model. Fixing it after a run makes the next run a development-set number — say so.
- **A read-count check counts only calls that could reach the server.** "Reads = dispatched calls" failed in a
  real run (475 for 477) because calls refused for bad arguments are dispatched but never read. Record each
  call's error code in the report, so a mismatch names its cause instead of leaving a guess.
