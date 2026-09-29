# Subagent topologies — status

Parent commit: `9dc9c90f` (branch `improve-sub-agents`). enola baseline pinned before the first edit.
`TopologySpec::MET` in `test/support/topology_spec.rb` is the record for P, V and N.

| Row | Status | First failing line at the parent |
|---|---|---|
| P1–P7 | **met** (T2) | was: `Error: the brief must be a non-empty string`. P2 proven discriminating: with `call_many` made sequential the overlap latch times out |
| V1–V3 | pending | no `review` role: `the child never ran` |
| N1–N3 | pending | `delegate_nudge.md` does not exist |
| H1–H4 | **met** (T1) | `rake agenteval:topologies:prove`; `test/agenteval_topology_pack_test.rb` |
| H5 | pending | needs a real fan-out and review session (T2, T3) |
| N4 | not written | T4 |
| R0–R5 | not run | T6 |

## Rounds

| Round | Content | State |
|---|---|---|
| T0 | design, bar, offline spec red at the parent | done |
| T1 | hard pack HA1–HA6, grep_agent and topology controls, validator (H1–H5) | done. Review found one regex classified both surveys and the grep control could not fail; the survey generator, grep policies, HA1/HA4 depth, report fields, `redundant_fanout`, `unread_review`, held-out prove and the survey scope check were fixed before commit. H3 amended from 4× to 2× the 32K window (fan-out children must each fit) |
| T2 | fan-out (P1–P7) | done. Cross-gem addition (owner to note): `Tamoz::Graph::Compiled#call_many` / `SubgraphRuntime#call_many` reserve call indexes in input order before running children concurrently, so a re-run node pairs each brief with its own stored child; `test/graph_subgraph_fanout_test.rb` |
| T3 | review role (V1–V3) | |
| T4 | delegation notes (N1–N4) | |
| T5 | development-set real runs on seeds 1–2; tune guidance (labelled) | |
| T6 | held-out real run on seeds 3–4; findings (R0–R5) | |
