# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Agent
    # Runs one pending tool call: scope and approval at the gate, the journaled effect at execute,
    # and the shaped, scrubbed, spilled result appended to the surface.
    class WorkGate
      PLAN_BOUND_TOOLS = (WorkContext::MUTATING_TOOLS + %w[run_check]).freeze

      def initialize(services:, work:, tools:)
        @services = services
        @work = work
        @tools = tools
      end

      # rubocop:disable Metrics/AbcSize -- the repeat guard and routing of one call are one transition
      def gate(state, context)
        pending = state[:work_pending] || []
        cursor = state.fetch(:work_cursor)
        return round_complete(state) if cursor >= pending.length

        call = with_arguments(pending.fetch(cursor))
        signature = Harness::LoopPolicy.signature(call.fetch('name'), call.fetch('arguments'),
                                                  epoch: state.fetch(:work_mutation_count))
        verdict, count = @work.settings.loop_policy.repeat(state.fetch(:work_signatures), signature)
        return stop_repeating(call, count) if verdict == :stop

        reminders = verdict == :remind ? [@work.settings.loop_policy.reminder(call.fetch('name'), count)] : []
        route(state, context, call, cursor).merge(work_signatures: [signature],
                                                  work_reminders: state.fetch(:work_reminders) + reminders)
      end
      # rubocop:enable Metrics/AbcSize

      # rubocop:disable Metrics/AbcSize -- preview, dispatch and outcome of one effect stay in journal order
      def execute(state, context)
        prepared = state.fetch(:work_prepared)
        call = with_arguments(state.fetch(:work_pending).fetch(state.fetch(:work_cursor)))
        step = prepared.fetch('step').merge('arguments' => call.fetch('arguments'))
        preview = mutation_preview(step)
        outcome = @services.effects.dispatch(context, prepared.fetch('intent'), step,
                                             iteration: state.fetch(:work_step_count),
                                             sub_operation: state.fetch(:work_cursor))
        raise LeaseLostError, "another owner still holds effect #{outcome.effect_key}" if outcome.status == :wait
        return blocked(outcome, prepared) if outcome.status == :unknown

        executed(state, call, prepared, outcome, preview)
      end
      # rubocop:enable Metrics/AbcSize

      private

      def with_arguments(call)
        call.merge('arguments' => JSON.parse(@work.resolve.call(call.fetch('arguments_ref'))))
      end

      # Reminders wait until every call of the step is answered: a user message between the
      # results of one assistant message is refused by OpenAI-compatible APIs.
      def round_complete(state)
        reminders = state.fetch(:work_reminders)
        entries = reminders.reduce([]) do |added, text|
          added + [@work.entry(state.fetch(:work_entries) + added, 'system_update', text)]
        end
        { work_entries: entries, work_reminders: [], next_node: 'work_observe' }
      end

      def stop_repeating(call, count)
        { work_exhausted: "called #{call.fetch('name')} with the same arguments #{count} times",
          next_node: 'work_step' }
      end

      def route(state, context, call, cursor)
        return result(state, call, "Error: #{call.fetch('error')}") if call['error']

        case call.fetch('name')
        when 'update_plan'
          harness_result(state, call, @tools.update_plan(state, context, tool_call(call),
                                                         iteration: state.fetch(:work_step_count)))
        when 'recall_output' then harness_result(state, call, @tools.recall_output(tool_call(call)))
        else toolbox_gate(state, context, call, cursor)
        end
      end

      def tool_call(call)
        Harness::ToolCalls::Call.new(id: call.fetch('id'), name: call.fetch('name'),
                                     arguments: call.fetch('arguments'), error: nil)
      end

      def harness_result(state, call, outcome) = result(state, call, outcome.text).merge(outcome.update)

      def toolbox_gate(state, context, call, cursor)
        @services.configuration.capabilities.validate(call.fetch('name'), call.fetch('arguments'))
        refusal = scope_refusal(state, call.fetch('name'), call.fetch('arguments'))
        return result(state, call, refusal) if refusal

        prepare(state, context, call, cursor)
      rescue ToolError => e
        result(state, call, "Error: #{e.message}")
      end

      def scope_refusal(state, name, arguments)
        return nil unless PLAN_BOUND_TOOLS.include?(name)

        plan = state[:work_plan] && Harness::PlanDocument.new(state.fetch(:work_plan).fetch('document'))
        return 'Error: no accepted plan yet. Write one with update_plan first.' unless plan

        outside_scope(plan, name, arguments)
      end

      def outside_scope(plan, name, arguments)
        if name == 'run_check'
          check = arguments.fetch('name')
          return plan.checks.include?(check) ? nil : "Error: check #{check} is not in the accepted plan scope. " \
            'Revise the plan with update_plan.'
        end
        return nil if plan.in_scope?(arguments.fetch('path'))

        "Error: #{arguments.fetch('path')} is outside the accepted plan scope (#{plan.paths.join(', ')}). " \
          'Revise the plan with update_plan.'
      end

      def prepare(state, context, call, cursor)
        effects = @services.effects
        name = call.fetch('name')
        arguments = effects.resolved_effect_arguments(call.fetch('arguments'), name)
        step = { 'id' => step_id(state, cursor), 'tool' => name, 'arguments' => arguments }
        intent = effects.build_intent(step, accepted(state), arguments, iteration: state.fetch(:work_step_count),
                                                                        sub_operation: cursor)
        approve(state, context, call, { 'step' => step.except('arguments'), 'intent' => intent }, step)
      end

      def approve(state, context, call, prepared, step)
        verdict = journaled_verdict(state, step)
        return queued(prepared) if verdict == 'approve'
        return result(state, call, 'Error: the operator denied this call.') if verdict == 'deny'

        decision = @services.effects.decide_step_tool(
          tool: step.fetch('tool'), arguments: step.fetch('arguments'),
          session_id: @services.configuration.approval_session_id,
          step_scope: "#{accepted(state).fetch('plan_id')}.#{step.fetch('id')}"
        )
        case decision.verdict
        when :allow then queued(prepared)
        when :deny then result(state, call, "Error: denied by policy (#{decision.reason}, rule #{decision.rule_id}).")
        else ask(state, context, call, prepared, step, decision)
        end
      end

      # rubocop:disable Metrics/ParameterLists -- the approval needs the prepared effect and the decision it answers
      def ask(state, context, call, prepared, step, decision)
        preview = @services.effects.preview_for(step.fetch('tool'), step.fetch('arguments'))
        preview_digest = Digest::SHA256.hexdigest(preview)
        answer = Tamoz.interrupt(descriptor(state, prepared, step, decision, preview), context)
        granted = [true, 'approve', 'approved'].include?(answer)
        record = approval_record(state, prepared, step, preview_digest, granted)
        restart = { approvals: [record], work_started_ms: (Time.now.to_f * 1000).to_i }
        return result(state, call, 'Error: the operator denied this call.').merge(restart) unless granted

        queued(prepared).merge(restart)
      end
      # rubocop:enable Metrics/ParameterLists

      def queued(prepared)
        intent = prepared.fetch('intent')
        update = { work_prepared: prepared, next_node: 'work_execute' }
        intent.fetch('safety') == 'read_only' ? update : update.merge(effect_intents: [intent])
      end

      # rubocop:disable Metrics/AbcSize -- the approval descriptor's fields mirror step_gate's
      def descriptor(state, prepared, step, decision, preview)
        plan = accepted(state)
        {
          'kind' => 'approve_tool',
          'decision' => { 'id' => decision.id, 'verdict' => decision.verdict.to_s, 'reason' => decision.reason,
                          'rule_id' => decision.rule_id, 'required_evidence' => decision.required_evidence&.to_s,
                          'grant_scopes' => decision.grant_offer&.scopes&.map(&:to_s) },
          'session_id' => state.fetch(:session).fetch('session_id'), 'plan_id' => plan.fetch('plan_id'),
          'plan_digest' => plan.fetch('plan_digest'), 'step_id' => step.fetch('id'), 'tool' => step.fetch('tool'),
          'arguments' => step.fetch('arguments'), 'preview' => preview,
          'arguments_digest' => prepared.fetch('intent').fetch('arguments_digest'),
          'preview_digest' => Digest::SHA256.hexdigest(preview)
        }
      end
      # rubocop:enable Metrics/AbcSize

      def approval_record(state, prepared, step, preview_digest, granted)
        plan = accepted(state)
        SessionRecords.build(
          'approval', approval_id: "#{plan.fetch('plan_id')}.#{step.fetch('id')}", plan_id: plan.fetch('plan_id'),
                      plan_digest: plan.fetch('plan_digest'), step_id: step.fetch('id'), tool: step.fetch('tool'),
                      arguments_digest: prepared.fetch('intent').fetch('arguments_digest'), preview_digest:,
                      decision: granted ? 'approve' : 'deny'
        )
      end

      def journaled_verdict(state, step)
        id = "#{accepted(state).fetch('plan_id')}.#{step.fetch('id')}"
        state.fetch(:approvals, []).find { |record| record['approval_id'] == id }&.fetch('decision')
      end

      def accepted(state)
        plan = state[:work_plan]
        { 'plan_id' => 'work.plan', 'plan_digest' => plan ? plan.fetch('digest') : 'none' }
      end

      def step_id(state, cursor) = "work.#{state.fetch(:work_turn)}.#{state.fetch(:work_step_count)}.#{cursor}"

      def mutation_preview(step)
        return nil unless step.fetch('tool') == 'apply_patch'

        @services.effects.preview_for('apply_patch', step.fetch('arguments'))
      rescue ToolError
        nil
      end

      def executed(state, call, prepared, outcome, preview)
        name = call.fetch('name')
        text = if outcome.status == :succeeded
                 success_text(name, outcome.value, preview)
               else
                 "Error: #{@services.evidence.tool_error_message(outcome)}"
               end
        result(state, call, text, summary: summary(name, outcome))
          .merge(flags(state, name, outcome), effect_receipts: [receipt(prepared, outcome)], work_prepared: nil)
      end

      def success_text(name, value, preview)
        return String(value['shaped'] || value.fetch('output')) if value.key?('check')
        return "#{value.fetch('output')}\n\nDiff:\n#{preview}" if name == 'apply_patch' && preview

        String(value.fetch('output'))
      end

      def summary(name, outcome)
        check = outcome.value.is_a?(Hash) && outcome.value['check']
        check ? "#{check.fetch('name')} #{check.fetch('outcome')}" : "#{name} #{outcome.status}"
      end

      # Only a passing check after the last change verifies it; any other check result un-verifies.
      def flags(state, name, outcome)
        if WorkContext::MUTATING_TOOLS.include?(name)
          return {} unless outcome.status == :succeeded

          return { work_mutated: true, work_verified: false,
                   work_mutation_count: state.fetch(:work_mutation_count) + 1 }
        end
        return {} unless name == 'run_check'

        passed = outcome.status == :succeeded && outcome.value.dig('check', 'passed') == true
        return { work_verified: false, work_checked: false } unless passed

        { work_verified: state.fetch(:work_mutated), work_checked: true, work_boundary: true }
      end

      def receipt(prepared, outcome)
        intent = prepared.fetch('intent')
        SessionRecords.build(
          'effect_receipt', effect_key: outcome.effect_key, logical_key: outcome.effect_key,
                            attempt_identity: outcome.attempt_identity ||
                              "#{outcome.effect_key}/attempt/#{outcome.attempt_number}",
                            step_id: intent.fetch('step_id'), operation: intent.fetch('operation'),
                            safety: intent.fetch('safety'), status: outcome.status.to_s,
                            attempt_number: outcome.attempt_number, reconciliation: outcome.reconciliation,
                            iteration: intent.fetch('iteration'), sub_operation: intent.fetch('sub_operation')
        )
      end

      def blocked(outcome, prepared)
        intent = prepared.fetch('intent')
        @services.evidence.blocked_update(outcome, 'work tool outcome is unknown',
                                          step_id: intent.fetch('step_id'), operation: intent.fetch('operation'))
      end

      def result(state, call, text, summary: nil)
        limit = @work.settings.context_policy.max_inline_bytes
        spilled = ContextEngine::Spill.new(store: @work.store, max_inline_bytes: limit)
                                      .apply(@work.scrub(text), summary: summary || call.fetch('name'))
        entry = @work.entry(state.fetch(:work_entries), 'tool_result', spilled.text,
                            tool_call_id: call.fetch('id'), name: call.fetch('name'), spilled: spilled.spilled)
        { work_entries: [entry], work_cursor: state.fetch(:work_cursor) + 1, next_node: 'work_gate' }
      end
    end
  end
end
