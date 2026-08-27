# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Routes parsed command intents to bounded control replies and durable operations.
      module Commands
        private

        # Command registry parity stays explicit so every known command has a
        # distinct control path.
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
        def handle_command(envelope, decision, now:)
          intent = decision.command_intent
          case intent.name
          when 'help'
            append_control(HELP_REPLY, envelope, now:)
          when 'status'
            append_control(status_text(envelope, intent.arguments), envelope, now:)
          when 'new'
            append_control(new_conversation(envelope), envelope, now:)
          when 'cancel'
            append_control(cancel_request(envelope, now:), envelope, now:)
          when 'redirect'
            append_control(redirect_request(envelope, intent.arguments), envelope, now:)
          when 'answer'
            append_control(answer_command(envelope, intent.arguments), envelope, now:)
          when 'whoami'
            append_control(whoami_text(envelope), envelope, now:)
          when 'start'
            append_control(start_text(intent.arguments), envelope, now:)
          when *CONTEXT_CONTROL_COMMANDS
            append_control(context_control_text(envelope, intent), envelope, now:)
          end
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity

        # `/redirect r<ref> <task>` changes task text only and uses the durable
        # checkpoint inbox path shared with cancellation.
        def redirect_request(envelope, arguments)
          reference, task_text = redirect_parts(arguments)
          return REDIRECT_USAGE_REPLY unless valid_reference?(reference) && !task_text.empty?

          resolved = redirect_target(envelope, reference)
          return redirect_refusal(resolved) if resolved.is_a?(Symbol)
          return FINISHED_REQUEST_REPLY if finished_request?(resolved)

          enqueue_redirect(envelope, resolved, task_text)
          "Redirecting #{resolved.fetch('request_ref')}; the replacement task is queued."
        rescue Tamoz::CheckpointConflictError
          REDIRECT_UNQUEUED_REPLY
        end

        def redirect_parts(arguments)
          parts = String(arguments).strip.split(/\s+/, 2)
          [parts[0].to_s, parts[1].to_s.strip]
        end

        def redirect_target(envelope, reference)
          @store.request_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: reference
          )
        end

        def redirect_refusal(outcome)
          return UNKNOWN_REF_REPLY if outcome == :unknown_ref
          return AMBIGUOUS_REF_REPLY if outcome == :ambiguous_ref

          outcome
        end

        def enqueue_redirect(envelope, resolved, task_text)
          @checkpoints.enqueue_request(
            thread_id: resolved.fetch('thread_id'),
            request_id: command_request_id(envelope, %w[redirect]),
            operation: :redirect,
            payload: { 'task' => task_text },
            delivery: :redirect
          )
        end

        def valid_reference?(text) = text.match?(REFERENCE_PATTERN)

        def finished_request?(resolved)
          request = @checkpoints.fetch_request(
            thread_id: resolved.fetch('thread_id'), request_id: resolved.fetch('request_id'), namespace: []
          )
          request && %i[completed failed].include?(request.status)
        end

        def command_request_id(envelope, tags)
          Comms::Canonical.hexdigest(
            'tamoz.comms.command.v1',
            [surface_id, envelope.fetch('update_id'), *tags]
          )
        end

        # `/cancel` stamps the durable requested point and queues the cancel
        # operation in one store transaction.
        def cancel_request(envelope, now:)
          conversation_id = envelope.fetch('conversation_id')
          return CANCEL_NO_WORK_REPLY unless @store.conversation(surface_id:, conversation_id:)

          thread_id = Comms::Admission.thread_id(
            surface_id, conversation_id,
            generation: @store.conversation_generation(surface_id:, conversation_id:)
          )
          status = @store.conversation_status(surface_id:, conversation_id:)
          return CANCEL_NO_WORK_REPLY unless status &&
                                             status.fetch('thread_id') == thread_id &&
                                             status.fetch('open_requests').positive?

          request_id = command_request_id(envelope, %w[cancel])
          @store.request_cancellation(
            thread_id:,
            request_id:,
            payload: { 'task' => { 'cancel' => true, 'reason' => 'cancelled_by_user' } },
            now:
          )
          'Cancellation requested.'
        rescue Tamoz::CheckpointConflictError
          'Cancellation could not be queued; no active checkpoint is available.'
        end
      end
    end
  end
end
