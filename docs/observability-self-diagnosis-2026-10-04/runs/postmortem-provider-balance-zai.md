# Postmortem: Model calls refused: provider balance

Window: 2026-10-03T19:35:55Z → 2026-10-04T19:35:55Z · generated 2026-10-04T19:35:55Z

Blameless; assembled read-only from the durable record. Proposed actions are never executed.

## Impact

- Failed turns: 0
- Threads with failures: thread.noise.5
- Findings by severity: high 2

## Analysis (the attached findings report; this command does not verify it)

**Summary:** Investigated the Tamoz runtime's durable record over the last 24 hours after a 4-hour lookback showed an empty recent window. All five effect failures in the record are concentrated in one turn (thread.noise.5) at ~1791125835196-1791125835202, about 4.6 hours before diagnosis: four model.generate.plan attempts failed with Tamoz::Agent::ModelCallError code insufficient_balance, and one tool.read_file attempt failed with ToolError code not_found. The runtime's own high-severity rules fired only on the balance failure.

**Hypothesis (high):** insufficient_balance

- The runtime's own rules fired twice with high severity on the same failure: rule effect.repeated_failure and rule model.call_failed, each count 4, category dependency_unavailable, detail Tamoz::Agent::ModelCallError/insufficient_balance. Both rules name a provider/account condition, not a Tamoz defect. [call_-7218248447135049513]
- Timeline inside thread.noise.5: three model.generate.plan successes and two tool.read_file successes at ~1791125835190-5195, then four consecutive model.generate.plan failures with code insufficient_balance at ~1791125835196-5200, all distinct effect keys, each a single attempt with duration 0 ms (refused immediately, no retries). The account crossed its balance threshold mid-burst: model calls worked until 5195 and every model call after 5196 failed. These are the last model calls in the record. [call_-7218248447135049512, call_-7218263805938099576]
- The only other error code in the window is ToolError/not_found: a single tool.read_file attempt at ~1791125835202 in the same thread, after the balance failures. It occurs once, fires no rule, and no other thread had any failure. It cannot explain four model calls failing with a balance code; it is best read as collateral of the planner losing the model (a path that was never produced) or an unrelated missing file. [call_-7218248447135049512, call_-7218263805938099576]
- Nothing else in the runtime is degraded: degraded=false, no worker-error occurrences, journal empty, and the sibling turns (thread.noise.0 through thread.noise.4) completed with all their effects succeeding. The failure is isolated to one thread at one instant, which matches a shared account hitting zero rather than a runtime fault. [call_-7218248447135049513, call_-7218263805938099575]
- A 240-minute lookback returned an empty timeline and empty summary even though rows exist; the 1440-minute lookback contains the incident. The burst is at 1791125835196 and diagnosis ran at 1791142396000, about 276 minutes earlier, so 'the last few hours' sits just outside the 4-hour window. [call_-7218296997445368582, call_-7218296997445368581, call_-7218248447135049512]
- Turn accounting is odd but secondary: thread.noise.5's request and final checkpoint are recorded completed at ~1791125835189, before the five failed effects at 5196-5202, and the turn outcome is 'completed' despite four failed planner effects. No attempt was retried, so there was no retry storm. [call_-7218263805938099576]

## Timeline

- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.0#request.d53a9484`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.0#request.d53a9484`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.1#request.9c624565`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.a8dcfc32`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.a8dcfc32`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.1#request.9c624565`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.2#request.d9b27000`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.0b288cd9`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.0b288cd9`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.2#request.d9b27000`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.3#request.14aeea98`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.8210bf4f`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.8210bf4f`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.3#request.14aeea98`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.4#request.8d415fce`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.a350b479`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.a350b479`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.4#request.8d415fce`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.aa225c6a`)
- 2026-10-04T14:57:15Z `durable` turn requested (`thread.noise.5#request.f8caebaf`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.aa225c6a`)
- 2026-10-04T14:57:15Z `durable` turn completed (`thread.noise.5#request.f8caebaf`)
- 2026-10-04T14:57:15Z `durable` write_file ask (`decision.165f90f2`)
- 2026-10-04T14:57:15Z `durable` write_file approve (`decision.165f90f2`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1`)
- 2026-10-04T14:57:15Z `durable` model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance (`sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1`)
- 2026-10-04T14:57:15Z `durable` tool.read_file failed — Tamoz::Agent::ToolError/not_found (`sha256:c5cda6aa674d4de60c4f8e317932dab581e66fa93fc4e602b4a9fa238aff4332#1`)

## Findings

### [high] The same failure is repeating (4)

Rule `effect.repeated_failure` · category `dependency_unavailable` · finding `sha256:8146d08bf5ca58b809f31da9796f7777b9a554472a1db3f61b9eeabe710cd0f5`  
Seen 2026-10-04T14:57:15Z → 2026-10-04T14:57:15Z

**Action:** One error class and code keeps recurring; fix that cause once instead of retrying the calls.

- `effect_attempts` `sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance

### [high] A model call failed (4)

Rule `model.call_failed` · category `dependency_unavailable` · finding `sha256:99be8bdd0b0664008aac074cce4b4b917fdba03769ffca2e0a98c6b251b6434f`  
Seen 2026-10-04T14:57:15Z → 2026-10-04T14:57:15Z

**Action:** A failed model call can end or degrade the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).

- `effect_attempts` `sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance

## Unknowns

None.

## Proposed actions (not executed)

- One error class and code keeps recurring; fix that cause once instead of retrying the calls.
- A failed model call can end or degrade the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).
