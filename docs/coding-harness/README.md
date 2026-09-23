# Coding harness — give Tamoz the power to implement complex coding tasks

Status: **built; real-model eval pending funding** (see [STATUS.md](STATUS.md)) · Date: 2026-09-23 · Branch: `enable-analysis-abilities`

Today Tamoz can make a reviewed, bounded change: plan, review, one approved patch,
one check, up to two repairs. It cannot carry a long coding task. It has no
multi-turn model conversation, no native tool calls, and no way to keep a long
working session inside the model's window. This plan adds that ability. It uses the
context-management design of DeepSeek Harness (`dsh`), adds a real system prompt
and personalization layer (Tamoz has none), and adds an eval that has to show the
ability works with a real model. The work goes into two new gems. The CLI and chat
both use them.

| Document | What it is |
|---|---|
| [PLAN.md](PLAN.md) | Current state (with file references), the design, the two new gems, the per-surface changes, the gated work packages, risks. |
| [CONTEXT-ENGINE.md](CONTEXT-ENGINE.md) | The DSH context-management method mapped onto Tamoz, mechanism by mechanism: frozen request header, request series, append-only surface, in-history prompt updates, spill, pruner, compaction, token meter, cache accounting. |
| [FILE-CONTEXT.md](FILE-CONTEXT.md) | Next phase (plan): the route's real window first, then files as their own kind of context — read-before-edit observations, notes for outside changes, bounded reads and dedup, the diff tail, `@path` references, a change ledger and rewind. §0.2–§0.3 carry the measurement of what DSH's machinery actually does (753 session logs) and the worked example of five reads with the third one changed. |
| [PROMPTS.md](PROMPTS.md) | The system prompt and personalization layer: section order, trust tiers, draft text, what is data and where it lives. |
| [EVAL.md](EVAL.md) | The eval: offline guarantees, controls that must discriminate, the cache/cost trace, the capability and context-fidelity corpora, the real-model runs, the stop rule. |
| [GOAL.md](GOAL.md), [QUALITY_BAR.md](QUALITY_BAR.md), [STATUS.md](STATUS.md) | The goal, the bar it must meet and where it stands, and the resume point with recorded deviations. |

## Using it

```bash
rbenv exec bundle exec tamoz --root . --allow-changes --check 'test=rbenv exec bundle exec rake test' --guidance AGENTS.md code "Add X"
```

Chat: start the worker/comms runtime with `--work-routing`. Inspect a thread's context and cache use with
`script/context_trace SESSION_DIR [THREAD]`. Real-model eval: `rake agenteval:harness:all`.

Sources this plan is built from:

- The context-management research: `~/ai-projects/articles/research-context-management-coding-agents`
  (the ten methods M-1…M-10, the eval chapter `08`, metrics `11`, the compaction
  policy `05` §5.6).
- Its cache annex: `~/ai-projects/articles/research-prompt-cache-architecture`
  (`dsh/dsh.md`, pinned at dsh `c291e7961a`).
- DSH itself: `~/external-projects/deepseek-harness` (`docs/architecture.md`,
  `packages/core/system-prompt`, `packages/core/agent-loop/src/runtime-context.ts`,
  `packages/core/session/src/surface.ts`, `packages/compaction/*`,
  `packages/spill/spill-policy`, `packages/fs/fs-observation-policy`,
  `packages/context/agent-instructions`, `packages/guard/repeat-tool-reminder`,
  `packages/bundle/base/cordis.patch.yml` for the deployed policy values).
- What DSH's machinery actually did: `script/dsh_context_survey` over `~/.dsh/sessions`
  (the table in [FILE-CONTEXT.md](FILE-CONTEXT.md) §0.2).

## The answer in one paragraph

Most of what this needs already exists in Tamoz, and the plan reuses it: the durable
graph, the effect journal (`EffectDispatcher`), the approval engine and its policy
YAML (`workspace_write` is already `allow` with session grants), the
content-addressed `ArtifactStore`, the sealed capability host, the context
controls (`/new /reset /compact /usage /context /think /verbose`), memory, skills,
and the `agenteval` harness. What is missing is narrower:

1. **A model conversation.** The transport sends one `[system, user]` pair in JSON
   mode ([episode_model_transport.rb:70](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb:70)).
   A coding loop needs a growing message history with native tool calls.
2. **A context engine.** The only context management is a 16 KB JSON frame cap
   (`BoundedCompactor`, [session_planning_context.rb:19](../../gems/tamoz-agent-session/lib/tamoz/agent/session_planning_context.rb:19)).
   A long session needs DSH's discipline: a frozen, byte-stable header; an
   append-only history derived from a durable log; bulk output spilled to disk
   behind a stub; a structured, cache-aware compaction when pressure builds.
   New gem **`tamoz-context-engine`**.
3. **A harness.** A system prompt with an identity, operating rules and tool
   guidance; operator persona and user preferences; the target project's
   `AGENTS.md` as attributed guidance; a living plan; a repeat guard; a finish
   contract. New gem **`tamoz-harness`**.
4. **A work loop in the session.** The durable session gets a budget-bounded
   `work` loop (the adaptive read-only loop, generalised) that runs tool calls
   through the existing approval gate and journal. `tamoz code` and chat both
   enter it.
5. **Coding tools.** Ranged reads, glob, regex grep, a diff after each edit,
   shaped check output, and recall of spilled output, in `tamoz-tools`.

## Owner decisions needed before WP1 (recommendations first)

| # | Question | Recommendation |
|---|---|---|
| D1 | How does the model call tools? | **Native tool calls** (OpenAI-compatible `tools`, which DeepSeek serves). Tool schemas sit in the frozen header, so they are cache-stable. The JSON-document protocol stays for the existing stage prompts. |
| D2 | How does "nothing acts without a reviewed plan" survive a long loop? | **A living plan with a declared scope, reviewed once.** The loop's first act is to write the plan (goal, done-when, files and checks in scope). The existing semantic reviewer accepts or revises it. Edits inside scope then run under the existing approval policy. Leaving the scope (a new path root, a new check) is a plan revision and gets reviewed again. The plan digest is bound to every effect, as it is today. |
| D3 | Shell access? | **No arbitrary shell in v1.** Configured checks (as today) plus a small read-only command allowlist declared as profile data (`git status/diff/log/show`, `rg`). A general shell is a separate, later decision. |
| D4 | Where does the target repo's `AGENTS.md` go? | **Into the body as attributed, untrusted guidance, never into the system prompt.** Opt-in per profile, with a byte budget. It can steer style. It can never grant a tool, a path or an approval. |
| D5 | Gem names | `tamoz-context-engine` (the window) and `tamoz-harness` (the prompt and the loop protocol). |
| D6 | Compaction policy | DSH defaults (trigger at 0.8 of the routed window, keep the newest 16%), plus the research rule **one compaction, then reset**: the second pressure event replaces the unpinned history with a handoff note and continues inside the same turn, and the turn ends `handed_off` after two resets — never a second compaction. |

## How this relates to active investigation

[../active-investigation/](../active-investigation/README.md) is planned on the
same branch and touches the same session, CLI and chat seams. It does not conflict
with this plan. Its governed probes register as one more read-only capability
source. The work loop in this plan sees them the same way it sees `read_file`.
Build order: WP1–WP4 here (gems, no session change) can run in parallel with
investigation WP1. The session changes (this WP5, its WP4) must be sequenced,
because both edit the session graph.
