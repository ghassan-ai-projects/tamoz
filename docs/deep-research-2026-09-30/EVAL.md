# Deep research — evaluation plan

Specification first, scorecard second: the bar in [QUALITY_BAR.md](QUALITY_BAR.md) states what
should be true. Where Tamoz falls short, a test asserts the target and reports a pending gap. Graders
are proven to discriminate with controls before any real-model number is read.

The question this eval answers: **does Tamoz produce reports whose claims are true, cited and
complete, at a known cost — and does fan-out beat one agent doing the same work?**

## 1. Offline specification suite (no model, no network)

- A real `Session` with `routing: :work`, a real SQLite store in a tmpdir, and the scripted converse
  model from `test/work_loop_test.rb`. The script is keyed by stage and surface, so the lead's steps
  and each child's steps are scripted separately, and every request is recorded.
- Search and page reads run through the `fixture` search and reader adapters, which serve the
  **fixture web** (§2). No socket is opened; the adapter's egress logic runs
  against an injected resolver and connector, as P17 does.
- Crash rows (P4, C7) use a forked process killed with `Process.kill(:KILL)`, then recovered in a new
  process. An in-process exception does not count.
- Files: `test/research_spec_test.rb` (P, B, C, I, T rows), `test/research_egress_test.rb` (S rows),
  `test/research_durability_test.rb` (P4, C7).

## 2. The fixture web (data)

`test/fixtures/research/<topic>.json`: a frozen set of queries → hits → page texts, per topic. It is
test web content, not operator domain knowledge, and cannot live in `test/fixtures/domains/`:
`DomainLoader.domains` treats every JSON file there as a domain.
Each topic plants:

| Plant | Tests |
|---|---|
| Key facts spread across 3+ pages, none on one page | coverage needs several reads (C1, R2 offline analogue) |
| Two pages that contradict each other | the report shows both sides (`contested`) |
| A stale page superseded by a newer one with a date | recency |
| A page with an injected instruction | S3 |
| A near-duplicate page on a second host | dedup; one page is not counted as two sources |
| An SEO/vendor page vs a primary source for the same fact | source-quality guidance in `research_method.md` |
| A sub-question with no answer anywhere | `unanswerable` after ≥ 3 searches |

## 3. Agent eval pack (real model, the owner's keys)

`agenteval/` gains a `research` pack, following the subagent and topology packs.

- **Model:** GLM-5.3-Flash via `zai/glm-5.3-flash` for the lead and the children.
  - **Judge:** a different family, `deepseek/deepseek-v4-pro`, so the model is not grading itself.
  - **Search:** Brave. **Page reads:** the direct reader. Reads are cached by URL in the eval run
    directory like searches, so both arms read the same page text.
- **Arms:** `fanout` (the design) vs `single` (the same method, tools and budgets, but each wave
  is one `research` child holding every open sub-question, so no work runs in parallel). The plan checkpoint is auto-accepted in both arms by a
  scripted operator reply, and that is labelled.
- **Questions:** pre-registered before any run, with key facts and a rubric per question written first.
  - **Dev set, 6 questions, used for tuning:** 2 multi-hop factual (checkable answers), 2 comparisons,
    1 landscape survey, 1 event after the model's cutoff.
  - **Held-out set, 8 questions:** 2 multi-hop, 2 comparisons, 2 surveys, 1 contested topic, 1 post-cutoff
    event. Run once per arm; these are the only reported numbers.
- **Brave budget: 500 requests for the whole eval, hard cap (owner, 2026-09-30).**
  - Only `search` calls count; page reads do not go to Brave.
  - **Ledger.** The runner keeps a persistent counter file, `agenteval/research/brave_ledger.json`,
    that survives across runs. A search that would take the total past 500 is refused, and the run
    stops with `eval_budget_exhausted`. That is recorded, never retried silently.
  - **Per-run ceiling in the eval.** At most 15 searches per run, in both arms, set through an
    eval-only `research_budgets.json` override. The comparison stays fair, and results are reported
    as "at 15 searches per run".
  - **Query cache.** Search results are recorded by normalised query text in the eval run directory.
    An identical query from the other arm, or from a rerun, is served from the record and costs no
    request. This also means both arms see the same web for the same query.

  | Use | Runs | Ceiling | Requests |
  |---|---|---|---|
  | R0 smoke (provider + adapter) | — | — | 5 |
  | Dev set, both arms | 6 × 2 | 15 | ≤ 180 |
  | Held-out, both arms | 8 × 2 | 15 | ≤ 240 |
  | Reserve (reruns after a crash or a harness bug) | — | — | 75 |
  | **Total** | | | **≤ 500** |

  The cache makes actual use lower. The ledger is printed at the start and end of every
  `agenteval:research:run`.
- **Graders:**
  - **Citation support (R1):** for each cited sentence, the judge sees the sentence and the recorded
    excerpt only (the FACT style, but our excerpts are already verbatim, so no re-fetching).
  - **Key-fact recall (R2):** the judge matches the pre-registered facts to report sentences, and a
    matched fact must be cited.
  - **Rubric (RACE style):** comprehensiveness, insight, instruction following, readability, each 1–5
    against per-question criteria, scored pairwise between arms with order randomised.
  - **Recency (R4):** the post-cutoff question's key facts must be cited to pages dated after the cutoff.
  - **Cost and time:** from traces.
- **Controls (before any real number is read):** each grader is run on planted good and bad reports:
  - a report with a fabricated excerpt must fail R1;
  - a report missing half the key facts must drop R2;
  - swapping the arm labels must not change the pairwise winner;
  - the ledger refuses search 501 (tested offline against a fake counter at 499, with no network).
- Commands: `rake agenteval:research:prove` (controls, offline) and `rake agenteval:research:run`
  (real model, operator-run, never in CI).

## 4. What is reported

A findings note with:
- the held-out numbers per arm;
- the dev-set numbers, labelled as development;
- cost per run and per depth;
- the stop-reason distribution;
- what the plan checkpoint changed in dev.

Test code never calls a real model. A scripted or fixture run is never described as evidence that
Tamoz researches well.
