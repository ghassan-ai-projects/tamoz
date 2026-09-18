# Coding — measurement plan

**Now:** graded eval (`agenteval/`), five controls discriminate, `pass^k`/interval/stage/cost
landed. One committed baseline exists but is a framework diagnostic: the plan-review gate aborted
28/46 trials before any edit.

**Unknown:** the real coding solve-rate — because the agent mostly never acts.

**Prereq / owner decision:** resolve the plan-gate blocker (config vs product) using the landed
stage/transcript. Reconfigure so the agent can act, or accept the gate as the finding. A live run
before this measures the gate, not coding.

**Measure (real model):**
1. `AGENTEVAL_SEEDS=4 AGENTEVAL_REPEAT=2 DEEPSEEK_API_KEY=… bundle exec rake agenteval:run`
2. `rake agenteval:compare` against the committed baseline; `rake agenteval:baseline` to promote.
3. Read `pass^k` + Wilson interval, split by acting/inaction cells and by stage.

**Done:** a real solve-rate with its interval, over an agent that actually acts, beside the noise
floor ([12? see master S3]); every trial carries a stage and a cost.
