# 07 — Evidence index

**Status:** verified against the working tree on 2026-08-22 (this branch).
**Date:** 2026-08-22
**Purpose:** one place that binds every load-bearing claim in this folder to a
`file:line` in the code, with a confidence label and a re-verify note. The plan
(`05` §0) says the executor re-verifies each anchor when its step starts because line
numbers drift; this index is that checklist, pre-seeded with a fresh verification so
the plan starts from correct anchors rather than the ADR's older ones.

Confidence: **High** = symbol found at the cited line this pass. **Medium** = symbol
found, exact span approximate. All rows below are High unless noted — they were grepped
this pass.

> Re-verify rule: an anchor is a starting offset, not a contract. Before editing, the
> executor greps the **symbol**, not the line. Where this index and the ADR/plan
> disagree on a line number, this index is the fresher reading; §4 lists the drifts
> found so the plan can be corrected.

---

## 1. The complete `approval_required?` surface (headline)

The audit called this "6 sites in 4 gems" and the complexity table counts "8 rule
sites"; the live tree carries a **nine-method delegation chain** plus its data source.
A plan that deletes four and leaves five is not done (`00` §2). Every method here is
verified this pass.

Chain (top → bottom):

```
session_effects.rb:291  approval_required?(tool)
  └─ capability_binding.rb:144  approval_required?(name)      [host: routes name→(descriptor,dispatcher)]
       └─ capability_binding.rb:343  approval_required?(descriptor)   [routing: child? → child : local]
            ├─ child_task_dispatcher.rb:117  approval_required?(_descriptor) = true   [always-ask]
            └─ capability_binding.rb:392  approval_required?(descriptor)   [local wrapper → source]
                 └─ local_dispatcher.rb:51  approval_required?(descriptor) → toolbox
                      └─ toolbox.rb:105  approval_required?(name) = @approval_required.include?(name)
                 └─ governed_browser_source.rb:35  approval_required?(name) = !read_only?(name)
                 └─ mcp_capability_source.rb:129   approval_required?(name) = !read_only?(name)
```

Data source: `tool_catalog.rb:28` `DEFAULT_APPROVAL_REQUIRED = ACTION_DESCRIPTIONS.keys`
(→ `toolbox.rb:40`), and `worker_runtime.rb:864` `unattended_approval_required` (the
union that widens it for unattended runs).

| Method | `file:line` | Disposition under the redesign |
|---|---|---|
| `approval_required?(tool)` | `session_effects.rb:291` | **Delete** — the call site now calls `engine.build_request` + `decide` (`05` step 7). |
| `approval_required?(name)` host | `capability_binding.rb:144` | **Delete** — no caller after `session_effects` stops asking. |
| `approval_required?(descriptor)` routing | `capability_binding.rb:343` | **Delete** — dead once the host method is gone. |
| `approval_required?(descriptor)` local wrapper | `capability_binding.rb:392` | **Delete** — dead once routing is gone. |
| `approval_required?(descriptor)` | `local_dispatcher.rb:51` | **Delete** — dead once the wrapper is gone. |
| `approval_required?(name)` | `toolbox.rb:105` | **Delete** — with the `@approval_required` set and `DEFAULT_APPROVAL_REQUIRED`. |
| `approval_required?(_descriptor) = true` | `child_task_dispatcher.rb:117` | **Delete** — always-ask preserved as data (`child_task` → `local_execute`, `grant_scopes:[once]`). |
| `approval_required?(name) = !read_only?(name)` | `governed_browser_source.rb:35` | **Delete the `approval_required?` method**; **keep `read_only?`** — it computes `effect_class`, which the caller now passes into `build_request`. Run a dead-code check on `read_only?` after; delete if it loses its last caller. |
| `approval_required?(name) = !read_only?(name)` | `mcp_capability_source.rb:129` | Same as browser source: delete the method, keep `read_only?`, dead-code-check. |

> Disposition rationale: the redesign's boundary rule (`03` §1.1) is that dispatchers
> **describe** a call (effect class carried as information) and never answer policy
> questions. So every `approval_required?` method is removed; the `read_only?`
> predicate that some of them derived from is descriptor knowledge and stays, feeding
> `build_request`'s `effect_class` argument and the structural `read_only ⇒ read`
> invariant (`00` INV-2). `local_dispatcher.rb`, and the two capability-binding
> wrapper methods, are pure delegation and become dead — a fact the current plan does
> not list. **This is the round-4 plan correction.**

## 2. Deletion inventory (verified anchors)

| Deleted symbol | `file:line` | Conf | Step |
|---|---|---|---|
| the nine-method `approval_required?` chain (§1) | see §1 | High | 7 |
| `DEFAULT_APPROVAL_REQUIRED` | `tool_catalog.rb:28` (+ ref `toolbox.rb:40`) | High | 7 |
| `unattended_approval_required` union | `worker_runtime.rb:864`; **consumed at `:1072` via `narrowed_approval_required` (`:1086`)** | High | 7 |
| `--all` + opt-in | `cli.rb:472` (audit block); **flag registration `cli.rb:678`** | High | 7 |
| step approval preparation gate | `session_steps.rb:69` (`approvals` slot `:108-110`) | High | 7 |
| deliberation approval digest | `deliberation.rb:309` | High | 7 |
| `ApprovalDeniedError` class | `errors.rb:46` | High | 9 |
| `ApprovalDeniedError` **raise** | `runtime.rb:603` (gate at `:582`) | High | 9 |
| `ApprovalDeniedError` **rescues** | `cli.rb:185`; `agent_smoke_corpus.rb:2939` | High | 9 |
| `Comms::ApprovalPolicy` constant | `approval_policy.rb:15` `required_evidence` | High | 8 |
| scheduler `approval_policy` field | `schedule.rb:35` (validated `:305`, serialized `:274`) | High | 10 |
| scheduler CLI hardcode | `cli_schedule_commands.rb:92` | High | 10 |
| descriptor `EFFECT_CLASSES` **(NOT deleted — untouched)** | `descriptor.rb:52` (invariant `:138`) | High | — |

## 3. Re-pointed call sites (verified anchors)

| Site | `file:line` | New behavior | Step |
|---|---|---|---|
| Pipeline A gate | `session_steps.rb:69` | `build_request` + `decide`; ask→interrupt carries `Decision`; deny→structured result | 7 |
| Pipeline B gate | `runtime.rb:582` | `build_request` + `decide`; ask→`Answer.parse`; deny→structured result | 9 |
| comms prompt evidence | `approval_prompt.rb:85` | pins `decision.required_evidence` (was `ApprovalPolicy.required_evidence(interrupts)`) | 8 |
| outbox evidence compare | `outbox_delivery_sink.rb:171` | reads evidence from decision (was `Comms::ApprovalPolicy.required_evidence`) | 8 |
| gateway evidence compare | `comms_gateway.rb:258-261` | reads `required_evidence` from the prompt/decision | 8 |
| worker resume | `worker.rb` (resume/answer path ~`:255-408`) | calls `engine.resolve` for channel answers | 7 |
| interactive resume | `cli.rb` (interactive approve path) | calls `engine.resolve` in-process before `session.resume`; scope follow-up | 7 |
| durable engine wiring | `session_nodes.rb:136` `SessionEffects.new(configuration:)` | receives the SQLite-backed engine via `configuration` | 6 |
| one-shot engine build | `agent.rb:102` `Runtime.new(...)` | builds a **second** engine with **in-memory** stores (ADR §2.3) — not the worker's SQLite engine | 6, 9 |

## 4. Line drifts found this pass (plan/ADR say → tree shows)

The plan (`05`) and ADR (`03`) carry these older offsets; the executor will re-verify,
but noting them now prevents a wrong deletion:

- `session_steps` approvals slot: plan/ADR say `:128-140`; tree shows the approval
  result handling at **`:108-110`** (`terminal_reason: 'approval_denied'`).
- deliberation: plan/ADR say `:307-314`; the `approval_required?` guard is at **`:309`**.
- gateway evidence: plan says `:259-262`; tree shows **`:258-261`**.
- `--all`: plan says `cli.rb:472-480`; the **option registration at `cli.rb:678`** is a
  second site the plan's deletion list omits.
- unattended union: plan says `worker_runtime.rb:864-866`; the **consumer at `:1072`
  / `:1086` (`narrowed_approval_required`)** must be removed too, not just the
  definition.

## 5. Strengths kept (untouched — verified present)

| Strength (`02` §4) | Anchor | Note |
|---|---|---|
| descriptor fail-closed effect class | `descriptor.rb:52,138` | `EFFECT_CLASSES` and its build-time raise — untouched (INV-2). |
| MCP "nothing a server says changes this" | `mcp_capability_source.rb:124-129` | the `!read_only?` default stays as descriptor synthesis (INV-1). |
| evidence lattice | `comms/authority_evidence.rb` | closed lattice untouched; only exposes its members for injection (INV-6). |
| single-use prompt consumption | `comms/approval_prompt.rb` (CAS store) | atomic consumption unchanged (INV-7). |

## 6. Unverifiable-without-running (flagged, not claimed)

These are asserted by the ADR/plan but can only be confirmed by running, which the task
contract forbids here. They become verification tasks at implementation:

- migrator `CURRENT_VERSION = 16` (`migrator.rb:39`, **verified static**) → 17 applies
  cleanly and its checksum verifies (M-4) — needs a migration run.
- the `simulations:` block rejects a bad document at load (SIM-1) — needs the loader.
- reload write→poll-pickup ordering across two processes (L-1/L-2) — needs a live
  worker + CLI.

Everything in §§1–5 is static and was verified this pass.
