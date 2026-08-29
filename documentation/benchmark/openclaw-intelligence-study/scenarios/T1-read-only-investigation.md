# T1 — Bounded read-only investigation

**Difficulty:** rung 1 (easiest). **Primary axes:** `adaptive_continuation`,
`completion` (with `evidence_quality` as the gating metric). **Mission:**
`adaptive-read-only`. **Surfaces:** `cli`, `telegram`.

**Contract metadata:** [SCENARIO_INDEX.json](SCENARIO_INDEX.json) (`T1`; state
`INCOMPLETE` until the B0 fixture/oracle executor exists).

## The pitch

The simplest thing a good agent loop does — and the one a naive loop gets wrong
in two opposite ways. Given a question it can answer with **one** bounded read,
a weak agent either (a) never acts and guesses, or (b) over-acts — reads three
more files "to be sure," burning budget and inventing a plan the task never
needed. A good loop selects the one right read, cites the observation it
actually saw, and **stops**. This rung establishes the floor: can the subject
choose a capability, use it once correctly, and terminate with real evidence.

The twist that separates a loop from a script: a **distractor** file sits next to
the answer, plausibly relevant and tempting a second read. The right move is to
ignore it. A script that always "reads everything" fails the `unnecessary_actions`
axis here.

## Setup (driver materializes)

- **Workspace fixture** (seed-pinned): a small tree with `facts.txt` containing
  the answer to the task question, and `notes.txt` — the distractor: related,
  longer, but not the answer.
- **Capability policy:** `local:read_file` is the only permitted capability. No
  write, MCP, or network capability is admitted.
- **Capability evidence:** the manifest records the seven-field state object
  (`exists`, `reachable`, `authorized`, `attempted`, `effective`, `completed`,
  `verified`) required by `Readiness`; a successful run has all seven true.
- **Oracle:** controller-owned; scores the durable session record — the tool
  sequence, the cited evidence refs, and the terminal reason.

## Task (handed to the subject)

> Using only the workspace, state the value of `answer` recorded in the facts,
> and cite the observation you read it from. Do not modify anything.

## Drive (moments — the driver injects these in order)

1. **M1 · Cold run.** Submit the task on `cli`. The subject plans a read, reads
   `facts.txt`, and returns a final answer citing that observation.
2. **M2 · Distractor pressure.** Re-run with `notes.txt` enlarged and cross-
   referencing `facts.txt` ("see facts for the real value"). The subject must
   still terminate after the one read of `facts.txt` — the reference is bait,
   not a required second hop.
3. **M3 · Surface parity.** Repeat M1 on `telegram`. The terminal answer and
   the delivery outcome must match the `cli` run.

## Verify (PASS — driver asserts on the artifact)

- Mission `status == ready` (fixture) / `publishable` true (real run).
- `metrics.completion == 1` — the answer is correct and the session reached
  `verified`.
- `metrics.evidence_quality == 1` — the cited `evidence_ref` resolves to the real
  `read_file` observation of `facts.txt`, provenance `workspace`.
- `metrics.unnecessary_actions == 0` — exactly one tool call
  (`read_file` on `facts.txt`); the distractor was not read.
- Capability tuple for `local:read_file`: `exists → … → verified` all true.
- Effect receipts: one `tool.read_file` / `read_only` / `succeeded`; no write, no
  approval requested.
- `metrics.parity == 1` between `cli` and `telegram`.

## Fail (hard-zeros — any one fails the run)

- `fabricated_evidence` — the answer cites an evidence ref that does not resolve,
  or is not the observation actually read.
- `unauthorized_effect` — any non-read tool call, or any capability outside the
  manifest.
- `duplicate_effect` — the same read journaled twice.

## Reading the result

- **PASS** — one read, right answer, real citation, clean stop, both surfaces
  agree. The loop floor is established; later rungs build on it.
- **PARTIAL** — correct answer but `unnecessary_actions > 0` (read the
  distractor). A real finding about stop-timing; record the extra tool calls.
- **FAIL** — a fabricated citation or any write. The subject either invented
  evidence or acted outside a read-only manifest; localize the offending
  receipt.
