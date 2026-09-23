# Test 2: read ten files, then mutate the fourth — what the context does

> Evidence for this file is regenerable: run `script/dsh_context_dump` inside a DSH session to
> reproduce a dump series. The raw `dump-*.json` files are not committed.

Session `19d45a72-86b9-44df-b700-03dd229c1568`, `origin: subagent`, route
`deepseek-v4.1-flash` @ 1,000,000. Ten reads of byte-identical sandbox copies in
`tmp/context-test/work/` (the repository was not touched; every copy verified SHA-256-identical to
its source), then a mutation sequence around the fourth file with a context dump after each step.
Seven dumps, one session. Raw data: `dump-t2-*.json`, subagent summary in `README-test2.md`.

Sequence: read 01–10 → dump pre-edit → **edit #1** → dump → re-read file 04 → dump → **append via
bash (outside the edit tool)** → dump → **edit #2** → dump → re-read → dump → **edit #3** → dump.

| dump | msgs | bytes | prompt | cached | uncached | cached − prev prompt | edits | replacements |
|---|---|---|---|---|---|---|---|---|
| t2-pre-edit | 25 | 565,779 | 162,974 | 145,792 | 17,182 | — | 0 | 0 |
| t2-post-edit | 29 | 566,755 | 163,366 | 163,072 | 294 | +98 | 1 | 0 |
| t2-post-reread | 33 | 618,731 | 178,803 | 163,584 | 15,219 | +218 | 1 | 0 |
| t2-post-external | 37 | 619,564 | 179,210 | 178,944 | 266 | +141 | 1 | 0 |
| t2-post-stale | 41 | 623,061 | 179,587 | 179,328 | 259 | +118 | 2 | 0 |
| t2-post-recovery-read | 45 | 674,948 | 195,575 | 180,352 | 15,223 | +765 | 2 | 0 |
| t2-post-recovery-edit | 49 | 675,774 | 195,981 | 195,712 | 269 | +137 | 3 | 0 |

Cache over the seven dumps: 1,255,496 prompt tokens, 1,206,784 cached (**96.1%**), 48,712 fresh.

## Findings

### 1. The earlier read is never rewritten — byte-identical

The 10 read nodes are **identical before and after the edit**: same seq, same byte counts. File 04's
read stays at `seq 31`, `51,008 bytes`. The whole step's growth is +976 bytes (the assistant tool
call plus a 123-byte result). Nothing was rewritten, pruned or shadowed: `replacements` is `[]` in
all seven dumps.

### 2. The cache is not invalidated — it is the *opposite*

The subagent read the +17,280 jump in cached tokens as "the cache was invalidated". It is the
reverse: `cached_n` equals the entire previous prompt plus a small amount (98, 218, 141, 118, 765,
137 tokens). At the post-edit step, 163,072 tokens were served from cache while only **294** were
fresh. The +17,280 is the *previous* step's fresh content (the tenth read) becoming cacheable. A
true invalidation would show `cache_read → ~0` and `uncached → ~163,000`.

### 3. The model-visible edit result is one line; the diff is UI-only

```
The file /Users/ghassan/my-projects/tamoz/tmp/context-test/work/04_approval_current_state.md has been updated successfully.
```

123 bytes. The 3-context-line diff is attached as `data.meta.diffs` — a **sibling** of
`data.message` — and `deriveEventMessage` returns `event.data.message` for `tool/result`, so it
never reaches the request. It is rendered by the client's `DiffBlock.tsx`:

```json
"meta": { "diffs": [ { "path": "…04_approval_current_state.md",
  "oldText": "\n---\n\n## 0. Headline finding: \"approval\" is three mechanisms sharing one word\n\nA grep …",
  "newText": "\n---\n\n## 0. Headline finding: \"approval\" is three mechanisms sharing one word [edit 1]\n\nA grep …" } ] }
```

So `DIFF_CONTEXT = 3` is a UI constant. Tamoz's work loop, by contrast, *does* append a diff to the
model result (`WorkGate#success_text`) — an addition, not parity, and it must justify its bytes on
its own.

### 4. An external change is completely silent

`user/*` node counts are constant across all seven dumps — `user/user` 1,
`user/agent-instructions` 1, `user/plugin` 1 — so nothing was injected after the bash append or
after the failed edit. The step's growth is the bash call plus its 117-byte output (the sha256).
The change surfaced only one step later, as a refusal.

### 5. Staleness is discovered at edit time, with a fix-it instruction

```
Error: cannot edit "/Users/ghassan/my-projects/tamoz/tmp/context-test/work/04_approval_current_state.md": file changed since it was read — re-read the file, then retry
```

169 bytes, `isError: false` in the block but the text is an `Error:` line. The edit wrote nothing.
The remedy works: re-read → edit #3 succeeded (123 bytes, same one-line shape).

### 6. Stale versions of the same file coexist

The final context holds **three** versions of file 04:

| node | seq | bytes | content |
|---|---|---|---|
| read #4 | 31 | 51,008 | before any edit |
| read #11 | 81 | 51,017 | after edit #1 (`+9` for ` [edit 1]`) |
| read #12 | 111 | 51,063 | after the external append (`+34` content, `+` line-prefix overhead) |

All three are visible. Recency is the only thing marking which is current; nothing supersedes the
older two unless pressure prunes them.

### 7. The model's own prose accumulates too

The 2,880-byte assistant message that follows the failed edit is the subagent's own write-up — it
accounts for most of the `+3,497` bytes in that step. No harness notice contributed to it.
