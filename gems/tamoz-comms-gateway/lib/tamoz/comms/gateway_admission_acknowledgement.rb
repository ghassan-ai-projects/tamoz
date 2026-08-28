# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Builds the synchronous acknowledgement for an admitted request.
      module AdmissionAcknowledgement
        private

        def accepted_reply(envelope)
          reference = Lifecycle::RequestRef.for(request_identity(envelope))
          "Received #{reference}."
        end

        def request_identity(envelope)
          Tamoz::Core::RequestIdentity.request_id(
            surface_id: envelope.fetch('surface_id'),
            surface_revision: envelope.fetch('surface_revision'),
            bot_id:, update_id: envelope.fetch('update_id'),
            raw_payload_hash: envelope.fetch('raw_payload_hash')
          )
        end
      end
    end
  end
end
