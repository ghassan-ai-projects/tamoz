# frozen_string_literal: true

module Tamoz
  module Stream
    # P14-A (design §15, plan §4) — the structural StreamStore contract.
    # `tamoz-stream` depends only on this; `tamoz-sqlite` implements the first
    # conforming adapter.
    #
    # Admission (design §5/§6): a repeated scoped id with the same canonical
    # hash is an IDEMPOTENT duplicate; the same id with a different hash is a
    # quarantine conflict (invariant 45). Invalid data receives a durable
    # rejection or quarantine record — never a silent drop. The connector
    # acknowledges only after the event and admission metadata are durably
    # appended.
    module StreamStore
      CONTRACT_VERSION = 1

      # Admission outcomes (design §5): durable, never raised.
      ADMITTED = "admitted"
      DUPLICATE = "duplicate"
      QUARANTINED = "quarantined"
      REJECTED = "rejected"

      # Admit one envelope: idempotent dedup, quarantine on hash conflict,
      # bounded validation rejection. Returns an outcome hash with the durable
      # admission metadata.
      #
      # @param envelope [EventEnvelope] the validated typed envelope.
      # @param clock [StreamClock] the injected clock (processing time owned by
      #   the runtime, never the payload).
      # @return [Hash] {"outcome" => ADMITTED|DUPLICATE|QUARANTINED|REJECTED,
      #   "identity" => ..., "reason" => ...}
      def admit(envelope, clock:)
        raise NotImplementedError
      end

      # The rejection/quarantine reason for an identity, if any (durable).
      def admission_record(identity)
        raise NotImplementedError
      end

      # Whether the connector may ack an event id: true only after durable
      # admission metadata exists.
      def durable?(identity)
        raise NotImplementedError
      end
    end
  end
end
