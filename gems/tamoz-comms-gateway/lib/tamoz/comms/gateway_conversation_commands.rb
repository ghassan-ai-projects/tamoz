# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Handles commands that address the conversation rather than a request.
      module ConversationCommands
        private

        def new_conversation(envelope)
          @store.bump_generation(surface_id:, conversation_id: envelope.fetch('conversation_id'))
          NEW_CONVERSATION_REPLY
        rescue KeyError
          NEW_CONVERSATION_UNBOUND_REPLY
        end

        def whoami_text(envelope)
          "You are #{envelope.fetch('correspondent_id')} in conversation " \
            "#{envelope.fetch('conversation_id')} on surface #{surface_id}."
        end
      end
    end
  end
end
