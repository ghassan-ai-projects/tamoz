# Manual Intelligence Test Report — 2026-08-11

> Historical intelligence report. Its provider and adapter references describe
> the implementation tested on 2026-08-11, not current Tamoz production support.

Date: 2026-08-11 (Europe/Berlin)
Run by: manual / OpenClaw orchestration against a local checkout
Branch/HEAD: current working tree (commits through `4d7aff9` "Refresh autonomy scorecard evidence")

Status legend:
- ✅ PASS — behaved correctly / capability worked
- ⚠️ PARTIAL — worked with caveats, or failed safe in a way worth noting
- ❌ FAIL — capability did not deliver, or hit a defect

---

## Test 1 — Read-only technical review (file-grounding)

**Task:** One-shot CLI, `--root` = `~/ai-projects/articles/ready/ART-040-film-pipeline-open-source`,
review `article.md` + cross-check `build_html.py` for consistency; produce summary, strongest/weakest
decision, consistency verdict, two improvements. No `--allow-changes`.

**Invocation (works):**
```bash
export TAMOZ_PROVIDER=deepseek TAMOZ_MODEL=deepseek-v4-flash
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
rbenv exec bundle exec tamoz --root <article-dir> "<prompt>"
```

**Result: ✅ PASS.** Completed the full loop: discovery plan → dual review (structural + semantic) accepted →
read-only execution (`read_file`, `search_text`) → self-verification. Produced a genuinely file-grounded
critique that:
- Quoted exact source lines (`build_html.py:10` hardcodes Meta instead of parsing from `article.md`).
- Caught a real defect: hand-rolled `md_to_html` has NO handling for `- ` bullet lines, so lists fall
  through to generic `<p>` and lose `<ul>/<li>` semantics.
- Correctly diagnosed the one-way `md->html` relationship as a silent-drift risk, with a CI
  regenerate-and-diff recommendation.
- Governed end-to-end, no unplanned actions.

---

## Test 2 — Internet validation / truthful refusal

**Task:** Verify a contested factual claim ("DeepSeek-V4 released Aug 2026, 150K context") using the
web, and EXPLICITLY refuse if it cannot access the internet (no guessing).

**Result: ✅ PASS (honest refusal).** The agent:
- Plan 1 searched the local workspace for evidence; the **semantic reviewer correctly rejected it**
  (local files cannot verify current internet facts).
- Plan 2 revised: confirmed no web/search/fetch tool exists in the toolset, committed to reporting honestly.
- Final output: explicitly stated it had no web search/fetch tool, therefore could not verify the claim,
  and **declined to guess or invent an answer**.

No hallucination. Capability boundary surfaced truthfully. This exercised the "report verified partial
progress truthfully" behavior.

**Important capability note:** the agent toolset is **filesystem-only**:
`read_file, list_directory, search_text, apply_patch, create_file, run_check, load_skill, read_skill_resource`.
A governed `websearch` MCP capability ships in `tamoz-mcp` (SSRF-pinned egress), but is **not enabled**
in runtime config (`sources: {}`). So tamoz cannot currently validate internet data end-to-end — this
was an honest-refusal test, not a successful-fetch test.

---

## Test 3 — Write / mutate files (`--allow-changes`)

**Task A (multi-file, vague):** add a completed task to `todo.md` + a line to `notes.md`, read back to confirm.

**Result: ❌ FAIL — plan review loop exhausted.**
```
tamoz: no plan passed review after 3 attempts: the plan did not pass review
```
Three drafted plans in a row were rejected at review (mostly the *semantic* stage), despite the plans
being reasonable (read state → apply_patch → read back). The runner gave up at the 3-attempt cap.
Failed **closed** (no partial edits, no destructive action — safety worked). But the "do something real"
capability did not deliver on this task shape.

**Task B (single, precise file append):** append `- [x] release script` to `todo.md`.
Used `apply_patch`, read back to confirm.

**Result: ⚠️ PARTIAL — pipeline works, needs approval.**
- Discovery plan accepted; action plan accepted.
- Stopped correctly at the **approval gate** and showed the exact patch diff:
```
--- a/todo.md
+++ b/todo.md
@@ -3,1 +3,2 @@
-- [ ] write release script
+- [ ] write release script
+- [x] release script
Approve apply_patch? [y/N]
```
- No approval was provided (non-interactive background stdin → `approval denied`), so the file was not
  written. The plan→review→patch→approval pipeline itself functioned correctly on a precise task.

**Observation for the fixing agent:** the difference between Task A (failed at plan review) and Task B
(accepted) suggests the plan/review loop is overly strict or non-deterministic on slightly more complex /
multi-step change tasks. Worth investigating why valid multi-step write plans get blanket semantic
`revise` without an actionable reason (final feedback is logged as "not discloseable").

---

## Test 4 — Telegram channel (end-to-end diagnostic, not completed)

**Goal:** drive a durable turn through the `telegram-ops` channel (gateway `comms serve` + `worker --json`).

**Result: ❌ BLOCKED on configuration/integration issues, not run to completion.**

Findings during bring-up:
1. **Token name mismatch:** `tamoz/.env` holds `TELEGRAM_BOT_TOKEN`, but `~/.tamoz/config.yaml` references
   `TAMOZ_TELEGRAM_BOT_TOKEN`. The token must be exported under the config's expected name (or config changed).
2. **Bot ID mismatch (fixed during test, not a code bug):** the `.env` token authenticates bot **8724435334**
   (`@tamoz_agent_bot`, verified via `getMe`), but config declared `expected_bot_id: 8556932567`. `comms doctor`
   correctly refused (anti token-swap invariant): `token authenticates bot 8724435334, config expects 8556932567`.
   Manual action (user-approved): updated config to `expected_bot_id: 8724435334` → doctor then PASSED all checks
   (runtime permissions, token, adapter, tls, bot id, webhook, poller).
3. **Profile activation error (BLOCKER):** `worker --json` failed every turn with:
   ```
   Tamoz::Agent::Profile::ValidationError: ~/.tamoz/profiles/ops.yaml is inside .tamoz/ and is evidence only;
   preview or import it instead of activating it
   ```
   A profile file under the `.tamoz/` runtime directory is treated by tamoz as **evidence-only** and refused at
   activation. The *activated* `ops` profile lives at the macOS platform config dir
   `~/Library/Application Support/tamoz/profiles/ops.yaml` (same digest `sha256:aaa8…`, bytes identical), already
   listed in that dir's `adoption.yaml`. The worker launched with `--runtime-dir ~/.tamoz` resolves the channel's
   `profile: ops` to the evidence-only `.tamoz/` copy and refuses.

**Needs resolution before the Telegram flow can be tested end-to-end:** reconcile the runtime directory vs the
platform config dir so the worker activates the correct (non-evidence) `ops` profile, then bring up gateway +
worker and exercise a durable message turn.

---

## Test 5 — MCP capability (❌ blocked by a code defect)

**Setup:** fresh runtime dir `/tmp/tamoz-mcp-rt` with schema-valid config enabling the MCP source pointing at
tamoz's own `script/mcp_test_server` (SDK-built, tools: `echo_constant, set_answer, needs_input, churn,
sleep_ms, search`), plus the `ops` profile. Verified the MCP server subprocess responds correctly to
`initialize` over stdio (capabilities advertised, `tamoz-mcp-test-server` v0.1.0).

**Result: ❌ FAIL — crashes during MCP source build, before any tool call.**
Every `queue`/worker-path command that builds the MCP source crashes with an unhandled **NameError**:
```
gems/tamoz-agent/lib/tamoz/agent/mcp_source_builder.rb:151:in `rescue in config_for':
  uninitialized constant Tamoz::Mcp::ValidationError (NameError)
```
Full trace: `config_for` (line 129) → `block in mcp_servers` (118) → `mcp_servers` (108) → `server_configs` (99)
→ `build` (47).

**Root cause for the fixing agent:**
- `mcp_source_builder.rb:151` references the constant `Tamoz::Mcp::ValidationError` in a `rescue` clause.
- `Tamoz::Mcp::ValidationError` IS defined in `gems/tamoz-mcp/lib/tamoz/mcp/errors.rb` (loaded by `require
  "tamoz/mcp"`), and `tamoz/mcp` is required in `McpSourceBuilder#build` before `server_configs` runs.
- Nevertheless the constant is not resolvable at rescue-evaluation time, throwing `NameError` *from inside the
  rescue clause*, which escapes and masks the original validation error.
- Likely a load-order / require-chain / constant-resolution problem in the agent gem's MCP wiring. The `rescue`
  bare-constant reference may need the same load guard as the rest of the build, or the class needs to be
  surfaced through the agent's require path before `config_for` is evaluated.

**What works independently (already verified):**
- `script/mcp_test_server` subprocess is healthy and speaks MCP correctly.
- Runtime-dir config with the MCP source is schema-valid (it passes config validation and reaches the MCP build).
- MCP is genuinely wired into the worker path: `worker_runtime.rb` builds `McpSourceBuilder`. The one-shot CLI
  does **not** expose MCP (MCP is worker/durable-path only).

---

## Environment / setup notes (reproducibility)

All manual runs used:
```bash
rbenv exec bundle exec tamoz ...          # bundler-resolved, from repo root
export TAMOZ_PROVIDER=deepseek
export TAMOZ_MODEL=deepseek-v4-flash      # CLI defaults to openai and fails without a model/provider
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8  # RubyLLM crashes parsing its models.json under C/ASCII locale
```
- The CLI requires a model/provider (`missing argument: --model or TAMOZ_MODEL` otherwise).
- Under the default C/ASCII locale RubyLLM fails with `Encoding::InvalidByteSequenceError` while parsing its
  bundled `models.json` (contains non-ASCII); setting UTF-8 locale resolves it. Env/config concern, not an
  agent-behavior bug.

## Priority findings for the fixing agent

1. **P1 — MCP build crashes (Test 5):** `uninitialized constant Tamoz::Mcp::ValidationError` at
   `mcp_source_builder.rb:151`. Blocks ALL MCP usage. Load-order / constant-resolution defect.
2. **P2 — effective-change unreliable on multi-step write tasks (Test 3A):** valid multi-file `--allow-changes`
   plans repeatedly rejected at review (semantic `revise`) with no actionable/`not discloseable` feedback, until
   the 3-attempt cap. Single precise tasks (3B) pass. Plan-review loop likely too strict / non-deterministic on
   multi-step changes.
3. **P2 — Telegram end-to-end blocked by profile/dir resolution (Test 4):** `profiles/ops.yaml` under `.tamoz/`
   is evidence-only and refused at activation; the activated copy lives in the platform config dir
   (`~/Library/Application Support/tamoz/profiles`). Worker launched with `--runtime-dir ~/.tamoz` resolves the
   channel profile to the evidence-only copy. Needs a defined relationship between runtime dir and config dir for
   profile activation in worker mode.
4. **P3 — internet validation not reachable (Test 2):** websearch MCP capability ships but is not enabled
   (`sources: {}`); tamoz tools are filesystem-only. Honest refusal works; live-fetch validation requires enabling
   the websearch source.
5. **P3 — model/provider + locale env gates:** document the `TAMOZ_PROVIDER/TAMOZ_MODEL` requirement and the
   UTF-8 locale requirement for CLI use.

---

# Post-Fix Re-Test — 2026-08-11 (14:33 CEST)

The coding agent remediated every priority finding. HEAD at re-test: `2fdc159`
("Document Tamoz MCP and websearch operations"). Fix commits reviewed:

- `7cb8771` Fix MCP configuration validation loading  (P1)
- `1d7e64d` Allow profiles in dot tamoz runtimes        (P2 Telegram)
- `7a85930` Improve multi-file plan review context       (P2 write)
- `ab8fa78` Make model loading locale safe               (P3 env)
- `1f07a94` Preserve suggestion isolation for runtime profiles

## Re-Test 1 — Read-only review (sanity): ✅ PASS

Same invocation as before (one-shot CLI, `--root` to article dir). Discovery plan
accepted, read `article.md`, returned a precise summary + top risk. Unchanged
from pre-fix behavior; no regression.

## Re-Test 3 — Multi-file write / mutate: ✅ PASS (fix verified)

Re-ran the exact multi-file task that previously failed (3 attempts rejected at
review). After the fix:
- Discovery plan **accepted** by both structural AND semantic review.
- Action plan (two `apply_patch` edits + two read-back verifications) **accepted**.
- Applied patch #1 to `todo.md` (`- [x] Release script` committed to disk,
  confirmed).
- Stopped at the second approval gate (needs one `y` per patch in unattended
  stdin); the approval gate itself behaved correctly.

Root-cause fix works: valid multi-file change plans now get actionable semantic
approval instead of an opaque 3-attempt `revise` loop.

## Re-Test 5 — MCP capability: ✅ PASS at build (P1 fixed)

- The `NameError` crash on MCP source build is **gone**. `queue list` against the
  MCP-enabled runtime now returns `No pending work.` instead of
  `uninitialized constant Tamoz::Mcp::ValidationError`.
- Dedicated regression test passes: `test/agent_worker_mcp_test.rb` —
  **9 runs, 30 assertions, 0 failures, 0 errors**.
- The fix (`require "tamoz/mcp"` hoisted to the top of `McpSourceBuilder#build`,
  before `config_for`) resolves the constant-loading defect.

**Note / not a code defect:** a full edge-to-edge MCP *invocation* through the
worker path was not completed because the `ops` test profile pins a `policy.
tool_catalog_digest` (`4a44f855…`) that no longer matches the current toolbox
catalog (`6b78e9ea…`, which changed once MCP tools are in scope). Rebinding the
profile digest to the live catalog is required before a queued MCP task will be
accepted by `queue add`. This is expected profile-pinning behavior, not a code
failure.

## Re-Test 4 — Telegram worker profile: ✅ FIXED (P2)

- `1d7e64d` changes `Profile.suggestion_path?` so a profile at
  `~/.tamoz/profiles/ops.yaml` is treated as a valid operator runtime profile
  (only the reserved suggestion basename stays evidence-only), instead of the
t
  previous over-broad rejection of any path under `.tamoz/`.
- Associated tests pass: `test/agent_profile_test.rb` —
  **43 runs, 124 assertions, 0 failures**.

## Env / locale gate: ✅ FIXED (P3)

- `ab8fa78` sets `Encoding.default_external = UTF-8` before requiring RubyLLM so
  its bundled `models.json` parses under a C/ASCII locale.
- `test/agent_ruby_llm_model_test.rb` — **3 runs, 12 assertions, 0 failures**.
- Interaction manual updated in `docs/INSTALL.md` (explicit `TAMOZ_PROVIDER` +
  `TAMOZ_MODEL` usage, and the websearch-off-by-default note).

## Residual items for the fixing agent (non-blocking)

- Profile `tool_catalog_digest` rebinding when MCP sources are added to a runtime
  (the `ops` profile used for testing still pins the pre-MCP digest). Not a code
  bug — confirm the documented flow for refreshing a pinned profile after adding
  an MCP source.
- Full end-to-end MCP invocation (exit the queue as the last unknown) still needs
  that rebind before it can be exercised live.

---

## Remediation loop — 2026-08-11

The findings above were reproduced against the implementation and addressed in
small, committed slices:

| Finding | Remediation | Evidence |
|---|---|---|
| MCP validation crash | Load `tamoz/mcp` before configuration validation so the typed validation error is available; added a regression for invalid server configuration. | `7cb8771`; `test/agent_worker_mcp_test.rb` — 9 runs, 30 assertions |
| Multi-file write plans | The planner and reviewer now receive the effective tool surface and explicit discovery/action rules. Bounded multi-file plans and read-back verification are explicitly valid; mutation approval semantics remain unchanged. | `7a85930`; `test/agent_runtime_test.rb` — 11 runs, 52 assertions |
| Telegram profile resolution | Runtime profiles are trusted when they live under the configured operator profile root, even when the runtime directory is named `.tamoz`; repository suggestion paths remain evidence-only. | `1d7e64`, `1f07a94`; profile and CLI profile suites pass |
| C-locale model startup | Tamoz normalizes RubyLLM's external encoding to UTF-8 before loading its bundled model registry. | `ab8fa78`; C-locale subprocess regression passes |
| Websearch availability | Kept websearch opt-in. Installation docs now state that disabled websearch means filesystem-only evidence and truthful refusal for current internet facts. | `ab8fa78`; documentation suite passes |

Focused verification after the loop: runtime, durable session, routing, MCP,
profile, CLI profile, RubyLLM, and documentation suites all passed. `enola check`
also passed with no structural regression. The Telegram network round-trip still
requires the operator's real token, bot id, allowlist, and foreground gateway;
those are deployment prerequisites rather than code changes performed here.

### Final gate verification

The full repository gate now passes under both required locales after two
additional consistency fixes:

| Locale | Result |
|---|---|
| `LC_ALL=C LANG=C` | 1,627 tests, 40,877 assertions, 0 failures, 0 errors |
| `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8` | 1,627 tests, 40,877 assertions, 0 failures, 0 errors |

Additional fixes:

- `8f684ee` aligned the independent SQLite oracle with `MIGRATION_8` and
  regenerated the requirements manifest and audit (`433` requirements,
  `402` passing named cases, `16` documented release gaps).
- `1ce1ebc` made the MCP source-structure audit explicitly read UTF-8, removing
  its C-locale `US-ASCII` error.

The earlier setup note about RubyLLM failing under the C locale is historical;
`ab8fa78` closes that failure and both complete locale gates now pass.
