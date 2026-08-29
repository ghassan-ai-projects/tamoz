# Independent Design Study: Approval/Permission Policy for an Autonomous Coding Agent

**Status:** independent green-field study. No codebase was read in producing this document; every
interface, component name, and mechanism below is a proposal, not a description of any existing
system. Prior-art claims are grounded in public documentation and reporting (links inline).

**Date:** 2026-08-22

---

## 1. Problem statement — what approvals actually protect against

An autonomous coding agent holds the user's privileges — shell, filesystem, credentials in
environment variables and config files, push access, paid API keys — and takes instructions from
text it reads, much of which the user did not write. The approval system exists because the agent's
*decision to act* is not trustworthy in two distinct ways: the model can be honestly wrong, and the
model can be deliberately steered. Approvals are the control that closes the gap between "the model
decided to do X" and "the user accepts the consequences of X". Concretely, the threat model has
five named risks:

**R1 — Destructive actions.** Irreversible or expensive-to-reverse mutations: `rm -rf` outside a
scratch area, `git reset --hard` over uncommitted work, `DROP TABLE`, killing a process the user
cares about, overwriting a hand-edited file, force-push to a shared branch, deleting a worktree
that holds in-progress state. The defining property is *irreversibility*, not danger in the
abstract: `git commit` is cheap to undo, `git push --force` to a shared remote is not. The approval
system must classify by reversibility and blast radius, not by verb name — a plain `mv` can destroy
more than a flagged `rm` if the target is the only copy.

**R2 — Exfiltration.** The agent reads something sensitive (a private key, `.env`, customer data,
proprietary code) and transmits it somewhere the user doesn't control: `curl` to an attacker host,
a `git push` to a lookalike remote, an MCP tool that phones home, a PR body embedding secrets. This
is the highest-severity risk because it is silent, unbounded in damage, and usually irreversible
once the bytes leave. Simon Willison's "lethal trifecta" frames it precisely: an agent that
simultaneously has (a) access to private data, (b) exposure to untrusted content, and (c) an
outbound channel is one poisoned document away from data theft
([ToxSec](https://www.toxsec.com/p/agentic-ai-attacks-explained-lethal-trifecta),
[gopher.security](http://www.gopher.security/mcp-security/securing-model-context-protocol-zero-trust)).
A coding agent almost always holds all three. Approvals must therefore treat the *conjunction* of
read-taint + outbound-action as a first-class risk class, not just individual scary commands.

**R3 — Prompt-injection-driven actions.** The agent reads attacker-controlled text — a README in a
cloned repo, a web page, an issue body, a log file, tool output, another MCP server's tool
description — and that text contains instructions. LLMs cannot reliably distinguish instructions
from data ([snailsploit](https://snailsploit.com/ai-security/agentic-ai-threat-landscape/)), so the
agent can be steered into running commands, editing files, or exfiltrating data that the user never
asked for. EchoLeak (CVE-2025-32711) demonstrated zero-click exfiltration via crafted email content
in Microsoft 365 Copilot
([HackerNoon](https://hackernoon.com/the-kernel-is-where-sovereignty-lives-and-ai-agents-just-broke-the-model)).
The consequence for approval design: the *approval prompt itself* is downstream of
attacker-influenced context, so the human is the last reliable checkpoint — and the policy engine
must not trust the agent's own narration of why an action is fine (see §7).

**R4 — Confused deputy.** The agent is a deputy holding the user's authority; a less-privileged
party (anyone who can get text into the context window) rides that authority
([Securie](https://securie.ai/glossary/confused-deputy) — the framing is Norm Hardy's 1988
capability-security term). Concretely: a poisoned README gets the agent to push to a repo using the
user's SSH key, or to invoke an internal API with the user's token. Approvals mitigate this only if
the decision context records *whose instruction* the action traces to, or at minimum whether
untrusted content is in the causal chain.

**R5 — Cost and side-effect spend.** Paid operations: LLM API calls in loops, cloud resource
creation, CI minutes, package purchases, emails sent, tickets filed, messages posted to shared
channels. Individually cheap, unbounded in aggregate, and the damage is a bill or a reputation, not
a filesystem state. A `while` loop around a paid endpoint is the canonical failure. Approvals (and
budgets) are the circuit breaker.

Two risks the approval system does **not** solve and must not claim to: (a) enforcement — an
approval says "you may", it does not *prevent*; sandboxing does that (§6.2, §7); (b) model quality —
a user approving a bad plan is not an approval-system failure.

---

## 2. Design principles

Each principle is stated with its rationale and its cost. Principles conflict; the costs are where
the conflicts live.

**P1 — Fail closed (deny by default).** Any action the policy does not understand — an unlisted
tool, a new MCP server, a malformed request, a policy that fails to load — resolves to *deny* or
*ask*, never *allow*. Rationale: R1–R4 all exploit gaps between what the policy author enumerated
and what the agent can actually do; a default-open gap is a vulnerability, a default-closed gap is
a UX bug. Cost: friction. Every new capability is dead until the policy is updated, and a broken
policy file can halt all work. The cost is paid by making *ask* (not *deny*) the usual fallback,
so a gap interrupts rather than blocks.

**P2 — Least privilege, scoped in time and space.** The agent gets the minimum authority for the
current task, and grants expire: session-scoped by default, command-scoped where feasible, durable
grants explicit and rare. Rationale: authority that persists longer than its justification is pure
attack surface for R3/R4; Android learned this and moved to runtime, one-time, and auto-resetting
permissions ([arXiv 2605.27667](https://arxiv.org/html/2605.27667v1)). Cost: re-asking. Every
scope narrowing multiplies the number of prompts the user sees, which feeds approval fatigue (§5) —
the worst failure mode of this principle is the user switching to a permanent allow-all to make the
prompts stop.

**P3 — Policy/mechanism separation.** The agent core never embeds policy decisions; it asks a
dedicated component "may I do X?" and obeys the answer. Policy is data, mechanism is code.
Rationale: policies change weekly (new tools, new users, new risk appetite), mechanism changes
rarely; coupling them means every policy tweak risks the agent core, and every core refactor risks
silently changing the security posture. This is also the standard architecture of OPA
([Safeguard](https://safeguard.sh/resources/blog/opa-policy-language): "the core idea is
decoupling"). Cost: an indirection layer that must be held narrow. Every leaked special case
("the core pre-filters boring commands") erodes the boundary and makes behavior unpredictable.

**P4 — Determinism.** The decision is a pure function of (action request, policy document, grant
state): same inputs, same verdict, no model calls, no randomness, no wall-clock dependence except
through explicit expiry fields. Rationale: a security decision you cannot reproduce is a decision
you cannot audit, test, or debug; non-deterministic policy evaluation makes §7's replay requirement
impossible. Cost: expressiveness ceiling. "Is this command semantically dangerous?" is not a
deterministic question, so deterministic policies must classify by *structure* (verb, target,
taint flags) and will both over- and under-approximate semantic danger.

**P5 — Simulatability and explainability.** For any action, the system can answer "what would you
do with this?" without executing, and "why did you decide that?" by naming the exact rule, profile,
or grant that fired. Rationale: users cannot maintain a policy they cannot predict (P2's
re-asking cost becomes unbearable if denials are surprising), and auditors cannot trust a black
box. Cost: policy authors must write machine-readable reasons, and the rule language must stay
simple enough that "which rule fired" is a meaningful answer — a constraint that rules out some
clever representations (§3.5).

**P6 — Auditability.** Every decision — allow, deny, ask, and the human's answer — is appended to a
durable, tamper-evident log with the full request, the policy version, the rule that fired, and the
timestamp. Rationale: after an R2 exfiltration or R1 deletion, the first questions are "what
happened, who approved it, and why did the policy allow it"; without a decision log there is no
answer. Cost: storage, and a genuine privacy tension — the log must record command arguments to be
useful, and arguments contain secrets; the log itself becomes a sensitive asset needing access
control.

**P7 — Approvals are a checkpoint, not a boundary.** The approval layer decides *whether to ask
and what to permit at the policy level*; a separate enforcement layer (OS sandbox, container,
network policy) makes denial physically real. Codex CLI embodies this: its sandbox is "enforced by
the OS… an Apple Seatbelt profile that starts from `(deny default)`"
([Backgrind](https://backgrind.com/blog/codex-cli-sandbox-modes/)). Rationale: policy evaluation
bugs, confused deputies, and injection-resistant bypasses are all survivable if the sandbox floor
holds; if approvals are the only barrier, one bypass is game over — as happened when Claude Code
read files in a denied credentials folder via an alternative tool path
([arXiv 2604.13536](https://arxiv.org/pdf/2604.13536)). Cost: two systems to design and keep
consistent; a policy that says "allow" but a sandbox that says "deny" (or vice versa) is a standing
source of confusing behavior that must be reconciled at the interface.

**P8 — Human-legible risk at the point of decision.** The approval prompt shows what matters for
*this* decision — exact command, exact target paths, reversibility, network destination, taint
state — not a generic "allow this tool?". Rationale: the human is the last reliable check against
R3; a vague prompt converts them into a rubber stamp. Cost: the renderer needs structured action
metadata (targets, destinations) that tools must supply, and a good summary costs design effort
per tool type.

---

## 3. Policy model options

Five distinct models. None is sufficient alone; §8 combines them.

### 3.1 Static allow/deny/ask rule lists

Pattern-matched rules over `(tool, argument-shape)`: `Bash(npm test:*)` → allow, `Bash(curl *)` →
ask, `Read(./.env*)` → deny. Evaluated in order, first match wins, deny-by-default fallthrough.
This is the Claude Code model — declarative allow/deny/ask rules layered over permission modes,
with a defined evaluation order (hooks → deny → ask → allow)
([HeyClaude](https://heyclaude.de/entry/guides/permission-design-for-claude-agent-sdk-agents)).

- *Expressiveness:* low-medium. Patterns over argv and paths are brittle to obfuscation
  (`rm -rf $DIR`, shell indirection, `bash -c "…"`) and cannot express taint conjunctions
  ("allow curl only if no private file was read this session") without extra machinery.
- *Complexity:* lowest. A rules file is readable end-to-end; evaluation is a loop.
- *Swap-ability:* high — the rules are pure data; the evaluator is 200 lines.
- *UX:* good for experts, poor for everyone else. Hand-writing correct glob rules is
  error-prone; over-broad rules (`Bash(*)`) are the common escape hatch and silently void R1–R4.

### 3.2 Risk-tiered autonomy levels

A small set of named tiers that bundle capabilities: e.g. *read-only* (inspect, no mutation),
*workspace-write* (edit inside the project, run routine local commands, no network or external
mutation), *full access*. This is the Codex CLI model, and its key design insight is making the
sandbox tier and the approval policy *orthogonal axes* — `read-only` / `workspace-write` /
`danger-full-access` crossed with `untrusted` / `on-request` / `never`
([inventivehq](https://inventivehq.com/blog/ai-coding-cli-sandbox-approval-modes-compared)).

- *Expressiveness:* deliberately low. Tiers are coarse; anything not fitting a tier needs escape
  hatches.
- *Complexity:* very low for the user, moderate internally (someone must assign every action to a
  tier).
- *Swap-ability:* medium — tiers are data, but the tier→capability mapping must live somewhere and
  tends to bake into tool definitions.
- *UX:* excellent. "Run it in workspace-write with on-request approvals" is a sentence any user
  understands. This is the right *user-facing* vocabulary even when another model does the
  underlying evaluation.

### 3.3 Capability / token-based

Authority as unforgeable, scoped tokens: the agent holds a capability for "edit files under
`src/`" or "call MCP tool X with args matching schema S", derived from a root grant and attenuable
(delegated onward only narrower, in the macaroons/biscuit style). Actions carry their capability;
the checkpoint verifies rather than decides.

- *Expressiveness:* high for delegation and scoping — confused-deputy resistance (R4) is the
  *point* of the model; authority and designation travel together.
- *Complexity:* highest of the five. Minting, attenuation, revocation, and storage of tokens is
  real infrastructure, and every tool must become capability-aware.
- *Swap-ability:* low — this is an architecture, not a policy file; it reshapes how tools receive
  authority.
- *UX:* poor as a surface (nobody wants to manage tokens), though the *effects* (fine-grained,
  expiring grants) are exactly what P2 wants. Best used as an internal representation, not a
  user-facing model.

### 3.4 Profile presets

Named, curated bundles that combine tiers, rule sets, and UX behavior into one selectable unit:
`review` (read-only + plan output), `implement` (workspace-write + ask-on-external), `ops`
(broader, louder logging), `unattended` (deny everything ask-worthy, fail the task instead). The
user picks a profile per session; profiles compose over a base policy. Factory's autonomy levels
(Off/Low/Medium/High, each bundling tool policy and sandbox scope) are the commercial reference
([Continuum](https://continuumcode.ai/guides/factory-ai-vs-claude-code/)); Claude Code's permission
modes (`default`, `acceptEdits`, `plan`, `bypassPermissions`) are per-mode presets of the same idea
([Alibaba Cloud docs](https://help.aliyun.com/en/model-studio/claude-code)).

- *Expressiveness:* as expressive as whatever it bundles — presets are a packaging model, not an
  evaluation model.
- *Complexity:* low for users, low for authors (a profile is a small data file).
- *Swap-ability:* very high — profiles are the natural unit of hot-swapping (§4).
- *UX:* the best of the five as a primary surface, provided the set stays small (3–5); a dozen
  profiles recreates the complexity they hide.

### 3.5 External policy engine (OPA/Rego, Cedar)

Decisions delegated to a general-purpose engine: the agent core sends a structured request
(principal, action, resource, context) to OPA or a Cedar evaluator; policies are authored in Rego
or Cedar, versioned, tested, and analyzed outside the application
([Oso](https://www.osohq.com/learn/opa-vs-cedar-vs-zanzibar),
[sph.sh](https://sph.sh/en/posts/policy-language-comparison-cedar-rego-openfga/)). Cedar adds
formal analyzability — you can *prove* properties of a policy, which serves P5 directly
([Natoma](https://natoma.ai/blog/mcp-access-control-opa-vs-cedar-the-definitive-guide)).

- *Expressiveness:* highest — arbitrary conditions over structured context, including taint
  conjunctions (R2) that §3.1 cannot express.
- *Complexity:* highest operational cost: a runtime (sidecar or embedded SDK), a new language for
  the team, policy CI. Rego in particular is a full query language whose flexibility makes "which
  rule fired" (P5) harder to answer than in a first-match list.
- *Swap-ability:* high in one direction (policy swaps without app changes — that is OPA's whole
  pitch) but adopting it is a one-way door of operational dependency; and in a Ruby host there is
  no first-class Cedar/OPA runtime, so it means a subprocess or sidecar boundary.
- *UX:* none directly — it's infrastructure; a profile/rules layer must still exist on top.

### 3.6 Comparison

| Model | Expressiveness | Complexity (user / operator) | Swap-ability | UX as primary surface |
|---|---|---|---|---|
| 3.1 Static rules | Low–medium; brittle to obfuscation | Medium / low | High (pure data) | Poor–medium; expert-only authoring |
| 3.2 Risk tiers | Low (coarse) | Low / medium | Medium (tier map leaks into tools) | Excellent |
| 3.3 Capabilities | High (delegation, attenuation) | High / high | Low (architectural) | Poor |
| 3.4 Profiles | Whatever it bundles | Low / low | Very high | Excellent |
| 3.5 OPA/Cedar | Highest (arbitrary context, provable) | Low / high | High (policy-as-data) but heavyweight dep | None — needs a layer above |

No model wins all columns. The two excellent-UX models (3.2, 3.4) are packaging, not evaluation;
the two high-expressiveness models (3.3, 3.5) are unusable as surfaces; 3.1 is the pragmatic
evaluation middle. §8 combines 3.4 over 3.2 over 3.1, with 3.5 left open behind the interface.

---

## 4. Policy/mechanism separation

### 4.1 The narrow interface

The agent core's entire relationship with policy is four calls — `decide`, `resolve`, `simulate`,
`reload` — of which only the first is on the action hot path:

```
decision = policy.decide(action_request)

action_request = {
  tool:        String,          # e.g. "shell", "file_edit", "mcp:github:create_pr"
  verb:        String,          # normalized action class: "read", "write", "execute", "network", "external-publish"
  argv:        [String],        # exact, resolved invocation — never re-parsed downstream
  targets:     [String],        # canonicalized absolute paths / URLs it will touch
  session:     { id:, profile:, taint: { untrusted_input: Bool, private_data_read: Bool } },
  context:     { cwd:, trust_root:, parent_grant_id: nil }
}

decision = {
  id:          String,          # decision handle; an `ask` is resolved against this id
  verdict:     :allow | :deny | :ask,
  reason:      String,          # human-legible, names the rule/grant that fired (P5)
  rule_id:     String,          # machine handle for the audit log (P6)
  grant_offer: nil | { scope: :once | :session | :command, key: String },
  policy_rev:  String           # digest of the policy document that produced this
}
```

Properties that matter:

- **The core asks; it never pre-judges.** No "the core skips the check for obviously-safe reads" —
  that is policy leaking into mechanism (P3). The policy component is fast enough (P4, sub-ms) that
  asking costs nothing.
- **The request is structured and terminal.** `argv` and `targets` are canonicalized *before* the
  decision, and what was decided on is exactly what executes — otherwise TOCTOU (F3). The core
  must not re-parse a shell string after approval.
- **Taint is input, not verdict.** The core reports *facts* (untrusted content entered the session;
  private paths were read); the policy decides what the conjunction means (R2). This keeps the
  lethal-trifecta rule in data, where it can change, instead of in the agent loop.
- **`ask` is a first-class answer with a `grant_offer`.** The decision carries the scope the user
  may grant (once / session / command-pattern), so the UI layer is a dumb renderer and grant
  semantics stay inside the component.
- **The human's answer flows back through `resolve`, not through the core's judgment.** The
  remaining three calls: `resolve(decision_id, answer, chosen_scope)` records the human's response
  to an `ask`, creates any grant in the grant store, and appends it to the decision log (F2) —
  the core reports what the user clicked, it never interprets it; `simulate(action_request)`
  evaluates with no side effects (P5, §4.3 validation); `reload(policy_doc)` performs the §4.3
  swap. Every state change in the component passes through one of these four calls.

### 4.2 What belongs inside vs outside

**Inside the policy component:**

- The rule/tier/profile evaluator (P4: pure function of request + policy + grant state).
- Profile resolution and composition (base policy + selected profile + user overrides).
- The grant store: session grants, their keys, their expiry; keyed on *request structure*, never
  on outcomes.
- The decision log (P6): append-only, one record per `decide` call including the human's answer to
  an `ask`.
- Policy loading, validation, versioning, hot-swap (below).
- `simulate(action_request)` — the same evaluation with no side effects, for "what would happen"
  UX and tests (P5).

**Outside, in the agent core or platform layer:**

- Tool dispatch and execution, including canonicalizing argv/targets before the call.
- The sandbox/enforcement layer (P7) — the policy says "allow"; the sandbox makes "deny" real.
- Rendering the approval prompt and collecting the human's answer (terminal, chat, mobile).
- The model loop, planner, memory — anything non-deterministic.
- Cost metering *signals* (the core reports "this action costs N credits"; policy holds the
  budget rule, R5).

The line to police: **the component returns verdicts; it never executes, and the core never
evaluates.** If the core grows a `if boring?(cmd) then skip` branch or the component grows a
`system()` call, the separation has failed.

### 4.3 Hot-swapping policies and profiles

- Policy documents and profiles are **content-addressed**: every load computes a digest
  (`policy_rev`) that goes into every decision record — the audit log can always say *which*
  policy allowed an action (P6).
- Swap is **atomic and session-explicit**: `policy.reload(new_doc)` replaces the evaluator for
  *new* decisions; in-flight sessions keep their `policy_rev` unless the caller explicitly
  re-binds. This avoids the race where a long session silently changes its rules mid-task.
- **Grants reference the policy that created them.** On reload, session grants are re-validated
  against the new document; a grant the new policy wouldn't have issued is dropped (fail closed,
  P1), not grandfathered.
- **Validation before activation**: a new document must parse, pass schema checks, and pass a
  canned simulation suite ("`rm -rf /` is denied", "read of `.env` asks") before it can become
  active. A broken document can never take the system down — the old one stays live (this is how
  P1's cost is paid: fail-closed for actions, fail-*safe* for policy operations).
- Rollback is "reload the previous digest" — trivially available because documents are immutable
  and addressed by content.

---

## 5. UX & latency

**Approval fatigue is the primary UX failure mode, and it is a security failure.** Habituation
turns the human checkpoint into a rubber stamp, after which R3 is unmitigated. Every mechanism
below trades prompt-count against grant-breadth; the design goal is *fewer, more meaningful*
prompts.

- **Batching at the plan level.** The agent presents "here are the 12 actions this step needs"
  once, classified by risk, instead of 12 sequential prompts. Approve-all / approve-the-safe-
  subset / reject. This front-loads attention to the moment the user still has context, and it
  turns latency from per-action to per-step.
- **Session-scoped grants as the default escalation.** The `ask` answer is a ladder: *once* /
  *this exact command, always* / *this pattern this session* / *(rarely) always*. P2's cost
  (re-asking) is contained by making the middle rungs cheap and the durable rung conspicuous.
  Android's one-time permissions are the proven consumer version of exactly this ladder
  ([arXiv 2605.27667](https://arxiv.org/html/2605.27667v1)).
- **Autonomy tiers per action class, not global.** "Reads: free. Workspace edits: free. Local
  test runs: session grant. Network: ask. External publish (push, PR, message): always ask." A
  single global slider forces users to choose between paralysis and recklessness; per-class tiers
  let autonomy be high precisely where R1/R2/R5 exposure is low.
- **Diminishing prompts.** Repeated identical-structure requests in a short window collapse into
  one prompt offering a session grant — while *changes in structure* (new destination, new target
  root, new taint state) always re-prompt. The fatigue defense must never generalize across a
  risk-class boundary.
- **Async approval over chat surfaces.** For an agent monitored via chat (mobile, Slack-like),
  blocking the loop on a prompt is often right for R1/R2, but not for everything: the design needs
  (a) an approval queue with per-request state, (b) *deny on timeout* as the default (P1), with
  per-class overrides ("reads time out to allow" only if the policy explicitly says so),
  (c) notifications with enough structured context (P8) to decide from a watch screen, and
  (d) the ability for the agent to continue independent work while a risky action pends — which
  requires the queue, not a modal dialog, as the integration shape.
- **Latency budget.** Policy evaluation itself must be sub-millisecond and allocation-light (P4)
  so it never appears in the critical path; the real latency is human. Two mitigations: prefetch
  (simulate the likely next actions while the model is generating, P5) and plan-level batching
  (above). A user kept waiting per-action will disable the system; a user consulted per-plan will
  not.

---

## 6. Prior art

### 6.1 Claude Code — permission modes + layered rules

Modes (`default`, `acceptEdits`, `plan`, `bypassPermissions`, and managed variants) crossed with
declarative allow/ask/deny rules and hooks, evaluated in a documented order
([Alibaba Cloud docs](https://help.aliyun.com/en/model-studio/claude-code),
[HeyClaude](https://heyclaude.de/entry/guides/permission-design-for-claude-agent-sdk-agents)).
*Does well:* the mode vocabulary is genuinely understandable; deny rules are enforceable in
settings and administrable centrally; the `canUseTool`-style callback gives embedders one narrow
seam — the shape §4.1 proposes. *Steal:* the three-verdict rule language (allow/ask/deny) and the
mode-as-preset packaging. *Avoid:* two known failure patterns — rules are pattern-matched, and
pattern matching is bypassable (a denied folder was readable through an alternative tool path,
per the incident survey at [arXiv 2604.13536](https://arxiv.org/pdf/2604.13536)); and users
routinely escalate to `bypassPermissions` under fatigue, voiding the model. Lesson: rules need an
enforcement floor beneath them (P7), and fatigue is a design input, not a user failing.

### 6.2 OpenAI Codex CLI — orthogonal sandbox × approval axes

Three sandbox tiers (`read-only`, `workspace-write`, `danger-full-access`) enforced by the OS —
Apple Seatbelt from `(deny default)` on macOS, bubblewrap on Linux — crossed with approval
policies (`untrusted`, `on-request`, `never`)
([inventivehq](https://inventivehq.com/blog/ai-coding-cli-sandbox-approval-modes-compared),
[Backgrind](https://backgrind.com/blog/codex-cli-sandbox-modes/)). *Does well:* the cleanest
separation in the field of *policy* (when to ask) from *mechanism* (what is physically possible);
sane defaults (`workspace-write` + `on-request`); the sandbox starts from deny. *Steal:* the
two-axis model wholesale — it is exactly P7 made concrete, and it gives §4.1's interface a natural
semantics: `allow` means "policy permits and sandbox must also permit". *Avoid:* the axes are
coarse; `workspace-write` draws a filesystem line but says little about network or exfiltration
(R2) without additional config, and "danger-full-access" as a named tier normalizes the risky end.

### 6.3 sudo / doas — the classic interactive grant

Per-invocation privilege escalation with a timestamp-limited credential cache (`sudo` remembers
authentication for a few minutes), a declarative policy file (`sudoers`) with command patterns,
and a hard rule that policy is validated before use (`visudo`). *Does well:* forty years of proof
that *ask at point of use, cache briefly, log everything* is a workable human model; `sudoers`
shows both the power and the footguns of pattern-based command rules (`NOPASSWD`, wildcard
injection). *Steal:* the short-lived credential cache — it is the session-grant ladder of §5 in
its oldest form — and `visudo`'s validate-before-activate, which §4.3 adopts for policy swaps.
*Avoid:* sudoers' evaluation subtleties (order dependence, alias indirection) that make "what does
this policy actually permit" famously hard — a direct violation of P5; and the binary permit/deny
with no structured *ask* channel, which agents need.

### 6.4 OPA / Cedar — policy-as-data infrastructure

OPA: a general engine where services ask "is this allowed?" with structured input and Rego
policies decide ([Safeguard](https://safeguard.sh/resources/blog/opa-policy-language)). Cedar:
AWS's authorization language optimized for *analyzability* — policies can be formally verified and
diffed for what they permit ([Natoma](https://natoma.ai/blog/mcp-access-control-opa-vs-cedar-the-definitive-guide),
[Oso](https://www.osohq.com/learn/opa-vs-cedar-vs-zanzibar)). *Does well:* the canonical
implementation of P3; policy CI, versioned bundles, decision logs, and (Cedar) proofs about
policies serve P4–P6 better than any hand-rolled evaluator. *Steal:* the architecture —
decoupled engine, content-addressed policy bundles, decision logging — even if not the software.
*Avoid:* adopting the runtime on day one in a Ruby host: no first-class SDK, a sidecar/subprocess
boundary for a sub-millisecond decision (§5's latency budget), a new language for the team, and a
Rego learning curve whose flexibility undermines "which rule fired" explainability. Keep §4.1's
interface engine-shaped so OPA/Cedar can be plugged in later if expressiveness demands it (§3.5).

### 6.5 Mobile OS permission models (Android / iOS)

Runtime, per-resource prompts; one-time grants; auto-reset of permissions for unused apps;
permission *groups* that turned out to over-bundle
([arXiv 2605.27667](https://arxiv.org/html/2605.27667v1)). *Does well:* two decades of
consumer-scale evidence on fatigue: users grant reflexively, so the platform narrowed scope
(one-time, while-in-use) instead of asking louder. *Steal:* one-time/session/always as the grant
ladder; auto-expiry of unused grants (a session grant not exercised in N minutes dies); showing
the *resource*, not the API, in the prompt (P8). *Avoid:* permission-group over-bundling —
Android's groups let one grant cover more than users understood; the agent equivalent is a session
grant for "shell commands" that silently covers `curl`. Grant keys must be structural and narrow
(§4.1).

(Also noted: Factory AI's Off/Low/Medium/High autonomy tiers as the profile-preset model done
commercially — [Continuum](https://continuumcode.ai/guides/factory-ai-vs-claude-code/) —
supporting §3.4's claim that small named bundles are the workable user surface.)

---

## 7. Failure modes & challenges

**F1 — Prompt injection reaches the approval channel.** The approval prompt is rendered from
context the attacker may have influenced: the agent narrates "I'd like to run `deploy.sh`" and the
real payload is three lines down, or the summary sanitizes what the command actually does. The
human checkpoint is only as good as the prompt is honest. *Design response:* the prompt renders
from the *structured request* (§4.1: exact argv, exact targets), never from the model's
narration; narration may be attached but must be visually subordinate. This is P8's hard edge.

**F2 — Replay and audit of decisions.** "Who approved the push at 14:03, under which policy, on
what rule?" must be answerable after the fact (P6). Challenges: the log records arguments that may
contain secrets (access-control the log itself); the log must be append-only/tamper-evident to be
evidence; and replay requires that decisions are deterministic (P4) and policy-addressed
(`policy_rev`, §4.3) — otherwise "same inputs" is not definable and replay is fiction.

**F3 — Time-of-check/time-of-use.** The gap between *decide* and *execute* is an attack and bug
surface: a path approved as a workspace file is symlink-swapped before the write; a command string
is re-parsed by a shell and picks up new semantics; an environment change alters what `argv[0]`
resolves to. *Design response:* canonicalize and freeze the request before `decide` (§4.1), bind
grants to digests of the exact structure approved, execute what was decided on without re-parsing,
and let the enforcement layer (P7) re-check at the kernel boundary where swaps actually matter.

**F4 — Non-determinism of the requesting agent.** The agent may never issue the identical request
twice, which breaks naive caching, and may issue *near*-identical requests that differ only in the
dangerous part (same verb, new destination). Grant keys must therefore be *patterns the policy
chose* (verb + target-root + destination-class), not hashes of requests — and §5's
diminishing-prompt rule must treat any structural change as a fresh decision. The uncomfortable
consequence: false re-prompts are the price of safety here, and the budget for them is set by
fatigue (§5), not by correctness.

**F5 — Secure defaults under change.** New tools, new MCP servers, new verbs appear continuously
— an MCP server's tool descriptions are themselves untrusted input (R3). Default-closed (P1)
handles the arrival case, but two adjacent defaults also matter: *deny on timeout* for unattended
asks (§5), and *deny on policy load failure* while keeping the previous policy live (§4.3) — the
system must never choose "permissive because confused".

**F6 — Fatigue attacks.** An attacker who can influence the agent can *flood* it with asks,
counting on the user to start clicking through (or to switch to a permanent grant). Rate-limiting
asks, collapsing duplicates, and making durable grants deliberately awkward (an extra confirmation,
a written scope) are the mitigations; a prompt counter in the UI ("23 approvals this session")
makes the flood visible.

**F7 — The conjunction problem (taint tracking is approximate).** R2's lethal-trifecta rule needs
to know whether private data was read and untrusted content ingested — but taint through an LLM's
context is not byte-trackable. The session taint flags are conservative approximations
(once-tainted, tainted-for-session). Over-tainting means everything eventually asks (fatigue);
under-tainting means exfiltration sails through. This is the least-solved problem in the study;
the honest position is conservative taint + per-class autonomy tuned so the over-taint cost lands
on low-risk classes.

**F8 — Approval ≠ enforcement.** Any check the agent can route around — a second tool path to the
same resource, as in the Claude Code incident (§6.1) — voids the policy silently. Every resource
must have its tool paths enumerated under the policy (or the sandbox must make the bypass
physically impossible). This is why P7 exists and why "the policy allowed it" must never be the
only barrier.

---

## 8. Recommendation

### 8.1 The architecture

**A three-layer stack, profile-packaged, behind one narrow interface:**

1. **Evaluation core (model 3.1):** a small embedded deterministic evaluator — ordered
   allow/ask/deny rules over the structured §4.1 request, first-match, deny fallthrough. Pure
   function, sub-millisecond, fully testable. ~200 lines of mechanism; all content is data.
2. **Tier mapping (model 3.2):** every action class is assigned to a risk tier (*read /
   workspace-write / local-execute / network / external-publish / destructive*), and each tier has
   a default verdict per profile. Tiers are the vocabulary rules are written in; per-class autonomy
   (§5) is expressed as tier-level overrides.
3. **Profiles (model 3.4):** named, content-addressed documents — `review`, `implement`,
   `unattended` — bundling tier defaults + extra rules + UX behavior (timeout posture, prompt
   verbosity). The user selects a profile per session; hot-swap per §4.3.

Plus, cross-cutting: the **grant ladder** (once / exact / session-pattern; no "always" for
network, publish, or destructive tiers), the **append-only decision log** with `policy_rev`
(P6/F2), **taint flags** as request input with a conservative conjunction rule in the base policy
(R2/F7), and a **sandbox floor** beneath the whole stack (P7/F8) — Codex-style, orthogonal to
policy. Model 3.5 (OPA/Cedar) is deliberately *not* adopted now; §4.1's request/decision shape is
engine-compatible, so a future swap costs a new evaluator behind the same interface, not a
redesign.

### 8.2 Why this, tied to §§1–7

- Against **R1**, tier assignment classifies by reversibility and blast radius (§1), and the
  `destructive` tier never gets durable grants — the failure that matters gets a human every time.
- Against **R2**, taint conjunction is a first-class rule in the base policy (§1, F7), and
  `network`/`external-publish` are permanently ask-tier — the lethal trifecta cannot be granted
  away in one click (§6.5's lesson).
- Against **R3/F1**, prompts render from the structured request, not model narration (§7), and
  every rule is deterministic so a steered agent faces the same wall every time (P4).
- Against **R4**, per-session profiles + expiring grants bound the deputy's usable authority in
  time (P2); capability tokens (3.3) remain available behind the interface if delegation to
  sub-agents becomes a requirement.
- Against **R5**, cost-bearing verbs are their own tier with budget rules in the profile — data,
  not code (§4.2).
- **§2:** P1 (deny fallthrough), P2 (grant ladder + expiry), P3 (§4.1 interface), P4/P5 (pure
  evaluator + `simulate` + `rule_id`), P6 (decision log), P7 (sandbox floor), P8 (structured
  prompts) each have exactly one home in the design; no principle is delegated to "be careful".
- **§3:** the comparison showed no single model wins; this stack takes each model only in the role
  where its column is strong — 3.1 to evaluate, 3.2 to classify, 3.4 to present.
- **§5:** plan-level batching, per-class tiers, and diminishing prompts are all expressible as
  profile data + grant-store behavior, so fatigue tuning never touches the agent core.
- **§6:** the design is Codex's two-axis separation (policy ↔ sandbox) + Claude Code's
  three-verdict rules and mode packaging + sudo's validate-before-activate + OPA's
  policy-as-data discipline + Android's grant ladder — with each system's documented failure
  (pattern bypass, fatigue escalation, sudoers opacity, Rego complexity, permission-group
  over-bundling) mapped to a specific countermeasure above.
- **§7:** F1→structured prompts, F2→`policy_rev` + deterministic log, F3→freeze-before-decide,
  F4→policy-chosen grant keys, F5→deny-on-timeout + previous-policy-stays-live, F6→ask
  rate-limiting and visible counters, F7→conservative taint with cost shifted to low-risk tiers,
  F8→sandbox floor. Every named failure mode has a named mechanism.

### 8.3 Open questions the eventual design must answer

1. **Grant-key grammar.** Exactly which request fields compose a session-grant key (verb +
   canonicalized target root? destination host? argv head?) — too narrow floods, too broad voids
   R1/R2. Needs empirical tuning against real session traces.
2. **Taint lifecycle.** Do taint flags ever clear within a session (after a human review? never?),
   and does *any* read of a sensitive path taint, or a policy-defined set? F7's trade-off is made
   here.
3. **Tier assignment ownership.** Who assigns a new tool/MCP server to a tier — tool author
   (metadata), policy author (override), or both with deny-on-conflict? This decides whether new
   tools fail closed (P1) automatically.
4. **Multi-agent delegation.** When the agent spawns sub-agents, do grants attenuate (3.3
   semantics) or does each sub-agent get the session profile? The interface supports both; the
   policy must pick.
5. **The async queue contract.** What is the agent allowed to do while an `ask` pends — continue
   provably-independent read-only work only, or anything the policy still allows? Blocking is
   safer; continuing is the latency win (§5). Needs a real definition of "independent".
6. **Log secrecy.** Decision logs need arguments to be useful (F2) and arguments contain secrets —
   redaction rules, retention, and access control for the log are their own mini-policy.
7. **Profile governance.** Who may author/install profiles, and are managed (org-pinned) profiles
   a requirement? Claude Code's managed-settings precedent (§6.1) suggests yes for team contexts.
8. **Simulation surface.** Is `simulate` exposed to users ("what could this profile let it do?")
   or only to tests and CI (§4.3 validation)? The former is a real feature; the latter is the
   minimum.

---

## 9. Revision log

Draft 1 was written in full, then checked item-by-item against the bar (§§1–8 below refer to the
numbered requirements, not the sections). The critique found:

1. *Problem statement* — passed as drafted (five named risks with concrete instances, plus an
   explicit "not solved" boundary). No change.
2. *Design principles* — draft had seven; P8 (human-legible risk at point of decision) was added
   in revision because the critique found §5 and F1 both depended on a principle that existed only
   implicitly. Eight principles now, each with rationale and cost.
3. *Policy model options* — five models passed, but the comparison table (§3.6) was added in
   revision: the draft stated tradeoffs in prose but the bar requires a comparison covering
   expressiveness, complexity, swap-ability, and UX explicitly; the table forces each cell to be
   defensible and exposed that capability tokens score "poor" as a UX surface, sharpening §8.
4. *Policy/mechanism separation* — draft had the interface but not the *policing rule*; revision
   added the explicit "component never executes, core never evaluates" line and the §4.3
   grant-revalidation rule (drop grants the new policy wouldn't issue), which the critique found
   missing for the hot-swap story.
5. *UX & latency* — passed, but the async-approval bullet gained the concrete requirements
   (queue, deny-on-timeout, notification context, continue-independent-work) in revision; the
   draft gestured at chat surfaces without design content.
6. *Prior art* — draft covered Claude Code, Codex, sudo, OPA/Cedar; revision added mobile OS
   permissions as a full fifth entry (it was previously a citation inside §2) so that each
   examined system gets the does-well/steal/avoid treatment the bar requires.
7. *Failure modes* — draft had F1–F5 and F8; F6 (fatigue attacks) and F7 (approximate taint) were
   added in revision — the critique found exfiltration's conjunction problem asserted in §1 but
   never honestly treated as an unsolved design problem.
8. *Recommendation* — the §8.2 mapping to prior sections was expanded from a paragraph to the
   per-risk/per-principle/per-failure enumeration, after the critique found the draft justified
   the *what* but only loosely tied back to §§1–7 as required.
9. *Quality* — filler audit: removed two rhetorical sentences and one duplicated explanation of
   deny-by-default (kept in P1, removed from §4.3). This section is the record of the pass.

**Second pass (post-draft re-check against items 1–8):**

- Item 4 failed on re-read: §4.1 claimed "the agent core's entire relationship with policy is one
  call" while §4.2 listed `simulate` and the grant store as component responsibilities — but no
  call carried the human's `ask` answer back into the component. The interface was amended to four
  calls (`decide`, `resolve`, `simulate`, `reload`), a decision `id` field was added so an `ask`
  can be resolved against it, and `resolve` now explicitly owns grant creation and the F2 audit
  record.
- Cross-reference bug found and fixed: the TOCTOU bullet cited "§7.4", but §7's failure modes are
  F-numbered — corrected to F3, and all other section references were re-grepped and verified.
- Items 1–3 and 5–8 re-checked and passed without further change.

All nine bar items checked after revision; no known gaps remain.
