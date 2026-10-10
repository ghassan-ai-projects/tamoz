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

          return wrong_correspondent(envelope, now:) unless answer_correspondent?(envelope)

          interrupts = clarification_interrupts(resolved.fetch('thread_id'), resolved.fetch('request_id'))
          return answer_refusal_for(envelope, ANSWER_STALE_REPLY, now:, reason: 'answer_stale') unless interrupts

          enqueue_answer(envelope, resolved, clarification_answers(interrupts, text), now:)
        end

        def enqueue_answer(envelope, resolved, payload, now:)
          resume = Comms::Resume.new(thread: resolved.fetch('thread_id'), payload:,
                                     request_id: Comms::ClarificationAnswerRequest.id_for(resolved.fetch('request_id')))
          case @store.admit_and_enqueue_answer(envelope, stream_id:, resume:, now:)
          when :duplicate then nil
          when :integrity_conflict then ANSWER_UNQUEUED_REPLY
          else ANSWER_QUEUED_REPLY
          end
        rescue Tamoz::CheckpointConflictError
          answer_refusal_for(envelope, ANSWER_UNQUEUED_REPLY, now:, reason: 'answer_enqueue_conflict')
        end

        def wrong_correspondent(envelope, now:)
          answer_refusal_for(envelope, ANSWER_WRONG_CORRESPONDENT_REPLY, now:, reason: 'wrong_correspondent')
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
      end
    end
  end
end
