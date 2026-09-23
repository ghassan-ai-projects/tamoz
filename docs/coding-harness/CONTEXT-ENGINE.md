# The context engine — the DSH method, mapped onto Tamoz

This is the specification for `tamoz-context-engine` and for how the `work` loop uses it.
Each mechanism names what DSH does (with its source), which research method it
implements, what Tamoz builds, what it costs the prompt cache, and which eval
property holds it (the `G-n` ids are in [EVAL.md](EVAL.md) §2).

The organising idea, from the research: **the window is an attention budget, and the
prompt cache is prefix-exact.** So keep everything stable at the front and
byte-identical, only append, move bulk out behind a pointer, and when you must rewrite,
do it once, at a boundary, with a schema, and log it.

---

## 1. The request, by segment

```
┌──────────────────────── frozen header (one request series) ────────────────────────┐
│ system: identity · operating rules · tool rules · editing rules · honesty/finish ·  │
│         surface (cli|chat) · operator persona · user preferences                   │
│ tools:  JSON schemas, sorted by name                                               │
└────────────────────────────────────────────────────────────────────────────────────┘
┌──────────────────────── body (append-only surface log) ────────────────────────────┐
│ user: runtime snapshot   (workspace, branch, date, budgets)          — volatile      │
│ user: project guidance   (AGENTS.md chain, attributed, grants nothing) — opt-in     │
│ user: memory recall      (existing memory engine)                                  │
│ user: the task                                                                      │
│ assistant: update_plan(...)            tool: plan accepted (review id)              │
│ assistant: read_file(...)              tool: numbered lines + sha                   │
│ assistant: apply_patch(...)            tool: unified diff                           │
│ assistant: run_check(test)             tool: "test: FAIL 2/140 …" + spill locator   │
│ …                                                                                   │
│ [checkpoint: <compacted-summary>…]     ← only at a logged replacement               │
│ user: plan re-read                     ← always right after a checkpoint            │
│ user: system_update (e.g. /think high) ← in-history, never a header rewrite         │
└────────────────────────────────────────────────────────────────────────────────────┘
```

Segments 1–2 (header) are the cached prefix. Everything volatile is in the body,
where recency also gives it more weight (research M-1, loss mode "freshness").

---

## 2. Mechanisms

### 2.1 Frozen request header and request series — M-1 prefix stability

- **DSH:** `packages/core/session/src/request-header.ts` (ordered `JSON.stringify`
  equality); `packages/core/system-prompt/src/index.ts:226-234` (sections sorted by
  `order` then a locale-independent name compare; tools lexicographic);
  `packages/core/agent-loop/src/agent.ts:363-369` (three triggers); four logged reasons
  `initial | resume | change | series`. Resume and a model swap alone continue the
  series.
- **Tamoz:** `ContextEngine::RequestHeader` is the canonical JCS of `{sections, tools, route}`.
  JCS already sorts object keys by code point, so ordering is locale-independent by
  construction. Sections are an array sorted by `[order, name.b]`. Tools are an array
  sorted by `name.b`. `ContextEngine::Series#admit(header, declared:)` returns
  `continue` or `start(reason)`; a `series` record lands on the surface log.
- **Triggers:** first request (`initial`), resumed turn (`resume`, series continues
  if bytes are equal), header bytes changed (`change`), declared boundary after a
  compaction or a `/new` (`series`).
- **Forbidden in the header:** timestamps, ids, cwd, branch, memory, plan, project
  guidance, per-turn tool subsets.
- **Cache effect:** the whole header is reusable on every request in the series.
- **Holds it:** G-1 (byte stability across processes and locales), G-2 (append-only).

### 2.2 Append-only surface log — "model-visible means logged"

- **DSH:** `docs/architecture.md` "Session log": `deriveMessages()` projects history
  from the log; a runtime invariant asserts that anything reaching a request is
  reconstructable from it. Compaction and pruning are *surface replacements* that
  shadow a range; the shadowed events stay in the log, so replay is deterministic.
- **Tamoz:** `ContextEngine::Surface` entries are small: kind, text or ref, digests, and for
  replacements `{op: replace, start_seq, end_seq}`. Model responses and tool results
  are already journaled by `EffectDispatcher`; bulk text lives in `ArtifactStore`
  by digest. `derive(header)` is a pure fold. The session keeps the entries in a graph
  append channel (refs only, see PLAN §3.4).
- **Cache effect:** appending never invalidates. A replacement invalidates from its
  first shadowed token; the prefix before it stays reusable.
- **Holds it:** G-2, G-3 (replay rebuilds identical bytes).

### 2.3 In-history prompt updates

- **DSH:** `llm-deepseek` declares `systemPromptUpdate: 'in-history'`; a changed prompt
  is appended after the cached prefix instead of rewriting node 0
  (`docs/architecture.md:109`).
- **Tamoz:** mid-turn changes (`/think`, `/verbose`, a profile preference, a plan scope
  change) become a `system_update` body entry, marked as an operator update. The header
  is re-rendered only at the next series start (a new turn or a `/new`).
- **Cache effect:** none within the series.
- **Holds it:** G-4.

### 2.4 Runtime context as body snapshots

- **DSH:** "Ordered dynamic contexts are separate from sections and become sourced
  user-role snapshots" (`packages/core/system-prompt/README.md`, Model Experience).
- **Tamoz:** the runtime snapshot (workspace root, branch and dirty state, date,
  budgets left), the project guidance and memory recall are sourced `user` entries at
  the start of the body. They are re-sent only when they change, as a new entry.

### 2.5 Output shaping — M-5

- **Research:** the cheapest token is the one never generated; head+tail, never middle;
  pass = one line, fail = full trace; never delete, always redirect.
- **Tamoz:** in `tamoz-tools` (PLAN §3.4): `run_check` shaping, capped and ranged reads,
  glob and grep caps, a diff instead of a re-read after an edit.

### 2.6 Spill — M-6 reversible offload

- **DSH:** `packages/spill/spill-policy`: over `maxInlineBytes`, a head/tail preview, a
  locator and retrieval guidance; "append-only; newly visible content follows the
  reusable request prefix and does not invalidate existing KV-cache entries".
- **Research rule:** the stub must hold enough to make the recall decision
  (`log_a3f9 (14KB)` is useless; `… npm ci, exit 0, 2 peer-dep warnings` is actionable).
- **Tamoz:** `ContextEngine::Spill` over the existing `ArtifactStore#retain`. Stub:
  `[output spilled: artifact:<digest> · 14.2 KB · 612 lines · exit 1 · 2 failures]`,
  plus the first 20 and last 40 lines. `recall_output` reads it back by range or filter.
  Default `max_inline_bytes: 8192`.
- **Holds it:** G-5 (recall is byte-exact), G-6 (stub carries the tool's digest line).

### 2.7 Tool-result pruner

- **DSH:** `compaction-tool-result-pruner`: only once a trigger qualifies; results over
  8,192 characters keep the first 4,096 and the last 1,024 around a marker; no model
  call; the replacement cites the original; may relieve enough pressure to skip the
  summary.
- **Tamoz:** same defaults, with the marker carrying the locator so the model can
  recall the middle. It runs before summarising, oldest results first, and never
  touches the newest retained slice.
- **Cache effect:** invalidates from the first pruned token.
- **Holds it:** G-7 (one-pass convergence, strictly smaller, original recoverable).

### 2.8 Compaction — M-8, with DSH's cache-aware summariser

- **DSH:** `compaction-basic`: pressure at `thresholdRatio 0.8` of the routed window,
  keep the newest `retainRatio 0.16`; the oldest **balanced** span (no unanswered tool
  call crosses the cut) is replaced by one user-role checkpoint; node 0 is never
  shadowed; the summary must shrink its source; a log-recorded
  `compaction/start → summary → end` bracket is the lock; on
  `CONTEXT_WINDOW_EXCEEDED`, one maximal balanced reduction and one retry.
  **The summariser replays the same system prompt, tools and shadowed messages
  byte-for-byte and appends the instruction as the last user message**, so the call is
  a prefix extension of the conversation and can reuse the warm cache.
- **Research additions:** fire at a **semantic boundary** when one is near (a plan step
  closed, a check passed, a hypothesis settled); suppress mid-edit (an approved,
  unverified mutation), right after an error, and while stuck; offload before
  compacting; re-read the plan right after (the first post-compaction step is the most
  error-prone: +0.108 blocked/error actions); **at most one compaction per turn, then
  hand off** (D6).
- **Tamoz:**
  - Trigger: `pressure ≥ threshold` arms compaction. It fires at the next boundary, or
    at the hard backstop `0.92`, whichever comes first.
  - Order: spill (already done at write time) → prune → re-measure → summarise if still
    over.
  - Durability: the summariser call is `SessionEffects#converse(stage: :context_compact)`,
    journaled, `:idempotent` (re-summarising the same span changes nothing durable
    until the checkpoint is appended). The checkpoint append and the `series` record
    are one checkpoint write, so a crash leaves either the old surface or the new one.
  - Validation: `ContextEngine::Compaction.validate!` rejects a summary that is not smaller,
    misses a schema section, or drops an exact string that the shadowed span carried in
    an error line, a path, or a command (extracted deterministically). A rejected summary
    falls back to prune-only, and the trace records the fallback.
  - After the checkpoint: the plan document is appended verbatim.
  - Second pressure event in the same turn: `Harness::Handoff` writes the note, the turn
    ends as `handed_off`, and the next turn opens a new generation from the note and the plan.
- **The summariser instruction** (final user message; DSH's text plus the research
  schema's additions, marked ✚):

```markdown
You are now acting as the compaction step for this coding session. Condense the
conversation ABOVE into a checkpoint that lets the same agent continue with no loss of
essential context.

Output EXACTLY these sections, in order. Terse bullets. Write "(none)" for an empty
section; never drop one.

## Primary Request and Intent
## Plan State            ✚ done (with how verified) / in progress / not started
## Files and Code        exact paths, why they matter, key changes
## Errors and Fixes
## Decisions             ✚ decision — because reason
## Ruled Out             ✚ approach — because reason — evidence (file:line or command)
## Exact Strings         ✚ verbatim errors, paths, commands, versions, identifiers
## Offloaded Artifacts   ✚ artifact locator — one-line description
## Pending Work
## Current Work
## Next Step

Rules:
- Preserve exact file paths, commands, error strings, identifiers and numbers verbatim.
- Mark anything not verified by a tool result as "unverified". Do not turn a hypothesis
  into a fact.
- Capture user instructions and corrections faithfully.
- Do not mention this request. Do not call any tool.
- If a <compacted-summary> block is already present, merge it: keep what is still true,
  drop what is stale.
```

- **Checkpoint preamble** (what the working model sees; DSH's wording):
  "This is an automatically generated checkpoint condensing an earlier span of the
  conversation to free up context. Treat the captured context as established background
  and build on it without restating it. Continue the task directly from the messages
  that follow, without acknowledging this checkpoint."
- **Cache effect:** the summariser call reuses the conversation's warm prefix when it
  runs on the same route (the DSH default; PLAN open point 3). The checkpoint itself
  invalidates from the first shadowed token. The research break-even is roughly four
  later turns, so a compaction near the end of a turn is a pure loss; the trigger does
  not fire if the plan's remaining steps are ≤ 1.
- **Holds it:** G-8 (balanced cut, node 0 safe), G-9 (validate!), G-10 (crash in the
  bracket), G-11 (overflow retry once), and the fidelity corpus in EVAL.md §4.

### 2.9 Living plan — M-7

- **DSH:** `tool-todo` (a whole-list replace; survives reopened sessions).
- **Research:** a rewritten-in-place state document with a **ruled-out** section; re-read
  after every boundary; 30–80 lines; "last updated after which event".
- **Tamoz:** `Harness::PlanDocument` via `update_plan`. It is also the D2 review object.
  It lives in session state, not in the repository. It is appended to the body after a
  checkpoint and at the start of every new generation.

### 2.10 Session lifecycle — M-10

- **Tamoz already has** generations (`/new` → `.gN`). The harness adds the handoff note,
  written from the plan and trace. Reset triggers: the second compaction, the repeat
  guard's stop, the budget, a user `/new`.

### 2.11 Token meter and usage

- **DSH:** `token-meter`: four characters per token plus structural overhead when no
  provider usage is available; prefers reusable provider usage; the pressure policy
  resolves capacity from the routed adapter. `llm-deepseek/src/translate.ts:56-70`:
  `input = prompt_tokens − cache_hit` so the counts are disjoint.
- **Tamoz:** `ContextEngine::TokenMeter` estimates UTF-8 bytes ÷ 4 (CJK and JSON
  underestimate; the calibration fixes most of it) and calibrates per series with the
  last reported `prompt_tokens`: `estimate(new) = reported(prev) + heuristic(appended)`.
  The window comes from the profile role (`context_window`), never a guess.
  `ContextEngine::Usage` reads DeepSeek's `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`
  and OpenAI's `prompt_tokens_details.cached_tokens`.

### 2.12 Repeat guard

- **DSH:** `repeat-tool-reminder`: advisory reminders at 3, 5 and 8 identical calls;
  never blocks; cleared by a new user message.
- **Tamoz:** reminders at 3 and 5 (a body entry: "you called X with the same arguments
  N times; look at the last result and change approach or finish"), a stop at 8 that
  hands off. The existing adaptive loop's hard `adaptive_repeated_action` stop becomes
  this.

### 2.13 Read-before-edit and freshness

- **DSH:** `fs-observation-policy`: a mutation needs a prior read and fails if the file
  changed since, with a re-read instruction. Not persisted across resume.
- **Prompt-cache research:** the disk edit is not a cache event; the rebuild is. Append
  a diff rather than re-reading; a full re-read costs about 1.46 turns and invalidates
  nothing.
- **Tamoz:** `expected_sha256` already enforces it. Add the stable error code and the
  appended diff (PLAN §3.4). Freshness after an external edit is detected at patch time,
  not tracked continuously.

---

## 3. Policy, as data

The defaults ship in `tamoz-context-engine`; a profile role may override them per model route,
as DSH's `modelPolicies` does.

```yaml
context:
  threshold_ratio: 0.8        # arm compaction
  backstop_ratio: 0.92        # compact even mid-step
  retain_ratio: 0.16          # newest slice kept verbatim
  max_compactions_per_turn: 1 # then hand off (D6)
  summary_max_tokens: 8192
  overflow_retries: 1
  spill:
    max_inline_bytes: 8192
    preview_head_lines: 20
    preview_tail_lines: 40
  prune:
    threshold_chars: 8192
    head_chars: 4096
    tail_chars: 1024
  repeat_guard: { remind_at: [3, 5], stop_at: 8 }
  instructions: { enabled: false, max_bytes: 16384, files: [AGENTS.md] }
```

---

## 4. What we deliberately do not copy from DSH

| DSH has | Tamoz does not, because |
|---|---|
| Cordis plugin tree, profiles, bundles | Tamoz composes with gems and trusted profiles already; a plugin framework is machinery with no current need. |
| `/compact` as the only manual path | Tamoz already has `/compact`; it is extended, not replaced. |
| Continuous `AGENTS.md` rediscovery after fs operations | The chain is read once per generation. Tamoz treats it as untrusted guidance, so less is better. |
| Sub-agent providers (Claude Code, Codex, in-process fork) | Out of scope (PLAN §5). |
| Model-facing compaction tool | DSH leaves it undecided; so does this plan. |
