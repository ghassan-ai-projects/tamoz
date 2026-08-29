# ADR relationships

Supersession and amendment edges between ADRs, generated from
[`catalog.json`](./catalog.json) by `script/adr_graph.rb` (`rake adr:graph`). An arrow
points from a decision to the ADR that replaced or amended it. Retired decisions are
marked; everything not shown here stands on its own.

```mermaid
graph LR
  A002["ADR-002<br/>Four v0.1 runtime gems"]:::retired
  A003["ADR-003<br/>Reuse RubyLLM public values"]:::retired
  A012["ADR-012<br/>MCP is a deferred integration stra"]:::retired
  A029["ADR-029<br/>MCP is native at the edge and uses"]
  A030["ADR-030<br/>One local capability catalog gover"]
  A035["ADR-035<br/>Streaming input is a distinct firs"]
  A037["ADR-037<br/>Event time, explicit backpressure,"]
  A040["ADR-040<br/>One monorepo, multiple independent"]
  A043["ADR-043<br/>Telegram v1 is deny-only and refer"]
  A048["ADR-048<br/>One digest-bound OpenAI-compatible"]
  A049["ADR-049<br/>Telegram approval is evidence-gate"]
  A051["ADR-051<br/>RubyLLM is removed from the runtim"]
  A052["ADR-052<br/>tamoz-agent is decomposed into foc"]
  A054["ADR-054<br/>Websearch is the fourth capability"]
  A055["ADR-055<br/>The continuous plane is a separate"]
  A002 -->|superseded by| A052
  A003 -->|superseded by| A048
  A003 -->|superseded by| A051
  A012 -->|superseded by| A029
  A030 -.->|amended by| A054
  A035 -.->|amended by| A055
  A037 -.->|amended by| A055
  A040 -.->|amended by| A052
  A043 -.->|amended by| A049
  A048 -.->|amended by| A051
  classDef retired fill:#eee,stroke:#999,color:#666,stroke-dasharray:3 3;
```

Solid = superseded (no longer in force). Dashed = amended/extended/revised (still in
force, refined by a later ADR). Full history: [`RETIRED.md`](./RETIRED.md).

## Next reads

- [`README.md`](./README.md) — the ADR catalog and its amendment-chain list
- [`catalog.json`](./catalog.json) — the machine-readable edges
