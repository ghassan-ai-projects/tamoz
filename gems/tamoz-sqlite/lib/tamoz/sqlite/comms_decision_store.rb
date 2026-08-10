# frozen_string_literal: true

require 'time'

require_relative 'store'

module Tamoz
  module SQLite
    # Durable decision store for channel and CLI approvals (design §9, plan
    # slice A). Implements the structural Tamoz::Comms::DecisionStore contract
    # WITHOUT referencing the contract gem (dependency rule 9): wire-form
    # hashes in, wire-form hashes out. The integration layer that loads both
    # verifies the CONTRACT_VERSION pair.
    #
    # Rows live in the versioned Store namespace so every transition is a
    # compare-and-set: exactly one concurrent claimer wins, and an expired
    # claim lease releases the record back to claimable (crash recovery).
    #
    # The wire is plain data by contract, so every operation reads it with the
    # same fetches — the predicate/selection smells below are the wire-reading
    # shape, not a choice to overload methods.
    # :reek:FeatureEnvy, :reek:ControlParameter, :reek:LongParameterList
    # :reek:UtilityFunction -- `claimable?` is a pure status predicate shared
    #   by the read and claim paths; inlining it would duplicate the lease rule.
    class CommsDecisionStore
      CONTRACT_VERSION = 1
      NAMESPACE = %w[tamoz comms decision].freeze
      DEFAULT_LIMIT = 500

      def initialize(store)
        @store = store
      end

      def insert_decision(wire)
        @store.put(NAMESPACE, wire.fetch('decision_id'), wire, if_version: nil)
        :created
      rescue StoreConflictError
        :duplicate
      end

      # Newest-wins: a later operator decision on the SAME question supersedes
      # an earlier one (the old one stays as durable evidence but is never
      # consumed). Different questions (digests) never cross-match.
      #
      # A claimed record whose lease has expired is treated as pending: its
      # claimer died before submitting, so the record is recoverable (design
      # §9 crash-before-submission path).
      def pending_decision_for(thread_id:, occurrence_id:, interrupt_digest:, now:)
        candidates = each_decision(thread_id:, limit: DEFAULT_LIMIT).select do |wire|
          claimable?(wire, now) &&
            wire.fetch('occurrence_id') == occurrence_id &&
            wire.fetch('interrupt_digest') == interrupt_digest &&
            Time.parse(wire.fetch('expires_at')) > now
        end
        candidates.max_by { |wire| wire.fetch('decided_at') }
      end

      # The claim is read-check-CAS in one method because the CAS must target
      # the exact version read; splitting the steps would open a TOCTOU gap.
      # :reek:TooManyStatements
      def claim_decision(decision_id:, owner:, fence:, claim_expires_at:, now:)
        entry = @store.get(NAMESPACE, decision_id)
        return :missing unless entry&.value

        wire = entry.value
        return :not_claimable unless claimable?(wire, now)

        updates = {
          'status' => 'claimed',
          'claim_owner' => owner,
          'claim_fence' => fence,
          'claim_expires_at' => claim_expires_at.utc.iso8601(6)
        }
        cas_update(decision_id, entry, updates)
        :claimed
      rescue StoreConflictError
        :not_claimable
      end

      # Same read-check-CAS shape as claim_decision: one atomic transition.
      # :reek:TooManyStatements
      def consume_decision(decision_id:, now:)
        entry = @store.get(NAMESPACE, decision_id)
        return :missing unless entry&.value

        status = entry.value.fetch('status')
        return :consumed if status == 'consumed'
        return :not_consumable unless status == 'claimed'

        cas_update(decision_id, entry, 'status' => 'consumed', 'consumed_at' => now.utc.iso8601(6))
        :consumed
      rescue StoreConflictError
        :not_consumable
      end

      def each_decision(thread_id:, limit: DEFAULT_LIMIT)
        rows = @store.each(NAMESPACE, limit:).filter_map do |entry|
          wire = entry.value
          wire if wire.fetch('thread_id') == thread_id
        end
        rows.sort_by { |wire| wire.fetch('decided_at') }.reverse
      end

      private

      # The compare-and-set write every transition shares: replace the version
      # we just read, or lose to the claimer who got there first.
      def cas_update(decision_id, entry, updates)
        @store.put(NAMESPACE, decision_id, entry.value.merge(updates), if_version: entry.version)
      end

      # A record is claimable when pending, or when a previous claim's lease
      # has expired — the crash-before-submission recovery path. The same test
      # at read time is what lets the worker SEE an expired claim so it can
      # reclaim and resume.
      def claimable?(wire, now)
        case wire.fetch('status')
        when 'pending'
          true
        when 'claimed'
          Time.parse(wire.fetch('claim_expires_at')) <= now
        else
          false
        end
      end
    end
  end
end
