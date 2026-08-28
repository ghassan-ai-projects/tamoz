# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Projects a clarification reply onto the currently paused session and
      # queues the existing durable resume operation.
      module Answers
        private

        def answer_command(envelope, arguments, now:)
          reference, text = answer_parts(arguments)
          unless valid_answer_reference?(reference) && !text.empty?
            return answer_refusal_for(envelope, ANSWER_USAGE_REPLY, now:, reason: 'answer_usage')
          end

          answer_reply(envelope, reference, text, now:)
        end

        def admit_answer(envelope, reference, text, now:)
          reply = answer_reply(envelope, reference, text, now:)
          append_control(reply, envelope, now:) if reply
        end

        def answer_reply(envelope, reference, text, now:)
          resolved = answer_target(envelope, reference)
          return answer_refusal_for(envelope, answer_refusal(resolved), now:, reason: 'answer_refusal') if
            resolved.is_a?(Symbol)

          return answer_refusal_for(envelope, ANSWER_WRONG_CORRESPONDENT_REPLY, now:,
                                    reason: 'wrong_correspondent') unless answer_correspondent?(envelope)

          interrupts = clarification_interrupts(
            resolved.fetch('thread_id'), resolved.fetch('request_id')
          )
          return answer_refusal_for(envelope, ANSWER_STALE_REPLY, now:, reason: 'answer_stale') unless interrupts

          outcome = @store.admit_and_enqueue_answer(
            envelope, surface_id:, bot_id:, thread: resolved.fetch('thread_id'),
            request_id: Comms::ClarificationAnswerRequest.id_for(resolved.fetch('request_id')),
            payload: clarification_answers(interrupts, text), now:
          )
          return nil if outcome == :duplicate
          return ANSWER_UNQUEUED_REPLY if outcome == :integrity_conflict

          ANSWER_QUEUED_REPLY
        rescue Tamoz::CheckpointConflictError
          answer_refusal_for(envelope, ANSWER_UNQUEUED_REPLY, now:, reason: 'answer_enqueue_conflict')
        end

        def answer_refusal_for(envelope, reply, now:, reason:)
          outcome = record_disposition(envelope, disposition: 'ignored', reason:, now:)
          outcome == :duplicate ? nil : reply
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

        def clarification_interrupts(thread_id, request_id)
          checkpoint = @checkpoints.latest(thread_id:, namespace: [])
          return unless checkpoint&.status == :paused
          return unless checkpoint_request_id(thread_id, checkpoint) == request_id

          interrupts = checkpoint.interrupts
          return unless interrupts.any? && interrupts.all? do |interrupt|
            interrupt.descriptor['kind'] == 'clarify'
          end

          interrupts
        end

        def checkpoint_request_id(thread_id, checkpoint)
          @checkpoints.request_history(thread_id:, namespace: []).reverse_each do |request|
            return request.request_id if request.execution_id == checkpoint.execution_id
          end
          nil
        end

        def clarification_answers(interrupts, text)
          interrupts.each_with_object({}) do |interrupt, answers|
            (answers[interrupt.task_id] ||= {})[interrupt.call_index] = text
          end
        end

        def clarification_reply_reference(envelope)
          return unless envelope.fetch('kind') == 'text' && envelope['reply_to']

          row = @store.outbox_row_for_receipt(
            surface_id:, conversation_id: envelope.fetch('conversation_id'),
            message_id: envelope['reply_to']
          )
          return unless clarification_receipt?(row, envelope['reply_to'])

          markup = parsed_hash(row['markup'])
          return unless markup['phase'] == 'clarification_required' &&
                        markup['actions'] == ['answer'] && markup['request_ref']

          markup['request_ref']
        end

        def clarification_receipt?(row, message_id)
          return false unless row && row['kind'] == 'control'

          receipt = parsed_hash(row['receipt'])
          receipt['message_id'].is_a?(Integer) && receipt['message_id'].positive? &&
            receipt['message_id'] == message_id
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
