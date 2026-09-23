# Context management — the prompt cache is prefix-exact

Learned mapping DSH's context machinery onto the Tamoz harness
(`docs/coding-harness/`, measured with `script/dsh_context_survey`).

- **A disk change is not a prompt event; a prompt-byte change is.** A file changing under
  the model costs nothing and touches nothing. Only rewriting the prompt moves the cache:
  an append re-bills the appended bytes, a rewrite re-bills the whole suffix uncached. In
  7,236 measured steps at a 1M window DSH rewrote nothing; its widest prompt (598,597
  tokens) was 99.6% cache read. Never rewrite an earlier message because the world changed —
  append the correction and let recency carry it.
- **Pin the model's view when it is formed; never re-derive it at use.** The gate filling
  `expected_sha256` from the disk (`session_effects.rb:340`) is the same defect the
  "pin authority; never re-derive it" rule names: the check passes against the current file,
  so a blind edit is accepted and an outside change is silently rebased. Record the observed
  version at read time and compare against that.
- **Measure the deployment, not the package defaults.** DSH's spill default is absent and its
  deployed value is 50,000 — six times the number its own docs/plan draft used. Read
  `packages/bundle/base/cordis.patch.yml` before claiming parity.
- **A window is policy, not a constant.** Same machinery, 0 compactions on a
  1,000,000-token route and 32 on 262,144-token routes, with the ceiling exactly at the 0.8
  trigger. An eval arm at 12K measures the compaction path, not how the agent behaves.
- **Say which mechanisms are parity and which are additions.** DSH has no proactive
  "file changed" note for read results and no read dedup — both absent by source search. It
  does own the pattern on the instruction channel (`Instructions removed: <path> — … no longer
  apply.`). Tamoz generalises it; label that as an extension, never as DSH parity.
- **Usage has two shapes.** `prompt_tokens = input_uncached + cache_read`; some routes report
  `totalTokens` and some only the three parts, and `totalTokens` also includes output. A
  missing number stays missing.
- **File content really is in the context; it is bounded, not summarised.** Measured across 42,124
  DSH tool calls: file content outruns tree/glob/lsp structure about 68:1, ~96% of results came
  back whole, and `read` is never spilled (the spill policy skips it by name to avoid a
  read → spill → read loop). Nothing substitutes an AST or outline for the bytes. A plan that
  assumes "the agent only keeps a summary" under-counts the window; bound the read, dedup it, and
  diff instead of re-reading — do not expect eviction below the trigger.
- **A UI affordance is not context.** DSH's edit returns the model one line (`… has been updated
  successfully.`, 123 bytes) while the 3-context-line diff rides `data.meta.diffs` beside the
  message and is excluded from the request by `deriveEventMessage`; only `DiffBlock.tsx` renders
  it. Read the projection (`deriveEventMessage`) before claiming a mechanism is model-visible.
- **A stale edit is the only freshness signal, and it arrives late.** Measured: an out-of-band
  write injects nothing at all (`user/*` node counts unchanged), and three versions of one file
  then coexist on the surface, ordered only by recency. If the harness needs the model to know,
  the harness must append it.
