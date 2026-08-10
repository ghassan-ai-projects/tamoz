# frozen_string_literal: true

module Tamoz
  module Comms
    # Structural contract for the channel store (design §13). `tamoz-sqlite`
    # implements it as an optional module loaded only when explicitly required
    # (dependency rule 9, exactly as StreamStore is implemented today); the
    # integration layer that loads both verifies the CONTRACT_VERSION pair, and
    # `tamoz-evals` audits it.
    #
    # Every primitive is transaction-bound and names its idempotency/conflict
    # result. The signatures below ARE the contract — the bodies raise because
    # a contract module has nothing to implement.
    # :reek:UnusedParameters, :reek:LongParameterList
    module CommsStore
      CONTRACT_VERSION = 1

      # Admit one inbound update AND enqueue its request in one transaction.
      # @return [:enqueued, :duplicate, :quarantined]
      def admit_and_enqueue(envelope, surface:, binding:, thread:)
        raise NotImplementedError
      end

      # Record a non-request disposition (ignored/rejected/unsupported) durably.
      # @return [:recorded, :duplicate]
      def disposition_only(envelope, surface:, reason:, control_reply: nil)
        raise NotImplementedError
      end

      # Persist the candidate next_offset ONLY after the returned prefix has a
      # durable disposition.
      # @return [:persisted, :behind]
      def persist_next_offset(surface_id:, bot_id:, next_offset:, expected: nil)
        raise NotImplementedError
      end

      # Append one desired delivery to the outbox.
      # @return [:appended, :duplicate, :capacity_refused]
      def append_delivery(delivery, surface_id:)
        raise NotImplementedError
      end

      # Claim one outbox row under a fenced lease for a transport attempt.
      # @return [:claimed, :not_claimable, :missing]
      def claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
        raise NotImplementedError
      end

      # Bind an outbox row to its effect journal entry.
      # @return [:bound, :conflict]
      def bind_journal_effect(delivery_id:, effect_key:, execution_id:)
        raise NotImplementedError
      end

      # Activate one approval prompt after its send receipt is durable.
      # @return [:activated, :already_active, :missing, :expired]
      def activate_prompt(reference_digest:, now:)
        raise NotImplementedError
      end

      # Consume one active approval prompt atomically with its decision record.
      # @return [:consumed, :not_consumable, :missing, :expired]
      def consume_prompt(reference_digest:, decision:, now:)
        raise NotImplementedError
      end

      # Revoke one binding; atomically invalidates unused approval prompts.
      # @return [:revoked, :missing]
      def revoke_binding(correspondent_id:, surface_id:, reason:, now:)
        raise NotImplementedError
      end
    end
  end
end
