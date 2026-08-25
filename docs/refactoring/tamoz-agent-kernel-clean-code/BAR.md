# Tamoz agent kernel clean-code refactoring bar

## Scope

- Repository: `/private/tmp/tamoz-agent-kernel-clean-code-20260825`
- Branch: `codex/refactor-tamoz-agent-kernel-20260825`
- Baseline: `1d728e6141698dab0b9ee8519e777e2513cbc058`
- Entry points assessed: `Tamoz::Agent::EpisodeNodes`, `Tamoz::Agent::Deliberation`,
  `Tamoz::Agent::EffectDispatcher`, and every Ruby file loaded by
  `gems/tamoz-agent-kernel/lib/tamoz/agent_kernel.rb`.
- Owned production paths: `gems/tamoz-agent-kernel/lib/**/*.rb`.
- Owned documentation path: `docs/refactoring/tamoz-agent-kernel-clean-code/`.
- Read-only dependencies: `test/**/*.rb`, `gems/tamoz-core/**`, `gems/tamoz-tools/**`,
  other gems, `bin/**`, and `apps/**`.
- Forbidden changes: public constants, public method names/signatures, wire keys,
  serialized shapes, error classes/messages, ordering, journal/effect semantics,
  model/tool dispatch boundaries, test files, unrelated documentation, and generated
  artifacts outside the owned documentation path.

## Behavior contract

- This is a behavior-preserving refactor. No behavior change is authorized silently.
- Preserve return values and object shapes, including all projected hashes and receipts.
- Preserve exception classes, messages, and the point at which they are raised.
- Preserve ordering, fallback paths, exactly-once journal behavior, retry/reconciliation
  boundaries, budgets, digests, logical keys, and context/block forwarding.
- Preserve catalog validation, digest verification, evidence grounding, tool allowlists,
  and model/tool effect journaling.
- If a cleaner design requires behavior to change, record the concrete proposal and
  evidence in `docs/refactoring/tamoz-agent-kernel-clean-code/BEHAVIOR-CHANGES.md`; do
  not apply it without explicit approval.

## Required reading path

- `EpisodeNodes` public node methods should read as episode workflow steps: load trusted
  inputs, perform the domain decision, journal external work only at the existing seam,
  and return the next graph state. Parsing, projection, catalog validation, and digest
  mechanics belong one level below the node story.
- `Deliberation` public prompt/validation methods should read as protocol intent first;
  string assembly, canonicalization, and field-level checks belong in named helpers.
- `EffectDispatcher.run` should read as prepare → resolve identity → reuse/reconcile or
  execute → return the recorded outcome. Attempt bookkeeping and error serialization
  belong below that story.
- Smaller files should be changed only where a function mixes abstraction levels or has
  an intent-free name; otherwise record that the file was assessed and leave it stable.

## Must-pass criteria

- [ ] B1 Scope: only owned production/docs paths changed; forbidden interfaces and tests
      are untouched.
- [ ] B2 File assessment: every gem file has a candidate decision recorded in `TODO.md`;
      changed files name the reading-order defect there and unchanged files have a reason.
- [ ] B3 Story: each changed public/top-level function states its workflow in domain
      order without lower-level parsing, collection, serialization, or byte mechanics.
- [ ] B4 Abstraction: each changed function stays at one coherent level and calls named
      operations one level below it.
- [ ] B5 Names: every extracted or renamed function states intent or a domain concept;
      no `process_*`, `handle_*`, `do_*`, or wrapper-only helpers are introduced.
- [ ] B6 Restraint: no duplicated capability, speculative handling, compatibility shim,
      narrative comment, or unrelated cleanup is introduced.
- [ ] B7 Preservation: the final focused and required repository checks pass, and the
      diff plus tests provide evidence for the listed behavior contract.
- [ ] B8 Architecture: the post-change Enola snapshot is comparable to the pinned
      baseline and introduces no unexpected cycle, layer violation, coupling, or spillover.
- [ ] B9 Hygiene: created files are mode `0644`; no scratch files or unrelated changes
      remain; the final commit contains only this task.
- [ ] B10 Review: the independent read-only reviewer returns `PASS` against this exact
       bar after all corrections.

## Deferred gates

No tests, lint, or repository quality gates are run during candidate discovery or
implementation. At the end, the orchestrator runs the relevant focused suites and the
repository gates, records any pre-existing known-red result, then runs the Enola
post-change snapshot/diff.

## Candidate and review protocol

- One implementation agent may inspect every owned file, propose candidates, edit only
  owned paths, and report its file-by-file decisions.
- Independent reviewers are read-only and check the actual diff and final evidence. Per-file
  notes are deliberately not retained; agent reports and the commit history are the evidence.
- The reviewer returns `PASS`, `FAIL`, or `BLOCKED` with a B1–B10 matrix. A failed item
  returns to the same implementation agent for correction; the bar cannot be lowered.
- The orchestrator owns commits, final gates, and any behavior-change report.
