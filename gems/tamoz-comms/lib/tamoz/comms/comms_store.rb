# frozen_string_literal: true

module Tamoz
  module Comms
    # Structural contract for the channel store (design §13). `tamoz-sqlite`
    # implements it as an explicitly required module (dependency rule 9, exactly
    # as StreamStore is implemented today); the integration layer that loads
    # both verifies the CONTRACT_VERSION pair, and `tamoz-evals` audits it.
    #
    # Every primitive is transaction-bound, names its idempotency/conflict
    # result, and binds the caller's clock (`now:`) so behavior is
    # deterministic under an injected clock and kill-consistent. Admission
    # shares the request-inbox enqueue seam inside ONE transaction; prompt
    # consumption inserts its decision in the same transaction (ADR-043).
    #
    # The signatures below ARE the contract — the bodies raise because a
    # contract module has nothing to implement.
    # :reek:UnusedParameters, :reek:LongParameterList
    # rubocop:disable Metrics/ParameterLists -- the signatures ARE the §13
    #   contract; every field is mandatory at the seam.
    module CommsStore
      CONTRACT_VERSION = 2

      # Deploy one surface revision (upsert, digest-addressed).
      # @return [:deployed, :duplicate]
      def deploy_surface(descriptor_wire, now:)
        raise NotImplementedError
      end

      # Admit ONE inbound update AND enqueue its turn in one transaction.
      # `bot_id` is the authenticated surface identity the update arrived on;
      # `reservation` is the terminal capacity reserved at admission
      # (invariant 57). Intake limits — max_open_requests, max_inbound_bytes,
      # and outbox_capacity — are enforced from the DEPLOYED surface row:
      # pending+claimed deliveries plus open reservations must stay under
      # outbox_capacity, so the reserved terminal answer can always append
      # (design §12, scorecard case 16). The first durable observation of
      # (surface, bot, update_id) anchors dedup: an exact digest replay is
      # :duplicate, and the SAME identity under a DIFFERENT payload digest is
      # a durable integrity conflict recorded on the ONE anchor row — its
      # conflict counter advances, nothing is enqueued (invariant 1).
      # @return [:enqueued, :duplicate, :integrity_conflict, :open_request_limit, :inbound_too_large, :capacity_refused]
      def admit_and_enqueue(envelope_wire, surface_id:, bot_id:, thread:, profile_id:, reservation:, now:)
        raise NotImplementedError
      end

      # Record a non-request disposition durably. A conflicting digest for a
      # KNOWN update identity updates that identity's single anchor row and
      # returns :conflict_recorded.
      # @return [:recorded, :conflict_recorded, :duplicate]
      def disposition_only(envelope_wire, surface_id:, bot_id:, disposition:, reason:, now:)
        raise NotImplementedError
      end

      # Append one delivery. `reserved_request_id` carries the request whose
      # admission reservation covers this terminal/prompt row (design §12);
      # control rows pass nil. Terminal projection is the caller's completion
      # signal — `complete_request` releases the reservation afterwards.
      # @return [:appended, :duplicate, :capacity_refused]
      def append_delivery(delivery_wire, surface_id:, capacity:, now:, reserved_request_id: nil)
        raise NotImplementedError
      end

      # Terminal projection is durable; release the request's reserved slots.
      # @return [:released, :not_admitted]
      def complete_request(thread_id:, request_id:)
        raise NotImplementedError
      end

      # One fenced poller per authenticated bot; an expired lease is
      # recoverable.
      # @return [:acquired, :not_acquirable]
      def acquire_poller_lease(surface_id:, bot_id:, owner:, fence:, ttl_s:, now:)
        raise NotImplementedError
      end

      # Persist the candidate next_offset ONLY after the returned prefix is
      # durable. Never regresses.
      # @return [:persisted, :behind]
      def persist_next_offset(surface_id:, bot_id:, next_offset:, now:)
        raise NotImplementedError
      end

      # Claim one outbox row under a fenced lease for a transport attempt.
      # @return [:claimed, :not_claimable, :missing]
      def claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
        raise NotImplementedError
      end

      # Reserve the next durable send slot for one chat and the surface-wide
      # lane. The returned delay is safe for concurrent drainers.
      def reserve_delivery_slot(surface_id:, conversation_id:, per_chat_messages_per_s:, global_messages_per_s:, now:)
        raise NotImplementedError
      end

      # Return a claimed row to pending only for a typed, proven-not-sent
      # transport refusal such as a server throttle.
      def release_delivery_claim(delivery_id:, owner:, fence:, now:)
        raise NotImplementedError
      end

      # Mark an attempt immediately before crossing the transport boundary.
      # An expired row with this marker is resolved to unknown, never retried.
      def mark_delivery_send_started(delivery_id:, owner:, fence:, now:)
        raise NotImplementedError
      end

      # Record a transport outcome for a CLAIMED row — fenced (invariant 4):
      # the update must match the claim's owner AND fence, so a stale caller
      # records nothing and takes no external action. `succeeded` carries the
      # receipt; `unknown` is the honest ambiguity state.
      # @return [:marked, :not_claimable]
      def mark_delivery(delivery_id:, owner:, fence:, status:, now:, receipt: nil)
        raise NotImplementedError
      end

      # Resolve crashed attempts whose transport boundary was already crossed.
      def reconcile_expired_deliveries(now:)
        raise NotImplementedError
      end

      # Persist a provider retry deadline in the pacing lane.
      def defer_delivery(surface_id:, conversation_id:, not_before:, now:)
        raise NotImplementedError
      end

      # Read-only channel status derived from durable admission/projection
      # rows. Reference-addressed and queue-aware: when anything is admitted,
      # the projection carries the active request's short reference
      # (`request_ref`) and its queue facts (`queue_age_ms`, `queue_position`);
      # with nothing admitted those keys are absent. `now:` binds the reader's
      # clock for age arithmetic; without it the store's backend time answers.
      def conversation_status(surface_id:, conversation_id:, now: nil)
        raise NotImplementedError
      end

      # Resolve ONE request by its short reference inside ONE conversation —
      # caller-bound, never cross-conversation.
      # @return [Hash] the full status projection plus `terminal_reason`
      # @return [:unknown_ref] no request in this conversation matches
      # @return [:ambiguous_ref] several requests share the ref prefix
      def request_status(surface_id:, conversation_id:, ref:, now: nil)
        raise NotImplementedError
      end

      # The bound conversation's durable /new generation.
      # @return [Integer]
      def conversation_generation(surface_id:, conversation_id:)
        raise NotImplementedError
      end

      # Durably advance the generation by one and return the new value;
      # raises when the conversation row is absent, mutating nothing.
      # @return [Integer]
      def bump_generation(surface_id:, conversation_id:)
        raise NotImplementedError
      end

      # Bind one outbox row to its effect journal entry (design §10).
      # @return [:bound, :conflict, :missing]
      def bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
        raise NotImplementedError
      end

      # Activate one approval prompt after its send receipt is durable.
      # @return [:activated, :already_active, :missing, :expired]
      def activate_prompt(reference_digest:, now:, receipt:)
        raise NotImplementedError
      end

      # Consume one ACTIVE prompt and insert its decision in ONE transaction.
      # @return [:consumed, :not_consumable, :missing, :expired]
      def consume_prompt(reference_digest:, decision_wire:, now:)
        raise NotImplementedError
      end

      # Revoke one binding; atomically invalidates its unused (inactive)
      # approval prompts.
      # @return [:revoked, :missing]
      def revoke_binding(correspondent_id:, surface_id:, reason:, now:)
        raise NotImplementedError
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
