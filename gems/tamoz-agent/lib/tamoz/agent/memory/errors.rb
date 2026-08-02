# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §6 (C8): typed failures over the merged D-7 taxonomy (invariant 17:
      # policy violations propagate as classes; repairable mistakes become typed
      # values). Admission default-rejection is a typed RESULT VALUE, never an
      # exception; secret-shaped content, consolidation failure, and deletion
      # partial-failure propagate as classes.
      class MemoryError < Error; end

      # Terminal policy violation: admission of secret-shaped or disallowed
      # content. Propagates; nothing is stored.
      class MemoryPolicyError < MemoryError; end

      # Terminal: a protected Store value (the sensitive record) cannot be
      # decrypted, or the protection codec refuses. Retrieval stays silent.
      class MemoryProtectionError < MemoryError; end

      # Propagates: consolidation model failure or invalid output. Prior
      # Knowledge stays intact and a rejected candidate is recorded.
      class MemoryConsolidationError < MemoryError; end

      # Propagates: deletion partial-failure. The receipt's `pending` fields name
      # the failed sink; there is no silent partial erasure.
      class MemoryDeletionError < MemoryError
        attr_reader :receipt

        def initialize(message, receipt: nil)
          @receipt = receipt
          super(message)
        end
      end

      # --- DR-1 BehaviorTransition failure model (§8) ---
      # Claim conflicts are typed values (the CAS loser never builds a session);
      # missing evidence and snapshot unavailability are terminal.
      class BehaviorTransitionClaimConflictError < MemoryError; end
      class BehaviorSnapshotUnavailableError < MemoryError; end
      class UnverifiedTransitionError < MemoryError; end
      class BehaviorVersionConflictError < MemoryError; end
    end
  end
end
