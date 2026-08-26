# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Renders durable conversation and request projections for /status.
      module StatusProjection
        private

        # `/status` renders the conversation aggregate or one request scoped to
        # the caller's conversation; malformed or foreign refs leak nothing.
        def status_text(envelope, arguments)
          return request_status_text(envelope, arguments) if arguments

          status = @store.conversation_status(surface_id:, conversation_id: envelope.fetch('conversation_id'))
          return NO_WORK_REPLY unless status

          "Work status: task=#{task_word(status)}; " \
            "#{state_axes(status)}" \
            "delivery=#{delivery_word(status)}; " \
            "next=#{status.fetch('next_action', 'inspect')}; " \
            "open requests=#{status.fetch('open_requests')}." \
            "#{reference_sentence(status)}#{queue_sentence(status)}" \
            "#{cancellation_sentence(status)}#{reason_sentence(status)}"
        end

        def request_status_text(envelope, reference)
          resolved = @store.request_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: String(reference)
          )
          return UNKNOWN_REF_REPLY if resolved == :unknown_ref
          return AMBIGUOUS_REF_REPLY if resolved == :ambiguous_ref

          "Request #{resolved.fetch('request_ref')}: task=#{task_word(resolved)}; " \
            "delivery=#{delivery_word(resolved)}; " \
            "#{state_axes(resolved)}" \
            "next=#{resolved.fetch('next_action', 'inspect')}." \
            "#{queue_sentence(resolved)}#{cancellation_sentence(resolved)}#{reason_sentence(resolved)}"
        end

        # Both lifecycle axes render external vocabulary only.
        def task_word(projection)
          internal = TASK_WORD_PRETRANSLATIONS.fetch(
            projection.fetch('task_state'), projection.fetch('task_state')
          )
          Lifecycle.task_state_for(internal) || 'idle'
        end

        def delivery_word(projection)
          internal = projection.fetch('delivery_state')
          return 'none' if internal == 'none'

          Lifecycle.delivery_state_for(internal)
        end

        def state_axes(projection)
          "phase=#{projection.fetch('phase', 'unknown')}; " \
            "event=#{projection.fetch('event_kind', 'unknown')}##{projection.fetch('event_sequence', 'unknown')}; " \
            "effect=#{projection.fetch('effect_state')}; " \
            "capability=#{projection.fetch('capability_state')}; "
        end

        def reference_sentence(projection)
          reference = projection['request_ref']
          reference ? " Reference #{reference}." : ''
        end

        def queue_sentence(projection)
          return '' unless projection.key?('queue_position')

          sentence = " Queue position #{projection.fetch('queue_position')}."
          projection['queue_age_ms'] ? "#{sentence} Age #{projection.fetch('queue_age_ms')} ms." : sentence
        end

        def reason_sentence(projection)
          reason = projection['terminal_reason']
          reason ? " Reason: #{reason}." : ''
        end

        # The cancellation timeline renders the requested, observed, and
        # terminal points distinctly without claiming an external call stopped.
        def cancellation_sentence(projection)
          facts = projection['cancellation']
          return '' unless facts

          sentence = " Cancellation requested#{age_phrase(facts['requested_age_ms'])}."
          sentence << " Observed by the runner#{age_phrase(facts['observed_age_ms'])}." if facts['observed_at_ms']
          case facts['terminal']
          when 'stopped'
            "#{sentence} Terminal: stopped at the cancellation boundary."
          when 'completed_before_effect'
            "#{sentence} Terminal: completed before the cancellation took effect."
          when 'failed_before_effect'
            "#{sentence} Terminal: failed before the cancellation took effect."
          when 'blocked'
            "#{sentence} Terminal: work was blocked when the cancellation arrived."
          else
            sentence
          end
        end

        def age_phrase(age_ms)
          return '' if age_ms.nil?

          seconds = [age_ms.to_i / 1000, 0].max
          age = if seconds < 60
                  "#{seconds}s"
                elsif seconds < 3600
                  "#{seconds / 60}m"
                else
                  "#{seconds / 3600}h"
                end
          " #{age} ago"
        end
      end
    end
  end
end
