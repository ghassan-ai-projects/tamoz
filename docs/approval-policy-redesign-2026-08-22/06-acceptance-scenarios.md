# 06 — Acceptance scenarios

**Status:** authoritative acceptance suite for the redesign.
**Date:** 2026-08-22
**Source:** the fixes in `03-redesign-adr.md`, the threat cases in
`04-review-security.md`, and the invariants/hard-zeros in `00-acceptance-bar.md`.

These are the end-to-end journeys the finished system must pass. Each is an acceptance
test, not a unit test: it describes an operator-visible outcome, names the invariant or
hard-zero it guards (`00` §4/§5), and names the plan step (`05`) that must make it pass.
A step is not done until its mapped scenarios pass **and** none that previously passed
regress (`00` §6).

Fixture/scripted models drive these; that proves the *plumbing and invariants*. Whether
the shipped `policy/base.yaml` is *well authored* is proven by its own `simulations:`
block (SIM-1) and a real run, never by these fixtures alone (`00` §2, owner directive
"real LLM, never fake").

## Legend

- **HZ** — this scenario is a hard-zero (`00` §5): failing it fails its step outright.
- **INV-n** — the global invariant (`00` §4) it guards.
- **Step** — the `05-implementation-plan.md` step that owns it.

---

## 1. Core allow / deny / ask

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| C-1 | a `read_file` on a normal workspace path → `decide` → **allow** (tier `read`, no prompt). | INV-2 | 3 |
| C-2 | a `read_file` on `**/.env` → `decide` → **deny**, reason names `credential-files`. | INV-4 | 3 |
| C-3 **HZ** | a `read_file` on a workspace symlink resolving to `~/.ssh/id_rsa` → **deny**; the realpath is matched, not the link. | INV-9 | 3 |
| C-4 | a `write_file` inside the workspace → **allow** (tier `workspace_write` default allow). | INV-11 | 3 |
| C-5 | a `run_check` → **ask**, `grant_offer` includes `:once` and `:session`. | — | 3 |
| C-6 | a `git push --force` (argv rule) → **ask**, reason names `force-push`. | — | 3 |
| C-7 **HZ** | a tool absent from `tool_tiers` → **ask** (fallback), never allow. Nothing the tool's own metadata says changes this. | INV-1 | 3 |
| C-8 | an unknown-effects MCP tool (`mcp:*`) → **ask**, `grant_offer` is `:once`-only. | INV-3 | 3 |

## 2. Deny-ordering (the sudoers-opacity hole)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| O-1 **HZ** | a document with a broad `allow` rule appended **after** `credential-files` → loads, but `read .env` still **denies**: deny rules evaluate first regardless of document order. | INV-4 | 2, 3 |

## 3. Grants (the over-bundling hole, `04-review-security` #1)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| G-1 | approve `run_check(lint)` with scope `:session` → a second `run_check(lint)` in the same session **auto-allows** (grant hit), no prompt. | INV-5 | 3 |
| G-2 **HZ** | after G-1, `run_check(test)` → **ask**: the grant key includes `key_argv` (the check name), so one check's grant never covers another. | INV-3 | 3 |
| G-3 **HZ** | an unknown-effects MCP tool's `:ask` offers `:once`-only; attempting to `resolve` it with scope `:session` → `InvalidScopeError`. One approval is never session-wide authority over opaque argv. | INV-3 | 3 |
| G-4 **HZ** | `child_task` → **ask** every time, even after any session grant elsewhere in the session; its `grant_offer` is `:once`-only. | INV-3 | 3, 7 |
| G-5 | a `local_execute` request with no path targets → its session key is degenerate → grant **degrades to `:once`**. | INV-3 | 3 |
| G-6 | a child session inherits the parent's profile but starts with an **empty** grant view (grants match `session_id`). | INV-3 | 7 |

## 4. Resolve idempotence (`04-review-security` #2)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| RS-1 **HZ** | a fenced-claim crash-recovery replays `resolve(id, same answer, same scope)` → returns the **originally recorded grant**, no crash, no second grant row. | INV-5, INV-10 | 3 |
| RS-2 | `resolve(id, different answer or scope)` on an already-resolved id → `ConflictingResolutionError`. | INV-10 | 3 |
| RS-3 | `resolve(unknown or expired id, …)` → `UnknownDecisionError`. | — | 3 |
| RS-4 | `resolve(id, scope the offer did not include)` → `InvalidScopeError`. | INV-3 | 3 |

## 5. Denial as data (audit §5.6)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| D-1 **HZ** | a `:deny` verdict → the model receives a **structured tool result** ("denied: <reason>, rule <rule_id>"); the turn **continues** and can course-correct. No `ApprovalDeniedError` is raised or rescued anywhere. | contract 5 | 7, 9 |
| D-2 | a model that re-issues the same denied action in a loop → the existing repeated-action guard terminates the turn with a typed reason (a steered flood is a replan loop). | — | 7 |
| D-3 **HZ** | the one-shot runtime denial path returns the **same** structured result as the durable session — the callback-plus-exception contract is gone. | contract 5 | 9 |

## 6. Reload delivery + in-flight semantics (`04-review-simplicity` #1, `04-review-security` #4)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| L-1 | `tamoz approve --reload <valid path>` → the document validates in the CLI process, `(policy_path, policy_rev)` is written to `tamoz_approval_active_policy`, and a worker picks up the new rev on its next poll pass / at session start and calls `engine.reload`. | — | 6 |
| L-2 **HZ** | `--reload <document that fails validation>` → the active-policy row is **untouched**; live workers keep running the previous rev. A broken edit can never take the system down. | contract 7 | 2, 6 |
| L-3 | reload mid-run → the in-flight session keeps its **bound** `policy_rev` until it ends; only new sessions bind the new rev. | contract 8 | 3, 6 |
| L-4 | a parked `:ask` when a reload lands → resolves against its **issuing decision** (stored `grant_offer`), unaffected by the new policy. | contract 8 | 3 |
| L-5 **HZ** | a `:session` grant from the old rev, after a reload → **never matches** (lookup is keyed on the session's bound rev); no grandfathering, fail-closed at read time. | INV-3 | 3, 5 |

## 7. Timeout semantics (`04-review-simplicity` #3, `04-review-api` #6)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| T-1 | attended profile (`on_timeout: park`), the channel prompt lapses at `timeout_s` → the turn stays parked and the decision is **still resolvable** through `tamoz approve <id>`. An attended run whose human walked away is recoverable, not bricked. | — | 7 |
| T-2 | unattended profile (`on_timeout: deny`), prompt lapses → the worker's poll pass resolves the ask to a **structured denial**; the turn ends with a stated outcome. | — | 7 |
| T-3 | a human answer and a timeout landing together → decided by `resolve` idempotence: whichever lands first wins, the loser is a no-op. | INV-10 | 7 |

## 8. Evidence from data (audit §5.3)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| E-1 | an approve prompt pins `filesystem_operator` and a deny pins `chat_bound` — both read from the `Decision`, not a Ruby constant; comms maps the symbol onto its lattice at the boundary. | INV-6 | 8 |
| E-2 **HZ** | a policy document whose `evidence:` block names a non-member symbol (`filesystem_operater`) → **rejected at load** against the injected symbol set, never a mid-turn prompt-build raise. | INV-6 | 2, 4 |

## 9. Answer vocabulary + interactive scope (`04-review-security` #5, missed-req)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| V-1 | the one-shot CLI accepts the full vocabulary (`a`/`approve`, `d`/`deny`) via `Answer.parse` — the two-dialect split is gone. | INV-11 | 1, 9 |
| V-2 | an interactive-CLI approval whose `grant_offer` includes `:session` → one follow-up ("remember for this session? [y/N]"), `resolve` called **in-process before `session.resume`**, the grant minted and the human answer logged. Session grants exist in the primary interactive UX, not only for channel answers. | INV-8 | 7 |

## 10. Decision log + simulation-as-data (`04-review-simplicity` #5/#11)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| LG-1 | every `decide` appends one record with `tool`/`verb`/`tier`/`rule_id` **cleartext** and argv/targets as **digests only**; `resolve` appends the human answer and scope. "Why was this asked/denied" is answerable from the database alone. | INV-8 | 3, 5 |
| LG-2 | a graph-node retry re-appending the same `decision_id` → **idempotent**, no double-write. | INV-10 | 3, 5 |
| SIM-1 **HZ** | the bundled `policy/base.yaml`'s own `simulations:` block runs at load; a document whose simulation expectation fails is **rejected**. The policy content is pinned by data, not a Ruby side-copy (no policy literals in Ruby). | INV-11, contract 7 | 2 |

## 11. Mid-session mode switch (ADR §2.6)

The one bounded exception to in-flight rev stability. Modes are profiles
(`plan`/`review`/`implement`/`auto`/bounded `bypass`); a switch rebinds one session's
approval profile, live.

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| MS-1 | mid-session `--mode auto` on a session that was asking for `local_execute` → the next `run_check` **auto-allows**, no prompt; agent roles/budgets/tools are unchanged. | INV-13 | 7B |
| MS-2 | mid-session `--mode review` (tighten) → a session grant minted under the old mode **no longer matches** (rev mismatch); the next covered call **asks**. Loosening later mints new grants going forward, never resurrects old-rev ones. | INV-3, INV-13 | 7B |
| MS-3 | a switch lands while an `:ask` is parked → the parked ask still resolves against its **issuing decision** (unchanged); the new mode governs only the next decision. | contract 8, INV-13 | 7B |
| MS-4 **HZ** | a switch across worker restart → applied **exactly once**; an already-approved or in-flight step is **never re-decided or reversed**. | INV-10, INV-13 | 7B |
| MS-5 **HZ** | a switch on thread A → thread B's mode is **unchanged**; the rebind is `session_id`-scoped and never global. | INV-13 | 7B |
| MS-6 | mid-session `--mode plan` → subsequent `write_file`/`run_check` **deny** as structured results, the turn continues read-only; a global `--reload` in the meantime does **not** change this session's chosen mode. | contract 7, INV-13 | 7B |

## 12. Migration discipline (owner directive, `00` §5)

| ID | Given → When → Then | Guards | Step |
|---|---|---|---|
| M-1 **HZ** | at no commit between steps 6 and 7 does the tree contain **two policy owners**: the engine deciding while the old `approval_required?` chain still fires. Convergence and the chain deletion land together. | contract 1 | 7 |
| M-2 **HZ** | an operator profile file still carrying `tools.approval_required` or `unattended.*` → **fails validation loudly at load**; it is never accepted-but-ignored. | contract 1 | 2, 7 |
| M-3 | after step 12 the grep sweep returns zero live references to `approval_required`, `ApprovalDeniedError`, `ApprovalPolicy`, `--i-understand-approve-all`, `tools.approval_required` outside this `docs/` folder and `CHANGELOG.md`. | — | 12 |
| M-4 **HZ** | migration 17 applies on a fresh database and its checksum verifies; migrations 1–16 and their checksums are **untouched**; no old-row handling exists. | — | 5 |

---

## Coverage check

Every audit weakness (`02` §5, all 11) and every review MUST/SHOULD-FIX (`03` §10) is
exercised by at least one scenario above:

| Audit weakness / review finding | Scenario(s) |
|---|---|
| W1 three mechanisms one word; W2 no single classifier | C-1..C-8, M-1 |
| W3 evidence is a hardcoded constant | E-1, E-2 |
| W4 no timeout semantics / blocks forever | T-1, T-2, T-3 |
| W5 no scoped grants / `--all` floodgate | G-1..G-6, V-2 |
| W6 denial terminal and silent | D-1, D-2, D-3 |
| W7 policy entangled across gems | M-1, M-3 |
| W9 two answer vocabularies | V-1 |
| W10 dead scheduler hash | M-3 (sweep) |
| Sec #1 over-bundling | G-2, G-3, G-4, G-5 |
| Sec #2 resolve idempotence | RS-1..RS-4 |
| Sec #3 deny order | O-1 |
| Sec #4 reload / in-flight | L-1..L-5 |
| Sec #6 evidence validation | E-2 |
| Sec #9 symlink | C-3 |
| Simp #1 reload delivery | L-1, L-2 |
| Simp #5 simulation-as-data | SIM-1 |
| API #1 effect_class provenance | C-1, C-7 (fail-closed classification from the `tool_tiers` map) |
| API #2 single canonicalization seam | C-3 (realpath in `build_request`), G-2 (key from canonical request) |

W8 (polling resume) and W11 (prompt-activation coupling) are argued not-fixed
(`03` §3) and deliberately have no scenario: they assert *unchanged* transport, pinned
by the existing comms/stream suites the plan repoints, not by a new acceptance journey.
