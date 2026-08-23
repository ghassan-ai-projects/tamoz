# Subagent orchestration — lessons and standing protocol

How to delegate work to background subagents in this repo efficiently. Written during the
approval-policy redesign (2026-08) after measured friction; follow it unless a task visibly
doesn't fit.

## Failure modes observed (each cost real wall-clock time)

1. **Mid-flight renegotiation is lagged.** A correction message sent to a running agent waits
   for its current turn to end before landing — budget one full work-turn of latency per
   correction. Three corrections to one agent redirected ~30 minutes of work. Everything
   correctable must therefore be front-loaded into the initial brief.
2. **Shared-file contention produces phantom failures.** Two writers on one file (or on
   `test/support/*`) surface as transient red suites that both sides waste time diagnosing.
   Ownership must be enumerated per file, including support fixtures.
3. **Undocumented behavior shifts break fixtures silently.** When a change moves semantics
   (e.g., which tools ask for approval), tests written against the old model fail in ways the
   agent cannot distinguish from its own bugs unless the NEW model is stated in the brief.
4. **Hygiene drift.** Scratch probe files left in the repo root; sandbox umask creates
   non-world-readable files that break gemspec packaging gates later.

## Hard runtime cap

**No agent run exceeds 60 minutes.** State the expected budget in the brief and scope the work
to fit (~30–40 minutes of actual work). An oversized phase is decomposed into pipelined smaller
agents, not tolerated as one marathon. Two reasons, both measured:

- A running agent executes as ONE turn: queued correction messages stay parked undelivered until
  it finishes. Mid-flight steering is impossible; the brief must be final at launch.
- The shared uncommitted tree makes interruption cheap: interrupt-and-salvage loses in-flight
  reasoning only, never work product. Prefer a deadline plus salvage over an open-ended wait.

Monitoring without messaging: each agent appends one line per completed unit to
`/tmp/tamoz-agents/<name>.log` (required by the housekeeping clause); the orchestrator checks
file mtimes there and in owned trees for liveness, and can start a background sleep job as a
watchdog that fires at the cap.

## Standing brief protocol

Every implementation-agent brief contains, up front:

- **Environment block**: rbenv PATH export (`export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"; eval "$(rbenv init -)"`), tests ONE FILE PER COMMAND (`ruby -Itest` with multiple files runs only the first), never `bundle install`, no linting/styles, no commits (integrator commits), no backwards-compat shims.
- **File ownership contract**: three explicit lists — owned / forbidden / read-only. Include `test/support/*.rb` assignments explicitly. Check `git status --short` claims against reality when a file might be dirty from someone else.
- **New behavior model**: the post-change semantics tests must assert, stated as assertions ("assert THIS, do not soften").
- **Named gate suites** (~8 max) plus an explicit known-red list the agent must not chase.
- **Report format**: files changed (one line each) · exact commands + pass counts · deviations with reasons · grep/diff proof for any "deleted everywhere" claim.
- **Housekeeping clause**: `chmod 644` every created file; zero scratch files left anywhere in the repo.

## Structural patterns that paid off

- **Parallelize disjoint phases**, pin the seam: two phases over disjoint gem surfaces run as
  two simultaneous agents with forbidden-lists marking the boundary; name any already-finished
  code as frozen ("DONE — do not touch") rather than hoping nobody drifts into it.
- **Batch reviews as lens pairs**: one reviewer agent per pair (correctness+soundness,
  architecture+duplication) instead of four singles; give reviewers the diff range AND the list
  of accepted deviations verbatim so they spend time on findings instead of re-deriving settled
  decisions.
- **Integrator keeps judgment work**: commits, cross-phase verification, docs, and end gates
  stay with the orchestrator; agents get bounded mechanical or self-contained design work.
- **Pre-draft briefs before they can fire** so launch is immediate when a dependency lands;
  re-read tree state first so ownership lists reflect what actually happened.

## Brief skeleton (copy per launch)

```
# <Phase N> brief — <title>
Repo/branch. Read plan step N + scenarios FIRST.
[environment block]
## New behavior model (assert THIS, do not soften)
- ...
## You own
- paths...
## Forbidden (other agents/me own these)
- paths...
## Gates (+ known-red list: suites NOT yours, with one-line reasons)
## Report format
files changed | commands + pass counts | deviations with reasons | proof grep
```
