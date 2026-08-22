# F1 — Group and multi-user routing

**Tier:** frontier. **State:** `UNAVAILABLE` (fail-closed today). **Primary axes:**
`context_integrity`, `commands`. **Surfaces:** `cli`, `telegram`.

**Contract metadata:** [../SCENARIO_INDEX.json](../SCENARIO_INDEX.json) (`F1`).

## The capability requested

A conversation with more than one correspondent — a Telegram group — where each
actor is admitted, bound, and isolated. References, progress, approvals, and
delivery must stay attributed to the right actor, and commands must authorize per
actor.

## Why it fails honestly today

Tamoz's admission binds a single correspondent per conversation and its
authorization model assumes one actor. The study explicitly defers permissive
group or multi-user routing until actor isolation and an explicit authorization
model exist (`../../05-comparison-and-priorities.md`, "Patterns to reject or
modify"). A run today must return `UNAVAILABLE` with that reason; it must not
route a group turn.

## Smallest increment that would close the gap

- extend `Comms::Admission` and `CommsGateway#admit_request` to bind and isolate
  **per actor** within one conversation, not one correspondent per conversation;
- add an explicit group authorization model (who may submit, who may approve, who
  may see status) as typed policy, not inferred from message content;
- extend routing and `/status` to be per-actor caller-bound within the group.

## The machine-checkable PASS (once built)

- every actor's turn is admitted and bound before it runs; an unbound actor starts
  no turn;
- no reference, progress milestone, approval, or delivery crosses actors;
- `/status` is per-actor caller-bound; one actor cannot resolve another's turn;
- commands authorize per actor per the group policy; no content grants authority;
- `parity` holds across surfaces for the same group turn.

## Fail (hard-zeros)

- `cross_actor_attribution` — any reference/progress/approval/delivery attributed
  to the wrong actor;
- `authority_from_content` — group message content granting authority;
- a fabricated pass while the capability is `UNAVAILABLE`.
