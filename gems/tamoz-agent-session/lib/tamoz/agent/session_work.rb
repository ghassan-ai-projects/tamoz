# frozen_string_literal: true

module Tamoz
  module Agent
    # The durable work loop: one tool-calling model step, its gated tool calls, then a context check.
    class SessionWork
      CONTROLS = { 'reasoning_depth' => 'think', 'answer_verbosity' => 'verbose' }.freeze

      def initialize(services:)
        @services = services
        @work = WorkContext.new(configuration: services.configuration)
        tools = WorkTools.new(services:, work: @work)
        @gate = WorkGate.new(services:, work: @work, tools:)
        @compaction = WorkCompaction.new(services:, work: @work)
      end

      # Each turn is a fresh execution: it opens a new surface seeded from the previous turn's
      # answer (a handoff note when that turn ran out) and carries the accepted plan forward.
      def intake(_state, context, base)
        return base if base[:next_node] == 'terminal'

        previous = @services.configuration.previous_turn_reader&.call(thread_id: context.thread_id,
                                                                      execution_id: context.execution_id) || {}
        entries = @work.opening(task: base.fetch(:task), transcript: transcript(context, previous),
                                previous_answer: previous[:verification]&.fetch('answer'),
                                updates: directive_updates(previous))
        base.merge(phase: 'work', next_node: 'work_step', work_entries: entries, work_turn: context.request_id,
                   # §3.1: the disk may change between turns, so a turn's ledger starts empty.
                   work_observations: nil, work_started_ms: now_ms, work_plan: previous[:work_plan])
      end

      # rubocop:disable Metrics/AbcSize -- one model step and its four outcomes, in journal order
      def step(state, context)
        exhausted = state[:work_exhausted] || budget_reason(state)
        return handoff(state, exhausted) if exhausted

        messages = @work.messages(state.fetch(:work_entries))
        call = @services.effects.converse(context, stage: :work_step, messages:, tools: @work.header.tools,
                                                   iteration: state.fetch(:work_step_count),
                                                   attempt: state.fetch(:work_overflowed) ? 1 : 0)
        return answered(state, call, messages) if call.status == :succeeded
        return overflow(state) if window_exceeded?(call)
        raise LeaseLostError, "another owner still holds effect #{call.effect_key}" if call.status == :wait
        if call.status == :failed
          return failed_turn("the model call failed: #{@services.evidence.tool_error_message(call)}")
        end

        @services.evidence.blocked_update(call, 'work model call outcome is unknown',
                                          operation: 'model.converse.work_step')
      end
      # rubocop:enable Metrics/AbcSize

      def gate(state, context) = @gate.gate(state, context)

      def execute(state, context) = @gate.execute(state, context)

      def observe(state, context)
        update = @compaction.reduce(state, context, forced: state.fetch(:work_force_reduce))
        return handoff(state, update.fetch(:work_exhausted)).merge(update.except(:work_exhausted)) if
          update[:work_exhausted]

        { work_pending: nil, work_cursor: 0, work_boundary: false, work_force_reduce: false,
          next_node: 'work_step' }.merge(update)
      end

      private

      def now_ms = (Time.now.to_f * 1000).to_i

      def transcript(context, previous)
        return [] unless previous.empty?

        @services.planning_context.conversation_transcript(context)
      end

      # /think and /verbose recorded between turns become in-history operator updates.
      def directive_updates(previous)
        controls = Array(previous[:context_controls])
        CONTROLS.filter_map do |key, control|
          value = SessionContextControls.last_preference(controls, control, key)
          Harness::Persona.update(key, value) if value
        end
      end

      def budget_reason(state)
        seconds = (now_ms - state.fetch(:work_started_ms)) / 1000
        @work.settings.loop_policy.exhausted(model_calls: state.fetch(:work_step_count),
                                             tool_calls: state.fetch(:work_signatures).length, seconds:)
      end

      def window_exceeded?(call)
        call.status == :failed && call.error.is_a?(Hash) && call.error['code'] == 'context_window_exceeded'
      end

      # rubocop:disable Metrics/AbcSize -- the assistant entry, the measurement and the routing are one durable update
      def answered(state, call, messages)
        projection = call.value
        calls = projection.fetch('tool_calls')
        entry = @work.entry(state.fetch(:work_entries), 'assistant', projection.fetch('content'), tool_calls: calls)
        update = { work_entries: [entry], work_step_count: state.fetch(:work_step_count) + 1, work_overflowed: false }
                 .merge(measurement(state, messages, projection))
        return cut_off(state, entry, update) if calls.empty? && projection.fetch('finish_reason') == 'length'
        return finish(state, projection.fetch('content'), update) if calls.empty?

        pending = Harness::ToolCalls.parse(calls, allowed: @work.header.tool_names).map { |parsed| pending_call(parsed) }
        update.merge(work_pending: pending, work_cursor: 0, next_node: 'work_gate')
      end
      # rubocop:enable Metrics/AbcSize

      def pending_call(parsed)
        arguments = Tamoz::Core.jcs(parsed.arguments)
        { 'id' => parsed.id, 'name' => parsed.name, 'error' => parsed.error,
          'arguments_ref' => ContextEngine::Surface.retain(@work.store, arguments) }
      end

      def cut_off(state, entry, update)
        note = @work.entry(state.fetch(:work_entries) + [entry], 'system_update',
                           Harness::PromptPack.fetch('cut_off'))
        update.merge(work_entries: [entry, note], next_node: 'work_step')
      end

      # rubocop:disable Metrics/AbcSize -- series, usage, calibration and trace come from the same request
      def measurement(state, messages, projection)
        previous = state[:work_series]
        series = ContextEngine::Series.admit(header: @work.header, previous_digest: previous&.fetch('header_digest'),
                                             declared: previous&.fetch('declared', false) == true)
        usage = ContextEngine::Usage.from_provider(projection['usage'])
        calibration = usage && ContextEngine::TokenMeter.calibrate(messages:, tools: @work.header.tools,
                                                                   prompt_tokens: usage.prompt_tokens)
        estimate = @work.estimate(state.fetch(:work_entries), previous&.fetch('calibration', nil))
        trace = ContextEngine::Trace.new(series:, header_digest: @work.header.digest, message_count: messages.length,
                                         estimated_tokens: estimate, window: @work.window, usage:, replacements: [])
        { work_series: { 'header_digest' => @work.header.digest, 'declared' => false,
                         'calibration' => calibration&.to_h },
          work_trace: [trace.to_h.merge('event' => 'request', 'step' => state.fetch(:work_step_count))] }
      end
      # rubocop:enable Metrics/AbcSize

      def finish(state, content, update)
        status = finish_status(state)
        checked = state.fetch(:work_verified) || state.fetch(:work_checked)
        update.merge(
          verification: SessionRecords.build('verification', answer: content, evidence: evidence(state),
                                                             satisfied: %w[done verified_no_changes].include?(status),
                                                             configured_check_passed: checked, terminal_reason: status),
          terminal_reason: status, next_node: 'terminal'
        )
      end

      def finish_status(state)
        status = Harness::Finish.status(mutated: state.fetch(:work_mutated),
                                        verified_after_last_mutation: state.fetch(:work_verified))
        status == 'answered' && state.fetch(:work_checked) ? 'verified_no_changes' : status
      end

      def evidence(state)
        return ['a configured check passed after the last change'] if state.fetch(:work_verified)
        return ['files changed; no configured check passed after the last change'] if state.fetch(:work_mutated)

        state.fetch(:work_checked) ? ['a configured check passed; no files changed'] : []
      end

      def overflow(state)
        return failed_turn('the context window was exceeded again after a reduction') if state.fetch(:work_overflowed)

        { work_overflowed: true, work_force_reduce: true, work_pending: [], work_cursor: 0, next_node: 'work_observe' }
      end

      def handoff(state, reason)
        plan = state[:work_plan] && Harness::PlanDocument.new(state.fetch(:work_plan).fetch('document'))
        stopped(Harness::Handoff.note(plan:, reason:, task: state.fetch(:task)), reason, 'handed_off')
      end

      def failed_turn(reason) = stopped("The work turn stopped: #{reason}.", reason, 'work_failed')

      def stopped(answer, reason, status)
        {
          verification: SessionRecords.build('verification', answer:, satisfied: false, evidence: [reason],
                                                             configured_check_passed: false, terminal_reason: status),
          terminal_reason: status, next_node: 'terminal'
        }
      end
    end
  end
end
