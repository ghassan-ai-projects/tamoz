# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Resolves typed context controls through the caller-provided session seam.
      module ContextControls
        private

        def context_control_text(envelope, intent)
          return CONTROLS_UNAVAILABLE_REPLY unless @controls

          conversation_id = envelope.fetch('conversation_id')
          return NEW_CONVERSATION_UNBOUND_REPLY unless @store.conversation(surface_id:, conversation_id:)

          thread = Comms::Admission.thread_id(
            surface_id, conversation_id,
            generation: @store.conversation_generation(surface_id:, conversation_id:)
          )
          controls = @controls.call(thread)
          return CONTROLS_UNAVAILABLE_REPLY unless controls

          projection = run_context_control(controls, thread, envelope, intent)
          Comms::ControlReply.line(intent.name, projection)
        rescue ArgumentError
          CONTROL_ARGUMENT_REFUSALS.fetch(intent.name, CONTROLS_UNAVAILABLE_REPLY)
        rescue Tamoz::CheckpointConflictError => e
          context_conflict_reply(e)
        end

        def run_context_control(controls, thread, envelope, intent)
          request_id = command_request_id(envelope, ['context_control', intent.name])
          case intent.name
          when 'reset' then controls.reset_episode(thread:, request_id:).document
          when 'compact' then controls.compact_transcript(thread:, request_id:).document
          when 'usage' then controls.usage_report(thread:).document
          when 'context' then controls.context_report(thread:).document
          when 'think' then controls.set_reasoning_depth(thread:, request_id:, depth: intent.arguments).document
          else controls.set_answer_verbosity(thread:, request_id:, verbosity: intent.arguments).document
          end
        end

        def context_conflict_reply(error)
          if error.message.to_s.end_with?(STATELESS_THREAD_MESSAGE)
            CONTROLS_NO_SESSION_REPLY
          else
            CONTROLS_CONFLICT_REPLY
          end
        end
      end
    end
  end
end
