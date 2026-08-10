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
      CONTRACT_VERSION = 1

      # Deploy one surface revision (upsert, digest-addressed).
      # @return [:deployed, :duplicate]
      def deploy_surface(descriptor_wire, now:)
        raise NotImplementedError
      end

      # Admit ONE inbound update AND enqueue its turn in one transaction.
      # `bot_id` is the authenticated surface identity the update arrived on;
      # `reservation` is the terminal capacity reserved at admission
      # (invariant 57) and `capacity` is the surface's outbox_capacity — intake
      # refuses while pending+claimed deliveries plus open reservations would
      # meet it, so the reserved terminal answer can always append (design §12,
      # scorecard case 16). The derived request id dedups replays.
      # @return [:enqueued, :duplicate, :capacity_refused]
      def admit_and_enqueue(envelope_wire, surface_id:, bot_id:, thread:, profile_id:, reservation:, capacity:, now:)
        raise NotImplementedError
      end

      # Record a non-request disposition durably.
      # @return [:recorded, :duplicate]
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

      # Bind one outbox row to its effect journal entry (design §10).
      # @return [:bound, :conflict, :missing]
      def bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
        raise NotImplementedError
      end

      # Activate one approval prompt after its send receipt is durable.
      # @return [:activated, :already_active, :missing, :expired]
      def activate_prompt(reference_digest:, now:)
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
