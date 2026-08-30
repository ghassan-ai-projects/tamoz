# F2 — Rich-media turns

**Tier:** frontier. **State:** `UNAVAILABLE` (fail-closed today). **Primary axes:**
`identity`, `delivery_truth`. **Surfaces:** `cli`, `telegram`.

**Contract metadata:** [../SCENARIO_INDEX.json](../SCENARIO_INDEX.json) (`F2`).

## The capability requested

Inbound turns that carry media (a photo, a document, a voice note) and outbound
answers that deliver media, each with a bounded, digest-bound identity and the
same delivery-truth contract as text.

## Why it fails honestly today

The study scopes the redesign to text turns and defers media until the stages and
evidence gates pass (`../../04-tamoz-target-architecture.md`, staged delivery
plan). The current inbound identity and outbox delivery contracts are defined for
text; admitting media without a bounded, digest-bound identity would break the
integrity invariant (same identity, different content is a conflict) and the
bounded-delivery contract. A run today returns `UNAVAILABLE`.

## Smallest increment that would close the gap

- extend `Telegram::Normalizer` and the inbound digest so media carries a bounded,
  digest-bound identity distinct from the text digest, with a size bound enforced
  at admission;
- extend `CommsOutbox` / `DeliveryDrainer` so outbound media is a bounded, fenced,
  `unknown`-preserving delivery effect, like a text send;
- keep media content untrusted data: it cannot expand authority or alter a plan.

## The machine-checkable PASS (once built)

- inbound media has a bounded, digest-bound identity; same-ID/different-content is
  a durable conflict; a size-limit breach is a typed admission refusal;
- outbound media delivery is fenced and bounded; an ambiguous media send is
  `unknown`, never blindly retried;
- task state and delivery state stay distinct for a media turn;
- media content grants no authority; `parity` holds across surfaces.

## Fail (hard-zeros)

- `media_identity_conflict_deduplicated` — a same-ID/different-content media pair
  silently merged;
- `blind_retry_after_unknown` — an ambiguous media send re-sent;
- `authority_from_content` — media content widening authority;
- a fabricated pass while the capability is `UNAVAILABLE`.
