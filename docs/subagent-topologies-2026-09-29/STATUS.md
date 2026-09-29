# Subagent topologies — status

Parent commit: `9dc9c90f` (branch `improve-sub-agents`). enola baseline pinned before the first edit.
`TopologySpec::MET` in `test/support/topology_spec.rb` is the record for P, V and N.

| Row | Status | First failing line at the parent |
|---|---|---|
| P1–P7 | pending | fan-out does not exist: `Error: the brief must be a non-empty string` |
| V1–V3 | pending | no `review` role: `the child never ran` |
| N1–N3 | pending | `delegate_nudge.md` does not exist |
| H1–H5, N4 | not written | T1 (pack) and T4 (notes) |
| R0–R5 | not run | T6 |

## Rounds

| Round | Content | State |
|---|---|---|
| T0 | design, bar, offline spec red at the parent | done |
| T1 | hard pack HA1–HA6, grep_agent and topology controls, validator (H1–H5) | |
| T2 | fan-out (P1–P7) | |
| T3 | review role (V1–V3) | |
| T4 | delegation notes (N1–N4) | |
| T5 | development-set real runs on seeds 1–2; tune guidance (labelled) | |
| T6 | held-out real run on seeds 3–4; findings (R0–R5) | |
