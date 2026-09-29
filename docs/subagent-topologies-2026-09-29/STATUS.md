# Subagent topologies — status

Parent commit: `9dc9c90f` (branch `improve-sub-agents`). enola baseline pinned before the first edit.
`TopologySpec::MET` in `test/support/topology_spec.rb` is the record for P, V and N.
Real-model results and the development-set tuning are in [FINDINGS.md](FINDINGS.md).

| Row | Status | First failing line at the parent |
|---|---|---|
| P1–P7 | **met** (T2) | was: `Error: the brief must be a non-empty string`. P2 proven discriminating: with `call_many` made sequential the overlap latch times out |
| V1–V3 | **met** (T3) | was: `the child never ran` |
| N1–N4 | **met** (T4) | was: `delegate_nudge.md` does not exist |
| H1–H4 | **met** (T1) | `rake agenteval:topologies:prove`; `test/agenteval_topology_pack_test.rb` |
| H5 | **met** (T3) | `Record.read` over a real fan-out + review session |
| R0–R5 | **run** (T6) | [FINDINGS.md](FINDINGS.md): R0, R1 and the fan-out half of R5 met; R2, R3, R4 and the review half of R5 are findings |

## Rounds

| Round | Content | State |
|---|---|---|
| T0 | design, bar, offline spec red at the parent | done |
| T1 | hard pack HA1–HA6, grep_agent and topology controls, validator (H1–H5) | done. Review found one regex classified both surveys and the grep control could not fail; the survey generator, grep policies, HA1/HA4 depth, report fields, `redundant_fanout`, `unread_review`, held-out prove and the survey scope check were fixed before commit. H3 amended from 4× to 2× the 32K window (fan-out children must each fit) |
| T2 | fan-out (P1–P7) | done. Cross-gem addition (owner to note): `Tamoz::Graph::Compiled#call_many` / `SubgraphRuntime#call_many` reserve call indexes in input order before running children concurrently, so a re-run node pairs each brief with its own stored child; `test/graph_subgraph_fanout_test.rb` |
| T3+T4 | review role (V1–V3) and delegation notes (N1–N4), one commit: they share the delegation and session-work files | done |
| T5 | done: baseline 48 trials (R0 0.25), tuning (`nudge_reads` 12→6, directive note, review trigger), tuned recheck 16 trials (R0 0.75) |
| T6 | done: held-out seeds 3–4, repeat 1; R0 met, R2/R3/R4 and the review half of R5 are findings ([FINDINGS.md](FINDINGS.md)) |
