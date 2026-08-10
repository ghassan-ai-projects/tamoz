# frozen_string_literal: true

module Tamoz
  module Comms
    # Structural contract for the durable decision store (design §9, plan
    # slice A). `tamoz-sqlite` implements it without a runtime reference to
    # this constant (dependency rule 9); the integration layer that loads both
    # checks the CONTRACT_VERSION pair before use.
    #
    # The store speaks the WIRE form of DecisionRecord (`DecisionRecord#wire`):
    # string-keyed hashes in, string-keyed hashes out, plus the status symbols
    # below. Claiming is compare-and-set: exactly one concurrent claimer wins
    # per record, and a claimed record whose lease has expired is claimable
    # again (crash recovery without a cross-layer transaction).
    #
    # The signatures below ARE the contract: every parameter is part of the
    # durable operation it documents, and the bodies raise because a contract
    # module has nothing to implement.
    # :reek:UnusedParameters, :reek:LongParameterList
    module DecisionStore
      CONTRACT_VERSION = 1

      # Inserts a pending decision. Idempotent on decision_id.
      # @param wire [Hash] the DecisionRecord wire form with status "pending".
      # @return [:created, :duplicate]
      def insert_decision(wire)
        raise NotImplementedError
      end

      # The single newest unexpired pending decision for one occurrence whose
      # interrupt digest matches, or nil. Newest-wins so a later operator
      # decision on the SAME question supersedes an earlier one.
      # @return [Hash, nil]
      def pending_decision_for(thread_id:, occurrence_id:, interrupt_digest:, now:)
        raise NotImplementedError
      end

      # Claims one record pending -> claimed under a fenced lease. A claimed
      # record whose lease has expired is claimable again.
      # @param claim_expires_at [Time] the lease deadline.
      # @param fence [Integer] monotonically increasing per claim.
      # @return [:claimed, :not_claimable, :missing]
      def claim_decision(decision_id:, owner:, fence:, claim_expires_at:, now:)
        raise NotImplementedError
      end

      # Consumes one claimed record -> consumed. Idempotent on an already
      # consumed record.
      # @return [:consumed, :not_consumable, :missing]
      def consume_decision(decision_id:, now:)
        raise NotImplementedError
      end

      # @return [Array<Hash>] every decision row for the thread, newest first.
      def each_decision(thread_id:, limit: 500)
        raise NotImplementedError
      end
    end
  end
end
