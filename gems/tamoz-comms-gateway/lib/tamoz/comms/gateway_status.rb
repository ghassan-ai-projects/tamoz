# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Renders a bounded human status by default and the full control-plane
      # projection only when the caller explicitly requests diagnostics.
      module StatusProjection
        HUMAN_TASK_STATES = {
          'idle' => 'idle', 'not_started' => 'accepted', 'admitted' => 'accepted',
          'queued' => 'queued', 'claimed' => 'working', 'running' => 'working',
          'redirecting' => 'waiting', 'completed' => 'completed', 'failed' => 'failed',
          'blocked' => 'blocked', 'stopped' => 'stopped'
        }.freeze
        HUMAN_NOW = {
          'accepted' => "Your message is queued; I'll start on it shortly.",
          'queued' => "Your message is queued; I'll start on it shortly.",
          'working' => "I'm working on your message.",
          'waiting' => "I'm working on your message."
        }.freeze
        TERMINAL_NOW = {
          'completed' => 'That one is finished.', 'failed' => 'That one ended with an error.',
          'stopped' => 'That one was stopped.', 'blocked' => 'That one is blocked.'
        }.freeze
        CANCELLATION_NOW = {
          'stopped' => 'Stopped, as you asked.',
          'completed_before_effect' => 'That finished before the cancel took effect.',
          'failed_before_effect' => 'That failed before the cancel took effect.',
          'blocked' => 'That was blocked when the cancel arrived.'
        }.freeze

        private

        def status_text(envelope, arguments)
          reference, diagnostic = status_arguments(arguments)
          return STATUS_USAGE_REPLY if reference == :invalid

          diagnostic ? diagnostic_status_text(envelope, reference) : human_status_text(envelope, reference)
        end

        def status_arguments(arguments)
          parts = String(arguments).strip.split(/\s+/)
          return [nil, false] if parts.empty?
          return [nil, true] if parts == ['--diagnostic']
          return [parts.first, false] if parts.length == 1
          return [parts.first, true] if parts.length == 2 && parts.last == '--diagnostic' &&
                                      valid_reference?(parts.first)

          [:invalid, false]
        end

        def human_status_text(envelope, reference)
          return human_request_status_text(envelope, reference) if reference

          status = @store.conversation_status(surface_id:, conversation_id: envelope.fetch('conversation_id'))
          return NO_WORK_REPLY unless status

          render_human_status(status)
        end

        def human_request_status_text(envelope, reference)
          resolved = @store.request_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: String(reference)
          )
          return UNKNOWN_REF_REPLY if resolved == :unknown_ref
          return AMBIGUOUS_REF_REPLY if resolved == :ambiguous_ref

          render_human_status(resolved, reference:)
        end

        # One plain sentence for a person; `--diagnostic` keeps every axis for operators.
        def render_human_status(projection, reference: nil)
          now = human_now(projection, reference)
          waiting = reference ? 0 : projection.fetch('open_requests', 1).to_i - 1
          return now unless waiting.positive?

          "#{now} #{waiting} more #{waiting == 1 ? 'message is' : 'messages are'} waiting."
        end

        # A cancel that raced a finished turn says so and never claims the work stopped.
        def human_now(projection, reference)
          cancellation = projection['cancellation']
          return CANCELLATION_NOW.fetch(cancellation['terminal'].to_s, 'Stopping, as you asked.') if cancellation
          return "I'm waiting for you to tap Approve or Deny." if projection['next_action'] == 'approval'

          state = human_task_state(projection)
          HUMAN_NOW.fetch(state) { reference ? TERMINAL_NOW.fetch(state, NO_WORK_REPLY) : NO_WORK_REPLY }
        end

        def human_task_state(projection)
          HUMAN_TASK_STATES.fetch(projection.fetch('task_state', 'not_started'), 'active')
        end

        def diagnostic_status_text(envelope, reference)
          return diagnostic_request_status_text(envelope, reference) if reference

          status = @store.conversation_status(surface_id:, conversation_id: envelope.fetch('conversation_id'))
          return NO_WORK_REPLY unless status

          "Work status: task=#{task_word(status)}; " \
            "#{worker_axis(status)}" \
            "#{state_axes(status)}" \
            "delivery=#{delivery_word(status)}; " \
            "next=#{status.fetch('next_action', 'inspect')}; " \
            "open requests=#{status.fetch('open_requests')}." \
            "#{reference_sentence(status)}#{queue_sentence(status)}" \
            "#{cancellation_sentence(status)}#{reason_sentence(status)}"
        end

        def diagnostic_request_status_text(envelope, reference)
          resolved = @store.request_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: String(reference)
          )
          return UNKNOWN_REF_REPLY if resolved == :unknown_ref
          return AMBIGUOUS_REF_REPLY if resolved == :ambiguous_ref

          "Request #{resolved.fetch('request_ref')}: task=#{task_word(resolved)}; " \
            "#{worker_axis(resolved)}" \
            "delivery=#{delivery_word(resolved)}; " \
            "#{state_axes(resolved)}" \
            "next=#{resolved.fetch('next_action', 'inspect')}." \
            "#{queue_sentence(resolved)}#{cancellation_sentence(resolved)}#{reason_sentence(resolved)}"
        end

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

        def worker_axis(projection)
          state = projection['worker_state']
          state ? "worker=#{state}; " : ''
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
