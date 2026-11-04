# frozen_string_literal: true

require_relative 'gateway_diagnostic_status'

module Tamoz
  module Comms
    class Gateway
      # Renders a bounded human status by default and the full control-plane
      # projection only when the caller explicitly requests diagnostics.
      module StatusProjection
        include DiagnosticStatus

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
      end
    end
  end
end
