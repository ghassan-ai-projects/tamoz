# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Builds the synchronous acknowledgement for an admitted request.
      module AdmissionAcknowledgement
        private

        def accepted_reply(envelope)
          reference = Lifecycle::RequestRef.for(request_identity(envelope))
          status = @store.conversation_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id')
          )
          if status && status.fetch('open_requests') > 1
            "Accepted #{reference}; queued behind earlier work; " \
              'I will report committed progress when it runs.'
          else
            "Accepted #{reference}. I will report committed progress."
          end
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
