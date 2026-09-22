# Skills — measurement plan

**Now:** behavior/adversarial tests (`agent_skills*_test`, toolbox, memory) + a contract case
(`m0/09_skill-capability-containment`). Containment and authority are tested; skill *selection and
use* competence is not graded.

**Unknown:** given a real model, does the agent pick the right skill for a task, apply it
correctly, and stay inside the skill's capability grant — versus the tests only proving a skill
cannot widen authority.

**Measure (real model):**
1. A graded skill task set: tasks solvable only by selecting+applying the correct skill, scored on
   outcome, with controls — null (invokes no skill / wrong skill) must fail; oracle (correct
   skill) passes; adversary (a skill attempting to widen authority or reach outside its grant)
   must trip the containment gate.
2. Run with the real provider, `repeat>=2, seeds>=4`, `pass^k` + interval.

**Prereqs:** the graded skill task set + its controls (build offline); real provider.

**Done:** a real skill-competence rate + interval, with a passing containment control shown; the
containment guarantee stays green under a real model.
