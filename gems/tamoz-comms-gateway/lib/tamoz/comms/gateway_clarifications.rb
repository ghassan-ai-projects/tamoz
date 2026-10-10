# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Finds what a clarification answer answers: the paused session's clarify interrupts, and the
      # question message a reply quotes.
      module Clarifications
        private

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
