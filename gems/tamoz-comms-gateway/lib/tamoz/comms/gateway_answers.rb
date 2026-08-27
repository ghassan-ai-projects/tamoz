# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Projects a clarification reply onto the currently paused session and
      # queues the existing durable resume operation.
      module Answers
        private

        def answer_command(envelope, arguments)
          reference, text = answer_parts(arguments)
          return ANSWER_USAGE_REPLY unless valid_answer_reference?(reference) && !text.empty?

          enqueue_answer(envelope, reference, text)
        end

        def admit_answer(envelope, reference, text, now:)
          outcome = record_disposition(
            envelope, disposition: 'ignored', reason: 'clarification_answer', now:
          )
          return if outcome == :duplicate

          append_control(enqueue_answer(envelope, reference, text), envelope, now:)
        end

        def enqueue_answer(envelope, reference, text)
          resolved = answer_target(envelope, reference)
          return answer_refusal(resolved) if resolved.is_a?(Symbol)

          return ANSWER_WRONG_CORRESPONDENT_REPLY unless answer_correspondent?(envelope)

          session = @controls&.call(resolved.fetch('thread_id'))
          return ANSWER_STALE_REPLY unless session

          view = session.view(thread: resolved.fetch('thread_id'))
          return ANSWER_STALE_REPLY unless clarification_view?(view)

          @checkpoints.enqueue_request(
            thread_id: resolved.fetch('thread_id'),
            request_id: command_request_id(envelope, %w[answer]),
            operation: :resume,
            payload: clarification_answers(view.interrupts, text),
            delivery: :queue
          )
          ANSWER_QUEUED_REPLY
        rescue Tamoz::CheckpointConflictError
          ANSWER_UNQUEUED_REPLY
        end

        def answer_parts(arguments)
          String(arguments).strip.split(/\s+/, 2).then do |parts|
            [parts[0].to_s.downcase, parts[1].to_s.strip]
          end
        end

        def valid_answer_reference?(reference)
          reference.match?(REFERENCE_PATTERN) || reference.match?(FULL_REFERENCE_PATTERN)
        end

        def answer_target(envelope, reference)
          lookup = short_answer_reference(reference)
          resolved = @store.request_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: lookup
          )
          return resolved unless resolved.is_a?(Hash)
          return resolved unless full_answer_reference?(reference)
          return resolved if resolved.fetch('request_id').casecmp?(reference.delete_prefix('r'))

          :unknown_ref
        end

        def short_answer_reference(reference)
          return reference unless full_answer_reference?(reference)

          value = reference.delete_prefix('r')
          "r#{value[0, Lifecycle::REQUEST_REF_WIDTH]}"
        end

        def full_answer_reference?(reference)
          reference.match?(FULL_REFERENCE_PATTERN)
        end

        def answer_refusal(outcome)
          return UNKNOWN_REF_REPLY if outcome == :unknown_ref
          return AMBIGUOUS_REF_REPLY if outcome == :ambiguous_ref

          ANSWER_STALE_REPLY
        end

        def answer_correspondent?(envelope)
          binding = @store.binding_by_conversation(
            surface_id:, conversation_id: envelope.fetch('conversation_id')
          )
          binding && binding.fetch('correspondent_id') == envelope.fetch('correspondent_id')
        end

        def clarification_view?(view)
          view && view.status == :paused && !view.interrupts.empty? &&
            view.interrupts.all? { |interrupt| interrupt.descriptor['kind'] == 'clarify' }
        end

        def clarification_answers(interrupts, text)
          interrupts.each_with_object({}) do |interrupt, answers|
            (answers[interrupt.task_id] ||= {})[interrupt.call_index] = text
          end
        end

        def clarification_reply_reference(envelope)
          return unless envelope.fetch('kind') == 'text' && envelope['reply_to']

          clarification_question_rows(envelope).reverse_each do |row|
            markup = parsed_hash(row['markup'])
            next unless markup['phase'] == 'clarification_required' &&
                        markup['actions'] == ['answer'] && markup['request_ref']

            receipt = parsed_hash(row['receipt'])
            return markup['request_ref'] if receipt_message_matches_reply?(receipt, envelope['reply_to'])
          end
          nil
        end

        def receipt_message_matches_reply?(receipt, reply_to)
          message_id = receipt['message_id']
          message_id.is_a?(Integer) && message_id.positive? &&
            reply_to.is_a?(Integer) && message_id == reply_to
        end

        def clarification_question_rows(envelope)
          @store.outbox_rows(surface_id:, statuses: %w[succeeded]).select do |row|
            row['conversation_id'] == envelope.fetch('conversation_id') && row['kind'] == 'control'
          end
        end

        def parsed_hash(value)
          parsed = JSON.parse(value.to_s)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
