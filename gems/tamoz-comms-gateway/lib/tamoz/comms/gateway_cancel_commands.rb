# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # `/cancel`: stops every open request in the conversation, or the one named by reference.
      module CancelCommands
        private

        # A bare `/cancel` stops everything open in this conversation; `/cancel r<ref>` stops one request.
        def cancel_request(envelope, arguments, now:)
          reference = cancel_reference(arguments)
          return CANCEL_USAGE_REPLY if reference == :invalid

          conversation_id = envelope.fetch('conversation_id')
          return CANCEL_NO_WORK_REPLY unless @store.conversation(surface_id:, conversation_id:)

          thread_id = Comms::Admission.thread_id(
            surface_id, conversation_id,
            generation: @store.conversation_generation(surface_id:, conversation_id:)
          )
          targets = @store.open_request_targets(surface_id:, conversation_id:, thread_id:)
          chosen = reference ? referenced_cancel_target(envelope, reference, targets) : targets
          return chosen if chosen.is_a?(String)

          stamp_cancellations(envelope, thread_id, chosen, now:)
        rescue Tamoz::CheckpointConflictError
          'Cancellation could not be queued; no active checkpoint is available.'
        end

        def stamp_cancellations(envelope, thread_id, targets, now:)
          return CANCEL_NO_WORK_REPLY if targets.empty?

          targets.reject { |target| target['stopping'] }.each_with_index do |target, index|
            tags = index.zero? ? %w[cancel] : ['cancel', target.fetch('request_id')]
            @store.request_cancellation(
              thread_id:, request_id: command_request_id(envelope, tags),
              target_request_id: target.fetch('request_id'),
              payload: { 'task' => { 'cancel' => true, 'reason' => 'cancelled_by_user' } }, now:
            )
          end
          CANCEL_REPLY
        end

        def cancel_reference(arguments)
          return nil if arguments.nil?

          parts = arguments.split(/\s+/)
          parts.length == 1 ? parts.first : :invalid
        end

        def referenced_cancel_target(envelope, reference, targets)
          return CANCEL_USAGE_REPLY unless valid_reference?(reference)

          resolved = @store.request_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: reference
          )
          return cancel_refusal(resolved) if resolved.is_a?(Symbol)

          target = targets.find { |candidate| candidate.fetch('request_id') == resolved.fetch('request_id') }
          target ? [target] : CANCEL_STALE_REF_REPLY
        end

        def cancel_refusal(outcome)
          return UNKNOWN_REF_REPLY if outcome == :unknown_ref
          return AMBIGUOUS_REF_REPLY if outcome == :ambiguous_ref

          CANCEL_STALE_REF_REPLY
        end
      end
    end
  end
end
