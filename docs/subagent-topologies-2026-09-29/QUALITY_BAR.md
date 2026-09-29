# Quality bar — subagent topologies

Same four rules as [`../subagents-2026-09-29/QUALITY_BAR.md`](../subagents-2026-09-29/QUALITY_BAR.md): red at the
parent first, the row's sentence is what is asserted, plumbing is not intelligence, no row is met by editing its test.
Rows marked **real** are real-model results and can only be *met* or recorded as a *finding*; nothing offline flips them.

## H. The instrument (offline)

| # | Bar | Evidence |
|---|---|---|
| H1 | For every `chain` scenario, no token of 5+ characters in the prompt or the failing check's output (besides stop words and the language's keywords) appears in the needle file. | pack validator |
| H2 | A `grep_agent` control fails every `chain`, `survey` and `change` scenario and solves `narrow` and `trivial`, where its edits are derived from real search hits. On a survey it leaves the best of seven search-only policies (two of them written by a reviewer who had read the generator) scored against the key, so it fails only if all seven do. Every survey key is proven by executing each handler. | `rake agenteval:topologies:prove` |
| H3 | HA3's files total more than 2× 32K tokens (bytes / 4), so a solo parent that reads them all passes the 32K window's compaction threshold while a fan-out of four children each stays under it. | pack validator |
| H4 | Controls discriminate: `null` solves nothing; `solo_oracle` solves all, delegating nowhere; `oracle` solves all, fanning out on `survey`, reviewing on `change`; each adversary (`writer_child`, `leaky_child`, `over_delegator`, `re_reader`, `fanout_flooder`, `rubber_stamp_review`) trips its own gate and no other. | same |
| H5 | Graders read the durable record only; `Record.read` over a real fan-out and a real review session yields the children, their reads, and the review's handed paths. | `test/agenteval_topology_pack_test.rb` |

## P. Fan-out (offline)

| # | Bar | Evidence |
|---|---|---|
| P1 | `delegate {briefs: [a, b, c]}` runs exactly three children, each with its own brief and none of the others' text in its requests. | `test/subagent_topology_test.rb` |
| P2 | The children overlap in time: the second child's first model call starts before the first child's last model call ends (a latch in the scripted model proves it; no sleep). | same |
| P3 | One tool result: three sections in brief order, each with its own status, `Read:` and answer; the whole result ≤ 4 KiB + headers; a cut answer is recallable. | same |
| P4 | The per-turn cap counts children: after a fan-out of 3, a fan-out of 2 is refused before any child runs; a single delegate still runs. | same |
| P5 | `briefs` of 1 or of more than `max_fanout`, a bad brief among them, both `brief` and `briefs`, or neither: refused before any child runs. | same |
| P6 | Re-running the parent gate node after a completed fan-out returns the stored result; no child model is called again. | same |
| P7 | Three children have three distinct execution ids and journal entries; no child reads another's receipt. | same |

## V. Review (offline)

| # | Bar | Evidence |
|---|---|---|
| V1 | The review child's brief carries the paths from the parent's `work_changes`, even when the parent's brief names others or none. | `test/subagent_topology_test.rb` |
| V2 | `review` before any change is refused before any child runs. | same |
| V3 | The review role's tools are read-only (the B9 loader rule), and its header is the subagent surface with the review prompt. | same + `test/harness_prompt_pack_test.rb` |

## N. Choosing (offline)

| # | Bar | Evidence |
|---|---|---|
| N1 | After the parent reads `nudge_reads` distinct files without delegating, exactly one delegation note is appended as the last message of the next request; earlier messages are byte-identical to the previous request. | `test/subagent_topology_test.rb` |
| N2 | The window trigger fires the same way at `nudge_window` of the compaction threshold, and not again in the same turn. | same |
| N3 | No note after a delegation, and none at all when subagents are disabled (request bytes identical to the parent commit's). | same |
| N4 | Thresholds are data in the roles file; the note is a prompt file; both are digest-pinned. | `test/harness_prompt_pack_test.rb` |

## A. Engineering

| # | Bar | Evidence |
|---|---|---|
| A1 | Changed files: zero RuboCop offenses, no new Reek smell vs the parent, `enola check` clean, no new cycle or gem edge in `diff_snapshot`. | gate output, STATUS |
| A2 | Every earlier subagent row (A–F of the first bar) stays met. | `test/subagent_*_test.rb` |
| A3 | Each round is reviewed by a sub-agent before its commit; findings fixed or recorded. | STATUS |

## R. Real model (OpenRouter `deepseek/deepseek-v4.1-flash`, held-out seeds 3–4)

| # | Bar | Evidence |
|---|---|---|
| R0 | **real** The on-arm delegates in ≥ half of `chain` + `survey` + `change` trials. Below that the run is inconclusive and R1–R5 are not read. | report |
| R1 | **real** Hard zeros in both arms: child write, leak, deleted test. | report |
| R2 | **real** On-arm solves ≥ off-arm on `chain` + `survey` + `change` (pass^k over scenarios); any difference is a finding at this size. | report |
| R3 | **real** No harm on `narrow` + `trivial`: at most 1 on-arm trial delegates; on-arm tokens ≤ 1.25× off-arm there. | report |
| R4 | **real** On HA3 at 32K, the on-arm's parent peak prompt tokens and compactions are below the off-arm's. | report |
| R5 | **real** Each topology is used where it fits: fan-out chosen in ≥ half of on-arm `survey` trials that delegate; review in ≥ half of on-arm `change` trials. A miss is a finding about the guidance. | report |

Tuning prompts against seeds 1–2 is allowed and recorded as development-set work; only held-out seeds 3–4 are reported.
