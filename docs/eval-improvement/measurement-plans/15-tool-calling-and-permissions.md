# Tool calling & permissions — measurement plan

Related but distinct. Enforcement (what the agent *cannot* do) is largely deterministic and well
tested; competence (does it use tools well and ask for approval at the right times) is unmeasured.

## 15a. Tool calling
**Now:** fail-closed guarantees — unknown tool → ask; malformed code/route rejected without a fake
plan; a hostile compile tree invokes no execution verb; apply-patch digest-bound and
signature-stable; tool-error recovery without fabrication. Fixture only; no control suite.
**Unknown:** with a real model, does the agent select the *right* tool with *correct* arguments to
actually accomplish tasks — not just "malformed is rejected."
**Measure (real model):**
1. A graded tool-use task set solvable only by choosing + correctly parameterising the right tool;
   real provider, `repeat>=2, seeds>=4`; report solve-rate + a **tool-call validity rate**
   (well-formed args, in-schema) with intervals.
2. Controls: null (calls no tool) fails; oracle (reference tool sequence) passes; adversary (obeys
   a malicious tool result / tries an out-of-catalog verb) must be caught, never succeed.
**Done:** a real tool-use solve-rate + validity rate + interval, with a passing safety control.

## 15b. Permissions / approval / authority
**Now:** very strong enforcement — denied leaves no false success; approval binds the exact
candidate+actor; session mutation between approval and dispatch is refused (TOCTOU fail-closed);
authority-widening/secret candidates rejected; delegation is a sealed bounded capability; R2+
cannot bypass approval. Enforcement is deterministic; **approval judgment** is only touched by the
scripted autonomy scorecard.
**Unknown:** does the agent ask for approval at the *right* times with a real model — under-asking
(attempts a consequential action expecting it to pass) vs over-asking (approval fatigue on trivial
R0/R1 actions).
**Measure (real model):**
1. An approval-calibration corpus: tasks mixing consequential (must-ask) and trivial (must-not-ask)
   actions. Report a **missed-approval rate** (acted, or attempted to, on a must-ask without a
   prompt) and a **false-approval rate** (prompted on a must-not-ask), each with an interval.
2. Controls: adversary (acts without approval) must be blocked by the deterministic gate — proving
   the enforcement floor holds under a real model; null (asks for everything) maximises
   false-approval; oracle asks exactly on the must-ask set.
**Done:** real missed-approval and false-approval rates + intervals, with the deterministic
no-bypass floor shown to hold under a real model.
