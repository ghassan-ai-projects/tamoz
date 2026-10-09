# frozen_string_literal: true

module Tamoz
  module Agent
    # The durable work loop: one tool-calling model step, its gated tool calls, then a context check.
    class SessionWork
      CONTROLS = { 'reasoning_depth' => 'think', 'answer_verbosity' => 'verbose' }.freeze
      # The user's /cancel, seen at the next step: no further model call or tool runs.
      CANCELLED = { next_node: 'terminal', terminal_reason: 'cancelled_by_user' }.freeze

      # One view of the work loop: an ordinary turn and a deep-research lead each have their own header and tools.
      Lane = Data.define(:work, :gate, :compaction, :nudge)

      def initialize(services:)
        @services = services
        @memory = WorkMemory.new(configuration: services.configuration,
                                 transcript: ->(context) { services.planning_context.conversation_transcript(context) })
        @lanes = { nil => build_lane(nil), lead: build_lane(:lead) }.freeze
        @attachment = WorkAttachment.new(configuration: services.configuration, effects: services.effects)
      end

      # Each turn is a fresh execution: it opens a new surface seeded from the conversation transcript (or the
      # previous turn's answer, a handoff note when that turn ran out), and carries the accepted plan forward.
      def intake(state, context, base)
        return base if base[:next_node] == 'terminal'

        research = WorkResearchState.opened(state[:research])
        return WorkResearchState.unavailable(base) if research&.fetch('mode') == 'lead' && !research_available?

        opened(base.merge(research:), context, state[:attachment])
      end

      # :reek:DuplicateMethodCall
      def opened(base, context, attachment)
        previous = @services.configuration.previous_turn_reader&.call(thread_id: context.thread_id,
                                                                      execution_id: context.execution_id) || {}
        reading = @attachment.read(attachment, window: work(base).window, context:) if attachment
        brief = @memory.brief(told(base, reading))
        entries = opening(base, context, previous, brief, reading)
        base.merge(task: told(base, reading), phase: 'work', next_node: 'work_step', work_entries: entries, work_turn: context.request_id,
                   work_execution_id: context.execution_id,
                   # §3.1: the disk may change between turns, so a turn's ledger starts empty.
                   work_observations: nil, work_started_ms: now_ms, work_plan: previous[:work_plan],
                   work_checkpoint: previous[:work_checkpoint],
                   work_trace: [brief.event, reading&.event, reading&.request].compact + work(base).opening_trace)
      end

      def step(state, context)
        return CANCELLED if stopped?(context)

        exhausted = state[:work_exhausted] || budget_reason(state)
        return handoff(state, exhausted) if exhausted

        note = lane(state).nudge.entry(state)
        return { work_entries: [note], next_node: 'work_step' } if note

        stepped(state, context)
      end

      def gate(state, context) = stopped?(context) ? CANCELLED : lane(state).gate.gate(state, context)

      def execute(state, context) = lane(state).gate.execute(state, context)

      def observe(state, context)
        update = lane(state).compaction.reduce(state, context, forced: state.fetch(:work_force_reduce))
        return handoff(state, update.fetch(:work_exhausted)).merge(update.except(:work_exhausted)) if
          update[:work_exhausted]

        { work_pending: nil, work_cursor: 0, work_boundary: false, work_force_reduce: false,
          next_node: 'work_step' }.merge(update)
      end

      private

      def build_lane(research)
        work = WorkContext.new(configuration: @services.configuration, research:)
        tools = WorkTools.new(services: @services, work:, memory: @memory)
        Lane.new(work:, gate: WorkGate.new(services: @services, work:, tools:),
                 compaction: WorkCompaction.new(services: @services, work:), nudge: WorkNudge.new(work:))
      end

      def lane(state) = @lanes.fetch(state[:research]&.fetch('mode') == 'lead' ? :lead : nil)

      def work(state) = lane(state).work

      def research_available? = @services.configuration.subagent_apps.key?('research')

      def opening(base, context, previous, brief, reading)
        transcript = @services.planning_context.conversation_transcript(context)
        work(base).opening(task: told(base, reading), asked: base.fetch(:task), transcript:,
                           previous_answer: previous_answer(previous, transcript), updates: directive_updates(previous),
                           carried: { memory: brief.text, checkpoint: previous[:work_checkpoint],
                                      material: reading&.material })
      end

      def told(base, reading) = reading&.task ? "#{base.fetch(:task)}\n#{reading.task}" : base.fetch(:task)

      def stopped?(context) = Tamoz::Cancellation::Stops.requested?(context.thread_id)

      # :reek:TooManyStatements
      def stepped(state, context)
        work = work(state)
        messages = work.messages(state.fetch(:work_entries))
        call = @services.effects.converse(context, stage: :work_step, messages:, tools: work.header.tools,
                                                   iteration: state.fetch(:work_step_count),
                                                   attempt: state.fetch(:work_overflowed) ? 1 : 0)
        return CANCELLED.merge(work_trace: [attempt_trace(state, call)]) if stopped?(context)

        called(state, call, messages)
      end

      # :reek:DuplicateMethodCall :reek:TooManyStatements
      def called(state, call, messages)
        return answered(state, call, messages) if call.status == :succeeded
        raise LeaseLostError, "another owner still holds effect #{call.effect_key}" if call.status == :wait

        update = if window_exceeded?(call)
                   overflow(state)
                 elsif call.status == :failed
                   failed_step(call)
                 else
                   @services.evidence.blocked_update(call, 'work model call outcome is unknown',
                                                     operation: 'model.converse.work_step')
                 end
        update.merge(work_trace: [attempt_trace(state, call)])
      end

      def attempt_trace(state, call)
        usage = ContextEngine::Usage.from_provider(call.value['usage'])&.to_h if call.status == :succeeded
        status = call.status.to_s
        { 'event' => 'request', 'step' => state.fetch(:work_step_count), 'status' => status, 'usage' => usage }
      end

      def now_ms = (Time.now.to_f * 1000).to_i

      # A chat transcript already holds the reply as delivered; a CLI transcript holds only the operator's lines.
      def previous_answer(previous, transcript)
        previous[:verification]&.fetch('answer') if transcript.none? { |fragment| fragment['role'] == 'assistant' }
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
        work(state).settings.loop_policy.exhausted(model_calls: state.fetch(:work_step_count),
                                                   tool_calls: state.fetch(:work_signatures).length, seconds:)
      end

      def window_exceeded?(call)
        call.status == :failed && call.error.is_a?(Hash) && call.error['code'] == 'context_window_exceeded'
      end

      # :reek:DuplicateMethodCall :reek:NilCheck :reek:TooManyStatements
      # rubocop:disable Metrics/AbcSize -- the assistant entry, the measurement and the routing are one durable update
      def answered(state, call, messages)
        projection = call.value
        calls = projection.fetch('tool_calls')
        work = work(state)
        entry = work.entry(state.fetch(:work_entries), 'assistant', projection.fetch('content'), tool_calls: calls)
        update = { work_entries: [entry], work_step_count: state.fetch(:work_step_count) + 1, work_overflowed: false }
                 .merge(measurement(state, messages, projection))
        return cut_off(state, entry, update) if calls.empty? && projection.fetch('finish_reason') == 'length'

        if calls.empty?
          refusal = lane(state).gate.finish_refusal(state)
          return remind_report(state, entry, update) if refusal.nil? && report_due?(state)

          return finish(state, projection.fetch('content'), update) if refusal.nil?

          return refused_stop(state, entry, update, refusal)
        end

        pending = Harness::ToolCalls.parse(calls, allowed: work.header.tool_names).map { |parsed| pending_call(parsed) }
        update.merge(work_pending: pending, work_cursor: 0, next_node: 'work_gate')
      end
      # rubocop:enable Metrics/AbcSize

      # :reek:LongParameterList
      def refused_stop(state, entry, update, refusal)
        note = work(state).entry(state.fetch(:work_entries) + [entry], 'system_update', refusal)
        update.merge(work_entries: [entry, note], next_node: 'work_step')
      end

      def pending_call(parsed)
        arguments = Tamoz::Core.jcs(parsed.arguments)
        { 'id' => parsed.id, 'name' => parsed.name, 'error' => parsed.error,
          'arguments_ref' => ContextEngine::Surface.retain(@lanes.fetch(nil).work.store, arguments) }
      end

      # A turn that gathered probe evidence owes a findings report, and a research turn owes its finishing tool; each is
      # reminded once, then may answer freely.
      def report_due?(state)
        entries = state.fetch(:work_entries)
        return false if entries.any? { |entry| entry['source'] == 'report_reminder' }

        WorkResearchState.finish_tool(state[:research]) ||
          (work(state).reports? && !work(state).gathered(entries).empty?)
      end

      def remind_report(state, entry, update)
        finish = WorkResearchState.finish_tool(state[:research])
        text = if finish
                 format(Harness::PromptPack.fetch('research_reminder'), tool: finish)
               else
                 Harness::PromptPack.fetch('report_reminder')
               end
        note = work(state).entry(state.fetch(:work_entries) + [entry], 'system_update', text, source: 'report_reminder')
        update.merge(work_entries: [entry, note], next_node: 'work_step')
      end

      def cut_off(state, entry, update)
        note = work(state).entry(state.fetch(:work_entries) + [entry], 'system_update',
                                 Harness::PromptPack.fetch('cut_off'))
        update.merge(work_entries: [entry, note], next_node: 'work_step')
      end

      # rubocop:disable Metrics/AbcSize -- series, usage, calibration and trace come from the same request
      def measurement(state, messages, projection)
        previous = state[:work_series]
        work = work(state)
        header = work.header
        series = ContextEngine::Series.admit(header:, previous_digest: previous&.fetch('header_digest'),
                                             declared: previous&.fetch('declared', false) == true)
        usage = ContextEngine::Usage.from_provider(projection['usage'])
        calibration = usage && ContextEngine::TokenMeter.calibrate(messages:, tools: header.tools,
                                                                   prompt_tokens: usage.prompt_tokens)
        estimate = work.estimate(state.fetch(:work_entries), previous&.fetch('calibration', nil))
        trace = ContextEngine::Trace.new(series:, header_digest: header.digest, message_count: messages.length,
                                         estimated_tokens: estimate, window: work.window, usage:, replacements: [])
        { work_series: { 'header_digest' => header.digest, 'declared' => false,
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

      def failed_step(call)
        @services.evidence.refusal_update(call) ||
          failed_turn("the model call failed: #{@services.evidence.tool_error_message(call)}")
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
