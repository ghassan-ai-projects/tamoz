# Deep research — design

Research: [RESEARCH.md](RESEARCH.md). Every part below extends a named seam from RESEARCH §2;
nothing here is a second loop, a second store or a second delegation mechanism.

## 1. Shape

```
user question (CLI or chat)
  └─ lead = the work loop, following the research method (`research_method.md`)
       1 scope    brief (sub-questions, perspectives, depth) → PLAN CHECKPOINT: the user sees the
                  research plan and approves, edits or stops it before any search runs
       2 research wave k: delegate(role research, N briefs) ──► N children in parallel (bounded pool)
                     each: search → read pages → report_sources (claims bound to page reads)
                  harness: ledger + coverage per sub-question → lead plans wave k+1 or stops
       3 write    lead writes the report once, citing ledger claim ids; harness renders the sources list
       4 verify   delegate(role verify, claim/excerpt pairs) → unsupported ids → lead revises
  └─ report delivered on the same surface; run folder written from the durable record
```

The lead is the existing work loop, not a new agent. The method (how to scope, split, judge
coverage and write) lives in `research_method.md` in the harness prompt pack, pinned into a research
turn's opening. (Skills are operator-sourced by design, P9, so no gem ships one; a prompt file is the
existing seam.) The **checks** — the ledger, the excerpt
check, the coverage gate, the budgets — live in the harness, so the model cannot talk its way past
them.

## 2. Interface: the same on CLI and chat, with no internals shown

- **One explicit command per surface** (owner):

  | Surface | Command |
  |---|---|
  | CLI | `tamoz deep-research "<question>"` |
  | Chat | `/research <question>` (Telegram command names allow no hyphen) |

  - Both start the same read-only work turn with the research method (`research_method.md`) loaded and the research
    tools admitted.
  - A plain question on the normal route gets a normal answer. It never starts a research run, so
    research costs (tokens, Brave searches, page reads) are only paid when asked for.
  - The user can steer depth in words ("quick look", "go deep"), or change it at the plan checkpoint.
- **Wiring:**
  - CLI: `"deep-research" => :cmd_deep_research` in `cli.rb`, a thin wrapper over `cmd_ask`, as
    `cmd_investigate` is.
  - Chat: `research` added to `Comms::Commands::KNOWN`.
  - Both land on the same session entry. R0 checks how the CLI answers a paused turn, so the plan
    checkpoint works in the terminal as it does in chat.
- **What the user sees**, rendered by the existing `surface_cli.md` / `surface_chat.md` rules:
  1. **the research plan, before anything runs** (§2.1);
  2. a few progress lines ("Reading sources on B", "Filling a gap on C");
  3. the report.
- **What the user never sees:** role names, subagents, waves, tool names, receipt ids, token counts,
  hashes, budgets. A render test fails on any of these (QUALITY_BAR I1).
- **Delivery (owner): the final report is written to the file system.**
  - Every run writes `report.md` to its run folder (§6).
  - The reply, on either surface, is the summary (3–5 sentences), the gaps in one line, and where the
    report was saved.
  - The full report is not pasted into the terminal or split across chat messages. Sending the file as a
    Telegram document is a later addition to `tamoz-telegram`.
### 2.1 The plan checkpoint (owner requirement)

Every run shows its plan and waits for the user before the first search. This is the one place
an early correction is cheap.

- **The plan message**, in plain words:
  - the question as Tamoz understood it;
  - the angles it will cover (the sub-questions, each with its perspective in a few words);
  - what it will leave out;
  - how deep it will go, with a rough time ("about 5 minutes", "about 20 minutes");
  - the one clarifying question, if the request is ambiguous. There is no separate clarifying round.
- **The user's answer**, in the same channel and in their own words:
  - "go" (or 👍) runs the plan;
  - any change ("drop B, add the Asian market, keep it quick") makes the lead revise the brief and
    run the revised plan. A change that adds or removes angles shows the plan once more;
  - "stop" ends the turn.
- **Seam (settled in R0).** The lead finishes scoping with a `propose_research_plan` call. The session
  pauses the turn with a durable `Tamoz.interrupt` of the existing **`clarify`** kind, with the rendered
  plan as its question. CLI (`CLI::PromptAdapter#clarify`) and chat (the worker's
  `request.clarification_request`, answered by a reply or `/answer`) already render that kind and
  return free text, so no new pause kind or surface code is needed. The answer returns to the lead as
  the call's result. The checkpoint is part of the research protocol, not an approval verdict, so
  nothing is added to the approval policy.
- **Durable.** A worker restart while waiting keeps the pause. The answer resumes the same turn.
- The harness refuses `delegate(role: research)` in a turn whose plan was not accepted
  (QUALITY_BAR P1).

### 2.2 Stopping

- **Stop:** a chat `/cancel` or a CLI interrupt goes through the existing `Cancellation::Stops`. The
  turn ends. No partial report is promised in v1.

### 2.3 Model

Owner decision: deep research runs on **GLM-5.3-Flash** through Z.ai's direct API.
- Model id `glm-5.3-flash`; base `https://api.z.ai/api/paas/v4` (OpenAI-compatible, Bearer auth).
- 1M-token context; 131,072 max output; function calling and prompt caching.
- $0.15 / $0.03 cached / $0.50 per 1M input / cached input / output tokens.
- Z.ai publishes no fixed concurrency number and says limits adjust with load.

Tamoz has no `zai` provider today (`Providers::ENV_KEYS`, `ModelClientFactory` descriptors). The
change is additive data:
- a `zai` descriptor (`openai-compatible`, `direct`, the base above);
- `ZAI_API_KEY` in `ENV_KEYS`;
- a `zai/glm-5.3-flash` route in `model_windows.yml` with `source`, `checked` and a pinned
  `max_concurrent_requests`.

The lead and the children use the same model (the rule the subagent plan set as its D7,
`docs/subagents-2026-09-29/PLAN.md`). The eval judge uses a
different model family (EVAL §3).

## 3. Roles and personas

Roles are fixed, reviewed data: entries in `subagent_roles.json` plus a prompt file. A role grants
tools and nothing else.

| Role | Prompt | Tools | Finishes with |
|---|---|---|---|
| `research` | `subagent_research.md`: search wide then narrow; prefer primary sources; record dates; stop your slice when it is covered | websearch `search`, websearch `fetch_result` | `report_sources` |
| `verify` | `subagent_verify.md`: judge only whether each excerpt supports its sentence; no outside knowledge | none beyond reading its brief | `report_support` |

**Persona is part of each brief, not a role.** When the lead calls `delegate`, each brief is a
structured object the harness renders into the child's opening:

| Field | Example |
|---|---|
| `sub_question` | id and text from the brief |
| `objective` | "Establish the current EU rules on X and their effective dates" |
| `perspective` | "a regulator", "a skeptic looking for failed deployments", "a practitioner" (STORM) |
| `boundaries` | "Market size is another child's slice; do not research it" |
| `source_hints` | "official journals, standards bodies; avoid vendor blogs" |

The perspective changes what the child asks, never what it may do. Tools always come from the role.

Needed changes to the seams:
- `SubagentRole::TOOL_PATTERN` accepts only `[a-z0-9_]`, so it must learn to name the websearch
  capability tools.
- `delegate.json` gains the structured brief for research roles.
- `report_sources` and `report_support` follow `report_findings.json` / `Harness::FindingsReport`.

## 4. Dynamic fan-out and concurrency

**How many children in a wave:**
`N = min(open sub-questions the lead assigns, depth's children_per_wave, role max_fanout)`.
The lead chooses N. The harness refuses anything over the cap, the same way `admitted` refuses today.

**How many run at once:**
`min(N, max_concurrent_requests(route) − 1)`. One slot is kept for the lead. The rest queue.
- `WorkDelegation#run` passes the briefs to the existing `call_many` in **batches of that size**.
  `tamoz-graph` does not change, and call indexes stay in input order. A pool inside `call_many`
  (`tamoz-graph` already depends on `tamoz-concurrency`) is the upgrade only if a real run shows
  batches waiting on their slowest child.
- `max_concurrent_requests` is a new field per route in `tamoz-agent-kernel/data/model_windows.yml`,
  pinned with `source` and `checked` like `context_window`. A route without the field runs children
  one at a time rather than guessing.

**Per-role limits:** `subagent_roles.json` gains optional per-role `max_per_turn` / `max_fanout`.
Research needs more children per turn (up to 12 across waves) than the global `max_per_turn` of 4.

**429s:** handled by the transport's existing retry. No adaptive throttle until a real run shows 429s.

**Search rate:** not throttled separately. 8 concurrent children sit far below Brave's 50 req/s.
Search **count** is budgeted (§8).

## 5. Search and page reads: two provider adapters

Both live in `tamoz-mcp-websearch`, which owns the HTTP stack, and are served through the existing
`websearch` MCP source. Each **adapter** is a small named class that owns its endpoint (exactly one
host), its request shape, its credential name, and the normalisation of its response. The operator
picks adapters by name. The model never sees which one is running.

```
sources.websearch: { search: "brave", reader: "direct" }    # tests use "fixture" for both
```

**Credentials.** Each adapter declares the env var it reads, and the name is pinned in reviewed code.
The direct reader needs none. Brave's ref is `TAMOZ_BRAVE_API_KEY`: four gems (`tamoz-mcp`
`ServerConfig`, `tamoz-agent-profile`, its egress validator, `tamoz-mcp-websearch` `EgressPolicy`)
enforce that a credential passed to a server is a `TAMOZ_*` name, so a model key or host secret can
never be handed to one by a config line. Widening that across four gems is an authority change this
feature does not need. `.env` keeps `BRAVE_API_KEY` as it is; whoever launches the worker exports
`TAMOZ_BRAVE_API_KEY` from it, and the eval runner does that mapping itself. (Deviation from A12's
wording, recorded in STATUS.md.) The generic `http` provider
is removed, not kept beside the adapters (owner rule: no compatibility code). R1 moves its tests onto
the adapters.

### 5.1 `search`: the Brave adapter

- `GET https://api.search.brave.com/res/v1/web/search` with `q` and `count`, header
  `X-Subscription-Token`. `count` is clamped to 10 (G3).
- The response is normalised to `{title, url, snippet, age}` per hit, and the hits are recorded in the
  journal with the search call.

### 5.2 `fetch_result`: the direct reader adapter

**Decision (owner, 2026-09-30):** Tamoz reads pages itself through the existing `EgressClient`, and
turns HTML into text with `nokogiri`. The adapter structure leaves room for a hosted reader (e.g.
Cloudflare `/markdown`) later, without touching callers.

- **Destination = a search hit.** The model-visible `read_page` takes a ref such as `S2-3` (search 2,
  hit 3), never a URL. The **session** resolves the ref from the hits it recorded in the turn's state
  when the search ran, and sends the adapter that URL. The adapter, as defence in depth, reads only a
  URL that one of its own searches returned in this process. The model cannot compose a URL, so it
  cannot use a URL's query string to leak data.
- **Egress: one deliberate widening, on the existing checks.**
  - `EgressClient` already refuses non-https and IP literals, resolves DNS and pins a public address
    (`pin_address`, private ranges refused), re-validates every redirect hop (`redirect_target`), drops
    credential headers on a host change, and enforces the hop limit and the circuit.
  - The one change: in reader mode, the exact-FQDN allowlist check (`validate_host!`) accepts any
    public FQDN, both the search hit's host and each redirect hop's host. Every other check stays as it is.
  - The operator opts in through the reader adapter's configuration. The search adapter stays
    exact-FQDN (`api.search.brave.com`).
- **Request:**
  - `GET` with no credentials and no cookies;
  - `Accept: text/markdown, text/html;q=0.9, text/plain;q=0.8`, so sites that serve markdown to
    agents (Cloudflare's *Markdown for Agents*) return it directly and free;
  - a Tamoz user agent;
  - raw body capped at 2 MiB. `EgressPolicy::MAX_RESPONSE_BYTES` (64 KiB) is a hard ceiling today, so the
    reader mode brings its own response ceiling; search keeps 64 KiB;
  - a deadline per read.
- **Extraction** (`text/html` only; `text/markdown` and `text/plain` pass through):
  - parse with `nokogiri`;
  - take `<article>`, else `<main>` / `[role=main]`, else `<body>`;
  - drop `script, style, noscript, nav, header, footer, aside, form, iframe, svg`;
  - emit plain markdown: headings, paragraphs, list items, table rows as lines, link text without URLs;
  - read the title from `<title>` / `og:title`, and the published date from
    `article:published_time`, `<time datetime>` or JSON-LD `datePublished` when present.
  - It is about 100 lines in the adapter, with no readability port and no second library.
- **Output:** the extracted text, capped at 32 KiB, returned as untrusted, attributed page content
  (never instructions), with the URL, title and date.
- **Journal:** each read is an ordinary tool effect through `EffectDispatcher.run`, keyed on the
  request like every other call. Children have their own request ids (`.agent/rules/subgraphs.md`),
  so they do not share receipts. When two children read the same page, the adapter serves the second
  from a small in-process cache keyed on the URL (C6).
- **Approval:** classified read-only in `gems/tamoz-approval/policy/*.yaml`, not in code.
- **A failed read** (refused host, timeout, bot wall, too little text, unsupported type) is a failed
  call with a reason. The child moves on.
  - PDF is deferred until a real run needs it.
  - Pages that only render with JavaScript come back thin. That is recorded, and a hosted reader
    adapter becomes a decision only if real runs lose key sources this way.

**Dependency:** `nokogiri` in `tamoz-mcp-websearch` only, the operator-side HTTP stack. It is
maintained, and ships precompiled native gems for macOS and Linux. `docs/DEPENDENCY_REVIEW.md`
gets the entry.

## 6. The ledger, context and files

**`report_sources` (the research child's finish).** Each entry is:
`{sub_question, claim, fetch_call, excerpt, published?}`.
- At record time the harness checks that `fetch_call` is a successful page read in **this child's**
  turn, and that `excerpt` occurs in that read's text. Whitespace is normalised; the excerpt is 20–400 chars.
- A failing entry is refused with a reason, and the child can fix it. This is where fabricated
  citations stop.

**Ledger.** It is the union of the children's accepted entries, stored with their durable output
(the same place `recall_output` reads from). The lead never sees raw pages. It sees:

| Who | In context | Budget (starting value) |
|---|---|---|
| Child | brief + page texts (≤ 32 KiB each, about 8k tokens) + its notes; existing compaction beyond that | ~40–80k tokens |
| Lead, per wave | brief + each child's summary (claims one line each, ≤ ~1.5k tokens) + a coverage table from the harness | ~30–40k across 3 waves |
| Lead, writing | brief + the full ledger, via `recall_output` | ~60–80k |
| Verifier | (sentence, excerpt) pairs only | ~10–20k |

**Run folder: the report on disk.**
- **Who writes it.** `tamoz-research` renders the folder's contents from values it is given.
  `tamoz-agent-session` writes them. A child never writes: children stay read-only, and `create_file`
  stays forbidden.
- **Where.** The name is readable, and the run id is inside `run.json`:

```
$TAMOZ_RUNTIME_DIR/research/<YYYY-MM-DD>-<question-slug>/
  report.md       the final report (the deliverable)
  brief.md        the accepted plan: sub-questions, perspectives, depth, and the stop reason
  notes/<n>.md    one per child: its brief and accepted claims with excerpts
  sources.jsonl   one line per page read: url, title, date published, date read
  run.json        the run record (§9)
```

- **How the write is made safe.** The write goes through `EffectDispatcher.run` as an idempotent
  effect keyed on the report's digest. Each file is written to a temp file, then renamed. A replay
  rewrites the same bytes, and a crash never leaves a half-written report.
- **What is the source of truth.** The durable record is; the folder is its projection. A report file
  deleted by hand can be regenerated from the thread.

## 7. When research stops

After each wave the harness sets every sub-question's status from the ledger:

| Status | Rule |
|---|---|
| `answered` | ≥ 2 claims from different hosts that the lead marks as agreeing, or 1 claim from a source the lead marks primary |
| `contested` | the lead records a disagreement between cited claims; both sides stay in the report |
| `unanswerable` | the lead declares it after ≥ 3 distinct searches on it with no accepted claim |
| `open` | anything else |

The lead's marks must point at ledger claims, so a status is never a bare assertion.

The run stops at the first of:
1. **coverage:** no `open` sub-question;
2. **saturation:** a wave added no accepted claim to any still-open sub-question;
3. **budget:** the depth's waves, children, searches, page reads, tokens or wall time;
4. **user stop.**

`WorkGate` refuses the lead's finish while a sub-question is `open` and none of 2–4 holds. The report
states the stop reason, and lists every non-answered sub-question under "Gaps and limits".

## 8. Budgets are data, and they move

One data file, `research_budgets.json` in `tamoz-research`'s `data/`, with two layers:

- **An eval override** is a second document passed by the caller (the eval runner) and validated
  against the ceilings: it can only narrow them (EVAL's 15 searches per run).
- **Ceilings (operator authority).** Maximums for children per run, waves, searches, page reads,
  tokens and wall time. Tamoz may propose **lowering** a ceiling, never raising one (`CandidatePolicy`:
  authority only narrows).
- **Defaults per depth (Tamoz may tune).** Starting values, to be moved by evidence:

| Depth | children/wave | waves | searches | page reads | report words |
|---|---|---|---|---|---|
| quick | 1–2 | 1 | 10 | 8 | 500–800 |
| standard | 2–4 | 2 | 40 | 30 | 1,500–2,500 |
| deep | 3–4 | 3 | 80 | 60 | 4,000–6,000 |

**Within a run:** the lead picks the depth and N freely inside the ceilings. No approval is needed.

## 9. Learning the numbers (self-tuning)

- Every run writes `run.json`: question class, depth, children and waves used, searches, page reads,
  tokens, wall time, stop reason, the claims each wave added, verifier support rate, sub-question
  statuses, and the owner's optional verdict (a 👍/👎 or a sentence, on either surface).
- The existing improvement lifecycle proposes a `research_budgets.json` **candidate** from those records.
  Example: "standard runs saturated at wave 1 in 7 of 9 runs → default waves 2 → 1".
- The candidate is evaluated on the offline pack plus the dev question set (EVAL), the owner approves
  its digest, and it is applied, with rollback kept. Nothing changes silently. Nothing tunes itself
  on the held-out set.

## 10. Report shape

- Summary (3–5 sentences).
- Findings by sub-question, each sentence citing `[n]`.
- Where sources disagree.
- Gaps and limits: the stop reason and the non-answered sub-questions.
- Sources: **generated by the harness** from the cited ledger ids (URL, title, date read). The lead
  cannot put a source in the list that no child read.
- Dated claims carry their date. The report uses the user's language.

## 11. The `tamoz-research` gem (owner: a new gem, boundaries absolute)

**What it owns.** The research rules, as pure Ruby with no I/O, no store and no model or network call.
It depends only on `tamoz-core`.

| Owned | What it does |
|---|---|
| `Ledger` | accepts or refuses a child's `report_sources` entries, given the page-read texts it is handed; merges children; deduplicates claims |
| `ExcerptCheck` | whitespace-normalised verbatim match, length bounds |
| `Coverage` | sub-question statuses from the ledger and the lead's marks |
| `StopRule` | coverage / saturation / budget / user, and why |
| `Budgets` | loads and validates `research_budgets.json` (ceilings and per-depth defaults) from the gem's own `data/` |
| `Report` | resolves `[n]` citations against the ledger, generates the sources list, checks the shape (I2) |
| `RunFolder` | renders the folder's files as `{relative path => content}`; writes nothing |
| `RunRecord` | builds `run.json` |

**The facade.** It is named in the gem's README and is the only way in:

| Call | Returns |
|---|---|
| `Tamoz::Research.ledger(...)` | the ledger |
| `.coverage(...)` | sub-question statuses |
| `.stop?(...)` | whether to stop, and why |
| `.budgets` | the loaded budgets |
| `.report(...)` | the checked report |
| `.run_folder(...)` | the folder's files |
| `.run_record(...)` | the `run.json` record |

Inputs and outputs are frozen `Data` values or plain hashes. No caller constructs an inner class or
reads an inner field.

**What it does not own**, and where each lives instead:
- the work loop, `delegate`, the plan pause, writing files, the effect journal → `tamoz-agent-session`
- prompts, roles, tool schemas, the research method → `tamoz-harness`
- search, page reads, egress → `tamoz-mcp-websearch`
- the approval verdict → `tamoz-approval` policy YAML
- tuning candidates → `tamoz-agent-improvement`, which proposes a new `research_budgets.json` through
  `Tamoz::Research.budgets` validation, never by editing the file's internals

**Edges.**
- New: `tamoz-agent-session → tamoz-research`, `tamoz-agent-improvement → tamoz-research` and
  `tamoz-agent-cli → tamoz-research` (the CLI validates `--research-budgets` through the facade before a run
  starts), all facade only. `tamoz-harness` holds only the `report_sources` JSON schema; parsing it is
  `Tamoz::Research`'s job, called from the session, so there is no harness → research edge.
- `tamoz-research` imports nothing from `tamoz-agent-*`, `tamoz-mcp*`, `tamoz-harness` or
  `tamoz-graph`.

**Guards.**
- `test/research_boundary_test.rb` fails when:
  - any file outside `gems/tamoz-research/` names a `Tamoz::Research::` constant other than the facade;
  - `tamoz-research` requires anything beyond `tamoz-core` and the stdlib;
  - `tamoz-research` performs I/O (`File.write`, sockets, `Net::`, `IO.popen`) outside its data loader.
- It follows `test/memory_boundary_test.rb`. enola checks the edges (QUALITY_BAR A2).

## 12. Cost (estimate on GLM-5.3-Flash + Brave; measured in R8)

A standard run is about 8 child loops of ~15 calls each, plus ~25 lead calls.

| Item | Amount | Cost |
|---|---|---|
| Prompt tokens | ~3M, of which ~80% are cache hits | 2.4M × $0.03 + 0.6M × $0.15 ≈ $0.16 |
| Output tokens | ~100k | ≈ $0.05 |
| Brave searches | ~30 | ≈ $0.15 |
| Page reads | ~30, direct | free |
| **Total** | | **≈ $0.35** |

A quick run costs a few cents; a deep run about $1. Brave's $5 monthly credit (~1,000 searches) is
the first limit we will hit, not the model.
