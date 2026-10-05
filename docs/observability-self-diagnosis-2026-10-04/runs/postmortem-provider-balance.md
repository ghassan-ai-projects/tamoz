# Postmortem: Model calls refused: provider balance

Window: 2026-10-03T15:27:20Z → 2026-10-04T15:27:20Z · generated 2026-10-04T15:27:20Z

Blameless; assembled read-only from the durable record. Proposed actions are never executed.

## Impact

- Failed turns: 0
- Threads with failures: thread.noise.5
- Findings by severity: high 2

## Analysis (the attached findings report; this command does not verify it)

**Summary:** The runtime's own record over the last 24h shows 6 turns requested and completed, 35 effect attempts (30 succeeded, 5 failed). Four of the five failures are the same model call failing repeatedly in thread.noise.5, and the self-diagnosis rule effect.repeated_failure fired at high severity on exactly that group. The workspace is empty, so the record is the only evidence.

**Hypothesis (high):** The root cause is the model provider rejecting calls for non-payment: every failing model.generate.plan attempt carries error class Tamoz::Agent::ModelCallError with code insufficient_balance and reason "402 Payment Required: the account balance is empty". The exact error code identifying the root cause is insufficient_balance (class Tamoz::Agent::ModelCallError, rule effect.repeated_failure). The single tool.read_file failure (code not_found, "notes.md does not exist") is a separate, unrelated one-off and not the cause.

- Four model.generate.plan effect attempts failed in thread.noise.5 with the identical failure: class Tamoz::Agent::ModelCallError, code insufficient_balance, reason '402 Payment Required: the account balance is empty'. [call-af411c37-bf7d-4f98-b04d-8ab726f85bd8, call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71, call-169bc01d-3bfa-4db1-949b-3109a8236ae1]
- The self-diagnosis rule effect.repeated_failure fired at severity high, category dependency_unavailable, count 4, first_seen 1791125835197 and last_seen 1791125835201, with detail failure 'Tamoz::Agent::ModelCallError/insufficient_balance'. [call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71, call-4aeb3d16-5558-40ff-aee8-588aaca5d5bf]
- The failures are confined to thread.noise.5; threads noise.0 through noise.4 each requested and completed a turn without a model failure, and the runtime reports 6/6 requests completed with no degraded sources. [call-af411c37-bf7d-4f98-b04d-8ab726f85bd8, call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71]
- A fifth, distinct failure occurred in the same thread: tool.read_file failed with class Tamoz::Agent::ToolError, code not_found, reason 'notes.md does not exist' — a one-off missing-file error, not part of the repeated group. [call-af411c37-bf7d-4f98-b04d-8ab726f85bd8, call-169bc01d-3bfa-4db1-949b-3109a8236ae1]
- The failing model calls are idempotent effects that each failed on attempt 1 with duration 0-1 ms, consistent with an immediate provider-side rejection rather than a timeout or retry exhaustion. [call-169bc01d-3bfa-4db1-949b-3109a8236ae1, call-a3c7e1f9-deda-42c4-adc7-5c26922e0a71]

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

**Action:** One failed model call ends the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).

- `effect_attempts` `sha256:6b5f1a06739e0756a0ca80311473543652496a3e37467a35725e2cae2b678fe6#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:47da65c43e58aef0b0f8e63b04b7e058125def876cdafa712a5b4160997bc741#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:f37cd3c8dfd3f6beb3395e3c04ca63604241e9dd9b5f39cad0e57ed201ed123b#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance
- `effect_attempts` `sha256:26fd998ea674d71ec786f1b263a8466a84e9a659378223bb6b343cd512013d0a#1` — model.generate.plan · failed · Tamoz::Agent::ModelCallError · insufficient_balance

## Unknowns

None.

## Proposed actions (not executed)

- One error class and code keeps recurring; fix that cause once instead of retrying the calls.
- One failed model call ends the turn that made it; check the error code (a refused key, an empty account or a rate limit is a provider problem, not a Tamoz bug).
