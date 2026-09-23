# Controlled reproduction: ten big reads, context dumped after each

> Evidence for this file is regenerable: run `script/dsh_context_dump` inside a DSH session to
> reproduce a dump series. The raw `dump-*.json` files are not committed.

Session `0bde31c8-1eb7-4f8f-854f-df7962cb7818`, origin `subagent`, route
`deepseek-v4.1-flash` @ 1,000,000. A subagent read ten large Tamoz files (one read per step,
nothing batched), then re-read file 03 as read 11. After **every** read it ran
`dump_context.rb`, which folds its own session log into the derived model-visible message list.
Eleven dumps, one session, no other tool used during the series. Raw data: `dump-01.json` …
`dump-11.json`, `README.md`.

## What entered, and what stayed

| dump | file | on disk | returned | of file | prompt | Δ prompt | cached | uncached |
|---|---|---|---|---|---|---|---|---|
| 01 | `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb` | 39 KB | 45,579 | 113% | 23,478 | — | 11,392 | 12,086 |
| 02 | `test/comms_gateway_test.rb` | 45 KB | 52,032 | 112% | 38,896 | 15,418 | 23,552 | 15,344 |
| 03 | `test/memory_engine_test.rb` | 42 KB | 48,360 | 112% | 52,860 | 13,964 | 39,040 | 13,820 |
| 04 | `documentation/adr/approval-policy-redesign/02-current-state-audit.md` | 46 KB | 51,026 | 108% | 68,114 | 15,254 | 52,992 | 15,122 |
| 05 | `test/agent_profile_machinery_test.rb` | 48 KB | 56,147 | 112% | 84,478 | 16,364 | 68,224 | 16,254 |
| 06 | `gems/tamoz-sqlite/lib/tamoz/sqlite/migrator.rb` | 63 KB | 57,628 | 89% | 98,851 | 14,373 | 84,608 | 14,243 |
| 07 | `script/tamoz_sqlite_oracle` | 76 KB | 58,873 | 75% | 115,951 | 17,100 | 99,072 | 16,879 |
| 08 | `docs/GAUNTLET_PROGRESS.md` | 135 KB | 55,365 | 40% | 131,620 | 15,669 | 116,096 | 15,524 |
| 09 | `test/support/agent_smoke_corpus.rb` | 114 KB | 57,740 | 49% | 146,346 | 14,726 | 131,712 | 14,634 |
| 10 | `docs/requirements-audit.json` | 319 KB | 58,390 | 18% | 163,553 | 17,207 | 146,432 | 17,121 |
| 11 | `test/memory_engine_test.rb` (**repeat of 03**) | 42 KB | 48,360 | 112% | 177,517 | 13,964 | 163,584 | 13,933 |

At the end: **47 visible messages, 614,891 bytes, 177,517 prompt tokens**, of which tool results are
590,676 bytes (96%). **Zero replacements in all eleven dumps** — no prune, no compaction, no
supersession. Every one of the eleven read results, including the deliberate duplicate, is still on
the surface at the end.

## Findings

1. **Read content is resident and is never summarised.** 589,500 bytes of read output went in and
   590,676 bytes of tool output are resident at the end. The repeat read was appended in full
   (48,360 bytes again) — DSH has no read dedup.
2. **The cap is the only bound, and it is a window, not a summary.** Files under 50 KiB arrive whole
   (returned ≈ 108–113% of the file: the extra is the `N: ` line-number prefix). Files over it are
   cut at the 50 KiB content cap with `Use offset=N to continue`: `migrator.rb` 89%,
   `tamoz_sqlite_oracle` 75%, `GAUNTLET_PROGRESS.md` 40%, `agent_smoke_corpus.rb` 49%,
   `requirements-audit.json` **18%**. So for a 319 KB file, 82% of it never entered the context at
   all — because it was never read in, not because anything summarised it.
3. **The cache is the whole reason this is affordable.** Cached tokens at step *n* equal the entire
   prompt at step *n−1* (23,552 vs 23,478; 39,040 vs 38,896; 163,584 vs 163,553). Over the eleven
   steps: 1,101,664 prompt tokens, 936,704 cached (85.0%), **164,960 fresh (15.0%)**.
4. **A read's cost is paid once and then re-sent.** Marginal prompt per read: mean 15,403 tokens
   (13,964–17,207) for ~54 KB. That content was then re-sent 2,868,619 bytes (2.8 MB) across the
   remaining steps — at the cache rate, but re-sent nonetheless. This is why dedup and bounded
   reads are cost work, not pressure work.
5. **`bytes / 4` underestimates by ~13% on code.** 614,891 bytes → 177,517 tokens measured, i.e.
   **3.46 bytes/token**; the heuristic would have said 153,722 (86.6% of the truth). Source code and
   JSON tokenize denser than four bytes per token, so the meter's calibration term carries real
   weight.
6. **The window decides whether any of this machinery fires.** Tamoz's documented 64K window has a
   0.8 trigger at 52,428 tokens: this series crosses it at step 3 (52,860) and the 0.92 backstop
   (60,293) by step 5 (84,478), so pruning/compaction would have started shadowing those reads. At
   the 1M route it ran to step 11 with zero replacements. Same code, same content, different policy.
