# Deep research — research

## 1. What the field converged on

| Source | What it does | What we take |
|---|---|---|
| Anthropic, multi-agent research system (2025) | Lead agent writes a plan, spawns 3–5 parallel subagents with detailed task descriptions, each running its own search loop; a separate citation pass. Multi-agent beat single-agent by 90.2% on their internal eval; token spend explained ~80% of the variance on BrowseComp; about 15× the tokens of a chat turn. Early failures: subagents duplicating each other, 50 children for a simple question, SEO farms preferred over primary sources. | Orchestrator–worker; effort scaled to the question in the prompt; explicit objective, output shape and **boundaries** per child; source-quality rules; citation as its own step |
| LangChain `open_deep_research` | Scope (clarify + brief) → supervisor with `ConductResearch` / `ResearchComplete` over researcher subgraphs → one-shot report. Children **compress** findings before returning. Parallel section-writing by children gave disjoint reports and was dropped. Near the top of DeepResearch Bench. | Three phases; compression at the child's end; **one writer** |
| Cognition, "Don't build multi-agents" (2025) | Parallel agents that make decisions conflict because they don't share context. | Children read, never decide the report; all writing stays with the lead |
| STORM (Stanford, 2024) | Different **perspectives** ask different questions of the same topic; outline before writing. | Persona as a per-brief perspective |
| OpenAI / Gemini Deep Research | OpenAI asks clarifying questions first; Gemini shows an editable research plan. | Both, merged: the plan is shown before research, and carries at most one clarifying question |
| DeepResearch Bench (2025) | 100 PhD-level tasks; **RACE** (comprehensiveness, insight, instruction following, readability, judged against criteria) and **FACT** (statement–URL pairs, checked by fetching whether the source supports the claim). | Our bar splits the same way: report quality (rubric) and citation trustworthiness (checked) |

The shape everyone ships: one lead owns the whole context. Children are ephemeral, isolated and
read-only, and they return a compressed result. There is no peer-to-peer messaging and no shared
mutable state.

## 2. What Tamoz already has

| Need | Existing seam | State |
|---|---|---|
| Lead loop | Work route (`Session` routing `:work`, `WorkGate`, `WorkTools`), with the `surface_cli.md` / `surface_chat.md` prompts | Serves both CLI and chat |
| Children | `delegate` tool → durable subgraph (`work_delegation.rb`, `SubgraphRuntime#call_many`), roles as data (`subagent_roles.json`, `SubagentRole`) | Shipped, opt-in; `explore` and `review` roles; fan-out 2–`max_fanout` |
| Full child output kept, bounded summary to parent | `SubagentReport#render(budget)`; the whole answer is kept for `recall_output`; `ANSWER_BYTES = 4096` split across briefs | Shipped |
| Evidence-bound finishing tool | `report_findings` (`report_findings.json`, `Harness::FindingsReport`): every finding cites the ids of tool calls that succeeded this turn | Shipped for probes; the pattern research findings need |
| Search | `websearch` MCP source (`McpSourceBuilder`, `CapabilityBinding`), operator adapter `script/websearch_adapter`, egress policy/client/circuit in `tamoz-mcp-websearch` | Shipped with one `search` tool; `fixture` and generic `http` providers |
| Replay-safe external calls | `EffectDispatcher.run`, keyed on the request | Shipped |
| Context windows per route | `tamoz-agent-kernel/data/model_windows.yml` (pinned, `source` + `checked`) | Shipped; no concurrency field |
| Bounded parallel map | `Tamoz::Pool` in `tamoz-concurrency` | Shipped; not used by `call_many` |
| Clarifying question | comms `clarification_request` → `push_clarification_question` | Shipped |
| Numbers that change with evidence | `tamoz-agent-improvement` `CandidateLifecycle` (propose → evaluate → human approves digest → apply → rollback); `CandidatePolicy`: authority may only narrow | Shipped |

## 3. Gaps

| # | Gap | Evidence |
|---|---|---|
| G1 | The work route never shows websearch to the model | `WorkContext` builds schemas from the local toolbox, probes and memory only (`work_context.rb:121`); tool review 2026-09-26, finding 1 |
| G2 | No page read: search returns snippets only | Tool review item 5; `script/websearch_adapter` has one tool |
| G3 | `max_results` is not bounded | `websearch_adapter:114` accepts any positive integer |
| G4 | Brave's API does not fit the generic `http` provider | The adapter POSTs JSON with `Authorization: Bearer`; Brave is a `GET` with query parameters and an `X-Subscription-Token` header. Resolved by named provider adapters (DESIGN §5) |
| G5 | The egress policy allows exact FQDNs only | `EgressClient#validate_host!` ("v1 allows exact allowlisted FQDNs only", `egress_client.rb:186`). Reading pages directly would reach hosts nobody listed in advance. Resolved by a reader mode on the existing `EgressClient` checks (DESIGN §5.2) |
| G6 | No HTML → text extraction | No HTML parser in `Gemfile.lock`. Resolved by `nokogiri` in `tamoz-mcp-websearch` (DESIGN §5.2) |
| G7 | No `research`/`verify` roles, no findings tool bound to page reads, no skill | `subagent_roles.json` has `explore` and `review` only |
| G8 | Fan-out concurrency is unbounded and not tied to the provider | `call_many` starts one thread per brief; `max_fanout` is a fixed 2..8 |
| G9 | Fan-out merges missed items, and children repeated calls | T6 held-out: merged answers missed 18 and 21 handlers; `step_repetition` 0.54–1.0 (`docs/subagent-topologies-2026-09-29/FINDINGS.md`) |
| G10 | The Brave key is under a name the adapter does not read | `.env` has `BRAVE_API_KEY`; the adapter reads `TAMOZ_SEARCH_API_TOKEN`, and the egress policy only accepts `TAMOZ_*` credential refs (`CREDENTIAL_REF_PATTERN`). Resolved by adapters that declare their own credential names (owner: keep the key name) |
| G11 | No Z.ai provider for GLM-5.3-Flash | `Providers::ENV_KEYS` and the `ModelClientFactory` descriptors know deepseek, openrouter and others, but not `zai`; `.env` now has `ZAI_API_KEY` |
| G12 | No plan checkpoint on the work route | The work route pauses only for tool approvals (`WorkGate`, `work_gate.rb:185`); the old plan route's clarification (`session_plan_outcomes.rb:139`) is not on this path |

## 4. Provider limits (read 2026-09-30; re-check before pinning)

- **DeepSeek direct:** concurrency is limited dynamically by server load, with a 429 at the limit.
  The docs publish no fixed number; one third-party report gives 2,500 concurrent requests for flash.
  [docs](https://api-docs.deepseek.com/quick_start/rate_limit)
- **OpenRouter paid models:** there is no platform cap; the upstream provider's capacity decides,
  and 429s mostly come from upstream. [limits](https://openrouter.ai/docs/api/reference/limits)
- **Z.ai (GLM-5.3-Flash):** OpenAI-compatible at `https://api.z.ai/api/paas/v4`; 1M context,
  131,072 max output; $0.15 / $0.03 cached / $0.50 per 1M tokens. Z.ai publishes no concurrency
  number, and its limits adjust dynamically with load.
  [API intro](https://docs.z.ai/api-reference/introduction) · [pricing](https://docs.z.ai/guides/overview/pricing) ·
  [model listing](https://openrouter.ai/models/z-ai/glm-5.3-flash:batch)
- **Brave Search API:** the Search plan is $5 per 1,000 requests at 50 req/s, with $5 of free credit a
  month (about 1,000 searches). [pricing](https://api-dashboard.search.brave.com/documentation/pricing).
  At that credit, a deep run of up to 80 searches allows roughly 12 deep runs a month. Search count is a budget, not only a rate.

The model provider is not the binding limit at our scale: 4–8 children is far below either
provider's capacity. The binding limits are **cost** (tokens and searches) and **quality**. We pin a
conservative operator number and back off on a 429, which the transport already surfaces.

## 5. Turning a web page into text: the options (read 2026-09-30)

| Option | Quality | Tamoz egress | Cost | Verdict |
|---|---|---|---|---|
| **Cloudflare Browser Run `/markdown`** (REST: `url` or `html` in, markdown out; renders JS) | high; real browser, main content as markdown | one host, `api.cloudflare.com`; Tamoz never touches page hosts | Free: 1 req / 10 s, 10 min/day. Paid ($5/mo): 30 req/s, 10 h/month included, $0.09/h after | first choice, but needs a Cloudflare API token the owner does not have; kept as a possible later reader adapter |
| Cloudflare *Markdown for Agents* (`Accept: text/markdown`) | high where enabled | direct to each page host | free | not a general reader, but **used**: the direct reader sends the header and takes markdown when a site offers it |
| Local: `nokogiri` + main-content heuristics | medium to good on articles and docs; static HTML only, no JS | direct to each page host, through `EgressClient`'s existing DNS pinning, private-range refusal and per-hop redirect checks | free | **chosen** (owner, 2026-09-30) |
| Jina Reader (hosted or self-hosted), Firecrawl | high | one host | paid API / run a service | same shape as Cloudflare; no advantage, and another vendor |
| Trafilatura, ReaderLM-v2 | high | direct, plus a Python or model runtime | free | a second runtime in a Ruby repo |

Cloudflare `/markdown` would have kept Tamoz's egress to a fixed allowlist and handled JavaScript
pages, but it needs a Cloudflare API token the owner does not have. The local reader is chosen instead:
- it is free and needs no new vendor;
- the security work it needs mostly exists already, in `EgressClient`'s DNS pinning, private-range
  refusal and per-hop redirect checks;
- sending `Accept: text/markdown` picks up *Markdown for Agents* wherever a site offers it.

Its known weakness is pages that only render with JavaScript. Real runs will show whether that loses
key sources; if it does, a hosted reader adapter is the fix.

Sources: [/markdown endpoint](https://developers.cloudflare.com/browser-rendering/rest-api/markdown-endpoint/) ·
[limits](https://developers.cloudflare.com/browser-rendering/limits/) ·
[pricing](https://developers.cloudflare.com/browser-rendering/platform/pricing/) ·
[REST rate increase 2026-03](https://developers.cloudflare.com/changelog/2026-03-04-br-rest-api-limit-increase/) ·
[Markdown for Agents](https://developers.cloudflare.com/fundamentals/reference/markdown-for-agents) ·
[HTML → Markdown for LLMs](https://tds.s-anand.net/2026-02/docs/week-6/html-to-markdown/) ·
[ReaderLM-v2](https://jina.ai/en-US/news/readerlm-v2-frontier-small-language-model-for-html-to-markdown-and-json/)

## 6. Conclusions

1. The design is the shape the field ships. Tamoz already has most of its parts: durable
   children, roles as data, evidence-bound finishing tools, replay-safe calls, a human-gated
   tuning loop. The missing pieces are all on the **web side** (G1–G6) plus the research roles
   and gates (G7–G9).
2. Tamoz's distinctive advantage is **checkable citations**. Every page read is a journaled
   receipt, so a claim can be refused at record time if its excerpt is not in the page the child
   actually read. Most systems check citations after the fact, or not at all.
3. The T6 result is a warning, not a verdict. Code surveys did not gain accuracy from fan-out.
   Research is the case where fan-out is known to pay: broad, read-heavy, independent. It still has
   to be shown on our own held-out run, with the single-agent arm as the control.
4. Budgets must be data, and they must move with evidence. The field's numbers (3–5 children,
   15× tokens) are starting points, not truths for our model and our questions.

Sources: [Anthropic — How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) ·
[LangChain — Open Deep Research](https://www.langchain.com/blog/open-deep-research) ·
[langchain-ai/open_deep_research](https://github.com/langchain-ai/open_deep_research) ·
[Cognition — Don't build multi-agents](https://cognition.ai/blog/dont-build-multi-agents) ·
[STORM (arXiv 2402.14207)](https://arxiv.org/abs/2402.14207) ·
[DeepResearch Bench (arXiv 2506.11763)](https://arxiv.org/abs/2506.11763) ·
[Patterns from production](https://tianpan.co/blog/2026-02-04-building-multi-agent-research-system)
