# frozen_string_literal: true

module Tamoz
  module Comms
    class Gateway
      # Renders a bounded human status by default and the full control-plane
      # projection only when the caller explicitly requests diagnostics.
      module StatusProjection
        HUMAN_TASK_STATES = {
          'not_started' => 'accepted', 'admitted' => 'accepted', 'queued' => 'queued',
          'claimed' => 'working', 'running' => 'working', 'redirecting' => 'waiting',
          'completed' => 'completed', 'failed' => 'failed', 'blocked' => 'blocked',
          'stopped' => 'stopped'
        }.freeze
        WORKER_NOW = {
          'accepted' => 'Waiting for a worker to begin.',
          'queued-unclaimed' => 'Waiting for a worker to pick up this request.',
          'working' => 'A worker is handling this request.'
        }.freeze
        TASK_NOW = {
          'accepted' => 'The request is accepted.',
          'queued' => 'The request is queued.',
          'working' => 'The request is in progress.',
          'waiting' => 'The request is waiting for its next step.',
          'completed' => 'The request is complete.',
          'failed' => 'The request ended with an error.',
          'blocked' => 'The request is blocked.',
          'stopped' => 'The request is stopped.'
        }.freeze
        NEXT_ACTIONS = {
          'inspect' => 'Check the request.',
          'continue' => 'Continue working on the request.',
          'approval' => 'Wait for your approval.',
          'none' => 'No further action.'
        }.freeze
        DELIVERY_WORDS = {
          'none' => 'not sent yet', 'pending' => 'pending', 'claimed' => 'pending',
          'succeeded' => 'delivered', 'delivered' => 'delivered', 'failed' => 'failed',
          'unknown' => 'unknown'
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

          render_human_status(status, 'Work status', status['request_ref'])
        end

        def human_request_status_text(envelope, reference)
          resolved = @store.request_status(
            surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: String(reference)
          )
          return UNKNOWN_REF_REPLY if resolved == :unknown_ref
          return AMBIGUOUS_REF_REPLY if resolved == :ambiguous_ref

          render_human_status(resolved, "Request #{resolved.fetch('request_ref')}", nil)
        end

        def render_human_status(projection, title, active_reference)
          "#{title}: State: #{human_task_state(projection)}.#{active_request_sentence(active_reference)} " \
            "Now: #{human_now(projection)} Next: #{human_next(projection)} " \
            "Delivery: #{human_delivery(projection)}.#{human_queue_sentence(projection)}" \
            "#{open_requests_sentence(projection)}#{cancellation_sentence(projection)}"
        end

        def human_task_state(projection)
          HUMAN_TASK_STATES.fetch(projection.fetch('task_state', 'not_started'), 'active')
        end

        def active_request_sentence(reference)
          reference ? " Active request: #{reference}." : ''
        end

        def human_now(projection)
          worker_state = projection['worker_state']
          return WORKER_NOW.fetch(worker_state) if WORKER_NOW.key?(worker_state)

          TASK_NOW.fetch(human_task_state(projection), 'The request is active.')
        end

        def human_next(projection)
          NEXT_ACTIONS.fetch(projection.fetch('next_action', 'inspect'), 'Continue checking the request.')
        end

        def human_delivery(projection)
          state = projection.fetch('active_delivery_state', projection.fetch('delivery_state', 'unknown'))
          DELIVERY_WORDS.fetch(state, 'unknown')
        end

        def human_queue_sentence(projection)
          return '' unless projection.key?('queue_position')

          sentence = " Queue position #{projection.fetch('queue_position')}."
          age = projection['queue_age_ms']
          age ? "#{sentence} Age #{[age.to_i, 0].max} ms." : sentence
        end

        def open_requests_sentence(projection)
          return '' unless projection.key?('open_request_refs')

          refs = projection.fetch('open_request_refs')
          " Open requests: #{projection.fetch('open_requests')}; refs: #{refs.join(', ')}."
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
