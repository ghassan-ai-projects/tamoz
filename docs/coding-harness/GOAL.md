# Goal — coding harness

Set 2026-09-23 by the owner: "start the impl and finish it all, set up a goal and quality
bar that the harness should meet, loop until it is done." Branch: `coding-harness`.

## The goal

Tamoz can take a multi-file coding task from the CLI (`tamoz code`) or from chat, work
on it in a durable, approval-gated, tool-calling loop whose context is managed the DSH
way, and finish it with a verified, honest report. An eval shows this with a real model.

Done means every row of [QUALITY_BAR.md](QUALITY_BAR.md) is met or recorded as an
owner-visible finding with evidence.

## Phase 2 goal — file context (set 2026-09-23, second owner directive)

> "Update the plan and start implementing it. Set up a high quality bar and end goal. Use two
> subagents as reviewers and loop until it is fully done, commit on each round. Prepare an eval
> and testing plan so we can run it with a real LLM after finishing."

Phase 2 completes [FILE-CONTEXT.md](FILE-CONTEXT.md) **FC1–FC9**. **End state:** a work
turn keeps a current, verifiable picture of every file it has read — before it edits, after
anything else changes the file, and after a check rewrites it — without ever rewriting a message
that is already in the cached prefix; the route runs at the model's real, recorded window;
repeated reads do not re-pay; and a turn can report and undo its net change.

Why this is the end state and not more: §0.2–§0.3 of FILE-CONTEXT.md measured what DSH does
(append only; the window is the mechanism; the machinery fires only above 0.8 × window) and what
the owner's sessions show (a 1M window, zero compactions in 7,236 steps). The phase closes the two
gaps DSH leaves open — a stale read stays stale, and a repeated read is paid in full — and stops
there.

**Two packages were dropped after review, under AGENTS.md "do not cover rare cases":**

| Dropped | Why |
|---|---|
| FC11 (series-boundary `system_update` normalization) | The measurement that justified it found **0** occurrences in the corpus, and the session-log spec shows no accumulation path in the current loop. There is no construction that reaches it. |
| FC10 (runtime snapshot on change) | Every component of that snapshot is **turn-constant**: `Header.runtime_snapshot` renders root, date, the *total* budgets and the window; branch is never passed. The snapshot therefore cannot change mid-turn, so the append-on-change half is dead code — while rendering *remaining* budget would append on every step, which is worse. The renderer already exists and is called once per turn; if the harness later tracks branch or dirty state, it is called again then. |

If either becomes reachable later, it returns as a fresh measured finding, not as pre-emptive code.

FC9 (real-model runs) is **prepared, not run**: the DeepSeek account has no balance. Its plan is
§8.3 of [EVAL.md](EVAL.md) and `rake agenteval:harness:all`.

## Owner decisions

The owner started implementation without overriding the plan's recommendations, so
they stand as decided (2026-09-23):

| # | Decision |
|---|---|
| D1 | Native tool calls (OpenAI-compatible `tools`). |
| D2 | A living plan with a declared scope, reviewed once by the existing semantic reviewer; leaving the scope is a plan revision. |
| D3 | No arbitrary shell: configured checks plus a read-only argv allowlist from profile data. |
| D4 | Project `AGENTS.md` goes into the body as attributed, untrusted guidance; opt-in. |
| D5 | Gems `tamoz-context-engine` and `tamoz-harness`. |
| D6 | DSH compaction defaults, one compaction per turn, then hand off. |
| F1 | `@path:120-180` line ranges are allowed in references (still a pointer, no content). |
| F2 | Referenced files are never inlined eagerly; the model reads what it needs. |
| F3 | Rewind is built, operator-only (`tamoz rewind`, `/rewind`); no model-callable revert. |
| F4 | Read defaults: 800 lines, 50 KiB, per route in the context policy. |
| F5 | No shadow-git repository; the change ledger uses the existing `ArtifactStore`. |
| F6 | Spill budget raised to DSH's deployed 50,000 bytes. |
| F7 | ~~Build the runtime snapshot (FC10) and series-boundary normalization (FC11).~~ **Both dropped after measuring them** — see the dropped-package table above. |
| F8 | Guidance files get DSH's change/removal notice; nested scope discovery stays off. |

## Loop

**One authoritative round table.** STATUS.md mirrors it; if they ever disagree, this one governs.

| Round | Packages | Adds a graph channel? | F rows it must move to met |
|---|---|---|---|
| R1 | FC1 (window, pinned as data) · restore A3/A4 (the packaging list is missing both phase-1 gems — `test/packaging_test.rb` is red today) | no | F1; A3, A4 |
| R2 | FC2 (contextual edit diff, read byte cap, stable error codes) | no | F2, F7 |
| R3 | FC3 (observation ledger, gate pinning, read window, dedup, outside-change notice) | yes | F3, F4, F5, F6, F17 |
| R4 | FC7 (superseded-read prune) — **after** FC3, which produces its input | no | F12 |
| R5 | FC5 (change ledger + diffstat) · FC4 (references, guidance digests + notice) | yes | F9, F10 |
| R6 | FC6 (operator rewind) | yes | F11 |
| R7 | FC8 (offline eval: scripted work-loop tests, genuine controls, the positive loop-level cell, and the scenario→trace join key) | no | F14 |
| R8 | FC9 (wire the `ctx-window`, `ctx-dedup`, `ctx-fresh`, `ctx-mention` and `ctx-positive` arms; prepared, not run) | no | F15 |

FC11 is dropped (§ above). Every round that adds a state channel **bumps `WORK_GRAPH_VERSION`**;
each round's sessions are written and read at one version only, and no session crosses a round —
the repo carries no compatibility code for old graph versions.

**Sequencing note (recorded, per review).** `docs/active-investigation/` WP4 is *plan, not built*
and also edits the session graph. Phase 2 runs first; WP4 rebases onto the phase-2 graph when it
starts. No round waits on it.

Every round, without exception:

1. `git status` clean at the start; note the enola baseline.
2. **Red first.** Write the round's tests and show them **failing at the round's parent commit**
   before the implementation lands. That failing run is the repro; a test that has never been red
   is not evidence (`.agent/rules/evaluation.md`). Record the parent sha and the failure output in
   STATUS.md.
3. Implement the package's deliverables.
4. Run the round's tests, then the gates below.
5. **Two independent reviewer subagents**, briefed separately and adversarially — one on
   correctness/durability, one on the quality bar/quality program and the repo's standing rules.
   They review the **committed diff range** of the round (or the staged set for R0), plus the
   round's accepted deviations. Findings are addressed or explicitly recorded; a round does not
   commit with an unaddressed blocking finding.
6. Commit with a message naming the package, the F rows it moves to met, and what it licenses.
7. Update STATUS.md in the same commit, including the F-row column above.

**The gate, exactly (environment substitution recorded).** `rake ci` aborts at
`stream:proto:check` on this host for an environmental reason (below), and `rake ci` skips the
serial suites that carry A2/A3. Every round therefore runs, and reports:

```bash
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
rake design:validate adr:validate syntax test_fast quality:architecture   # ci minus stream:proto:check
ruby -Itest test/packaging_test.rb                 # A3 — in SERIAL_TESTS, skipped by ci
ruby -Itest test/dependency_isolation_test.rb      # A2/F16 — likewise
bundle exec rubocop --cache-root .rubocop-cache <changed files>   # no NEW offense
```

`rake ci_full` is the same set plus the remaining serial suites; it is run **once, in R7**, for
the durability-heavy rounds' benefit, minus the same broken prerequisite.

**`--cache-root` is load-bearing.** RuboCop's default result cache lives under `~/.cache`, which
this sandbox refuses to write; it then aborts *after inspecting zero files* and still prints
"0 files inspected, no offenses detected". Without the flag the lint gate is a false green — found
by running it, not by reading it. A round must see a non-zero "N files inspected" for its files.

**Why the substitution is legitimate, and what it costs.** `stream:proto:check` invokes
`grpc-tools` 1.83.0's vendored protoc, which ships only `x86_64-macos` / `x86_64-linux` binaries;
this host is `arm64`, so the exec dies with `Errno::EBADARCH` before any comparison runs. No phase-2
change touches `tamoz-stream` or the proto contract, and the check cannot be repaired from inside
this repository. It is recorded as a **known-red prerequisite** in STATUS.md rather than silently
skipped; if the toolchain gains an arm64 binary, the full `rake ci` is the gate again.

Phase 1 (WP0–WP9) ran the same round loop; its record is unchanged in STATUS.md.
