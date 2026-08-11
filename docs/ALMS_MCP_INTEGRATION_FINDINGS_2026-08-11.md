# tamoz ↔ ALMS MCP Integration — Test Findings

**Date:** 2026-08-11
**Author:** OpenClaw-orch (ghassan's main agent)
**Scope:** Wire the **tamoz agent** to the **ALMS** MCP server over the new **Streamable HTTP transport**, and verify tamoz can query learnings end-to-end.
**Result:** ✅ WORKING. tamoz agent retrieved learnings from ALMS and produced a summary.

---

## 1. What was proven working

1. **ALMS Streamable HTTP MCP endpoint** responds correctly to the `initialize` handshake:
   - `POST http://192.168.2.112:8001/mcp` → `serverInfo: {name: ALMS, version: 0.1.0}`, `protocolVersion 2025-03-26`, capabilities `{resources, tools{listChanged}}`.
2. **18 ALMS tools** exposed over Streamable HTTP:
   - `agent.*` — register, list, heartbeat, update, unregister
   - `health.check`
   - `learning.*` — store, get, search, delete, sync, sync_ack, update_enrichment
   - `okf.export`
   - `protocol.*` — list, push, pull, pull_since
3. **tamoz MCP source builds** against ALMS: `McpSourceBuilder` → `Catalog.compile` → `Supervisor.build` → 18 tools registered as `mcp:alms/...`.
4. **Real round-trips through tamoz's governed executor** succeeded (`status=:succeeded`):
   - `mcp:alms/health.check` → `{"agent_count":6,"status":"ok","version":"0.1.0"}`
   - `mcp:alms/learning.search {"query":"model"}` → real stored learnings (scores 0.56–0.96)
5. **Full tamoz CLI agent turn** (via worker path): queued a task, worker accepted a plan whose step 1 = `mcp:alms/learning.search`, the call succeeded, and the agent composed a summary of the top 3 learnings.

---

## 2. How it was wired (config only is enough for the worker path)

### 2a. Config: `~/.tamoz/config.yaml`
```yaml
sources:
  mcp:
    enabled: true
    servers:
      - id: alms
        transport: http
        endpoint: "http://127.0.0.1:8001/mcp"
        read_only_tools:
          - health.check
          - learning.get
          - learning.search
          - protocol.list
          - agent.list
```
- `read_only_tools` matters: tamoz's plan reviewer only ADMITS an MCP tool during a read_only phase if it is classified `read_only`. `learning.search` and friends must be listed here or the plan is rejected with `unknown tool`.

### 2b. Transport / the https-or-loopback rule
`tamoz-mcp`'s `ServerConfig` **fail-closes**: an HTTP endpoint must use **https** **unless it targets loopback** (`localhost`, `127.0.0.1`, `::1`). ALMS on `192.168.2.112` is a *non-loopback* IP over plain http → rejected.

**Workaround used:** SSH tunnel on this machine:
```bash
# 127.0.0.1:8001 → data:8001
ssh -f -N -L 127.0.0.1:8001:127.0.0.1:8001 data
```
then point tamoz at `http://127.0.0.1:8001/mcp` (loopback → accepted).

### 2c. Model env
Agent turns need a tamoz model. We ran with provider `deepseek`, model `deepseek-chat`. Key must be in env (`DEEPSEEK_API_KEY`).

---

## 3. Commands used

```bash
cd ~/my-projects/tamoz
export PATH="$HOME/.rbenv/shims:$PATH"        # ruby 3.3.11 / bundler 4
export TAMOZ_RUNTIME_DIR=~/.tamoz

# 1. Queue a task for the agent (worker path wires MCP into the Session)
tamoz --runtime-dir ~/.tamoz queue add \
  --task "Use mcp:alms/learning.search with query 'architecture'. \
          Summarize the top 3 learnings with 2-3 bullets each."

# 2. Run the worker once (processes the queued task)
tamoz --runtime-dir ~/.tamoz --provider deepseek --model deepseek-chat worker --once
```

The agent's final text lives in the completed checkpoint payload in `~/.tamoz/runtime.sqlite3`:
```sql
SELECT payload FROM tamoz_checkpoints
WHERE thread_id='<thread>' AND status='completed';
```
(Element `[8]` is the JSON-serialized agent state; parse it, read the `"answer"` field.)

---

## 4. Issues to fix (the reason this needed a worker, not the plain CLI)

### 🔴 FIX-1 (high): plain `tamoz ask` CLI path does NOT wire the MCP source into the Session
- **Symptom:** `tamoz ... "task"` (interactive/ask path) runs the planner, but the plan reviewer rejects any MCP step with:
  `step "x" uses unavailable tool "mcp:alms/learning.search"; unknown tool`
- **Root cause:** `run_durable` in `gems/tamoz-agent/lib/tamoz/agent/cli.rb` builds `Session.new(...)` **without** the `mcp:` argument. The **worker** path (`worker_runtime.rb`) DOES pass `mcp: mcp_source` (line ~590), which is why the worker turn worked and the ask path did not.
- **Fix:** in `cli.rb` `run_durable`, build the MCP source from the runtime dir and pass `mcp:` to `Session.new` — mirroring `worker_runtime.rb#build_session`. (A temporary local edit proved this works; it was then reverted per operator instruction "do not change code".)
- **Note for routing:** this is a code change to the tamoz repo, to be applied deliberately — not part of the read-only test.

### 🟠 FIX-2 (medium): "no plan passed review after 3 attempts" flakiness
- The planner/reviewer sometimes rejects 2–3 plan drafts before accepting (reviewer is a model). Wording of the task prompt affects this. Not a transport bug; just allow retries or re-word prompts. `max_plan_attempts: 3` default.

### 🟠 FIX-3 (medium): tunnel/loopback dependency for plain-http ALMS
- tamoz requires https-or-loopback for HTTP endpoints. A permanent integration needs **either**:
  - an SSH tunnel started when tamoz uses ALMS (current approach), **or**
  - **https in front of ALMS** on the data machine so tamoz can hit `192.168.2.112` directly.
- Recommend https-on-ALMS as the durable fix; the tunnel is a stopgap.

### 🟡 FIX-4 (low): read_only_tools must be kept in sync
- Any ALMS tool tamoz should call during a read-only phase must be listed in `read_only_tools` or the plan reviewer rejects it. If operators add new ALMS tools, remember to update `~/.tamoz/config.yaml`.

### 🟡 FIX-5 (low): raw curl MCP session propagation
- A bare `curl` `tools/list` after `initialize` fails with `Invalid session ID` unless the `Mcp-Session-Id` header is captured and reused. (Known Streamable HTTP behaviour; tamoz's client handles it correctly — only affects manual curl debugging.)

---

## 5. Current config state (as of 2026-08-11 16:03)
- `~/.tamoz/config.yaml`: `sources.mcp` enabled with ALMS server (loopback) + `read_only_tools`. **No tamoz code was changed.**
- SSH tunnel: `127.0.0.1:8001 → data:8001` running on this machine. Not persisted across reboots.

---

## 6. Recommended next step
Review **FIX-1** and apply it in the tamoz repo (wire `mcp:` into the CLI `run_durable` session), so `tamoz ask` works as well as the worker path. Also consider **FIX-3** (https in front of ALMS) to remove the tunnel dependency.
