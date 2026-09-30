# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Agent
    # The lead of a deep-research turn: the plan the user accepts, waves of research subagents, the report on disk.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:ManualDispatch :reek:NestedIterators :reek:NilCheck :reek:TooManyMethods :reek:TooManyStatements
    # :reek:UncommunicativeVariableName :reek:UtilityFunction
    class WorkResearch
      LEAD_TOOLS = %w[propose_research_plan research_wave write_report].freeze
      FINISH = 'write_report'
      # One refusal for both cases the lead can reach it from: a plan the user already accepted, or a research whose
      # waves have started.
      ALREADY_PLANNED = 'Error: there is already a plan for this research; the plan can no longer change.'

      # Children run at once up to what the model route may carry, keeping one request for the lead.
      def self.batch_for(model)
        return 1 unless model.respond_to?(:provider) && model.respond_to?(:model)

        [ModelWindows.max_concurrent_requests(provider: model.provider, model: model.model) - 1, 1].max
      end

      def initialize(services:, work:, delegation:)
        @services = services
        @work = work
        @delegation = delegation
      end

      def propose(state, context, call)
        research = state.fetch(:research)
        return outcome(ALREADY_PLANNED) if research['accepted'] || !research.fetch('children').empty?

        brief = Tamoz::Research.brief(call.arguments, budgets:)
        reply = Tamoz.interrupt(checkpoint(state, brief), context).to_s.strip
        restarted(answered(research, brief, reply))
      rescue Tamoz::Research::Error => e
        outcome("Plan not shown: #{e.message}")
      end

      def wave(state, context, call)
        research = state.fetch(:research)
        return outcome('Error: the user has not accepted a plan; call propose_research_plan first.') unless
          research['accepted']

        ran(research, context, Tamoz::Research.wave(call.arguments, ledger: ledger(research), budgets:))
      rescue Tamoz::Research::Error => e
        outcome("Wave not started: #{e.message}")
      end

      def write_report(state, context, call)
        research = state.fetch(:research)
        return outcome('Error: there is no accepted plan to report on.') unless research['accepted']

        ledger = ledger(research)
        stop = Tamoz::Research.stop_reason(ledger, budgets:)
        return outcome(keep_going(ledger)) unless stop

        written(state, context, call, ledger, stop)
      rescue Tamoz::Research::Error => e
        outcome("Report not accepted: #{e.message}")
      end

      private

      # The time the user spent reading the plan is not the lead's working time.
      def restarted(result) = result.with(update: result.update.merge(work_started_ms: (Time.now.to_f * 1000).to_i))

      def budgets
        override = @work.settings.research_budgets
        Tamoz::Research.budgets(override:)
      end

      def ledger(research)
        brief = Tamoz::Research.restore_brief(research.fetch('brief'))
        Tamoz::Research.ledger(brief:, children: research.fetch('children'))
      end

      def outcome(text, update = {}) = WorkTools::Outcome.new(text:, update:)

      # The plan is asked as a clarifying question, the pause both surfaces already answer in free text.
      def checkpoint(state, brief)
        { 'kind' => 'clarify', 'session_id' => state.fetch(:session).fetch('session_id'),
          'plan_id' => 'research.plan', 'plan_digest' => Tamoz::Core.digest("tamoz.research.plan.v1\n", brief.to_h),
          'question' => Tamoz::Research.plan_text(brief, budgets:), 'context' => { 'phase' => 'research_plan' } }
      end

      def answered(research, brief, reply)
        case decision(reply)
        when :go
          outcome('The user accepted the plan. Send the first research_wave.',
                  research: research.merge('brief' => brief.to_h, 'accepted' => true))
        when :stop then stopped
        else
          outcome("The user asked for changes: #{reply}\nRevise the plan and call propose_research_plan again.",
                  research: research.merge('accepted' => false, 'plan_edits' => research.fetch('plan_edits') + 1))
        end
      end

      def decision(reply)
        said = reply.downcase.gsub(/\A[[:punct:][:space:]]+|[[:punct:][:space:]]+\z/, '')
        replies = Harness::ResearchPack.replies
        return :go if replies.fetch('go').include?(said)

        :stop if replies.fetch('stop').include?(said)
      end

      def stopped
        answer = 'Research stopped before it started; nothing was searched.'
        verification = SessionRecords.build('verification', answer:, satisfied: false, configured_check_passed: false,
                                                            evidence: ['the user stopped the research plan'],
                                                            terminal_reason: 'cancelled_by_user')
        outcome(answer, verification:, terminal_reason: 'cancelled_by_user', next_node: 'terminal')
      end

      def ran(research, context, wave)
        inputs = wave.assignments.map { |assignment| child_input(wave, assignment) }
        child = @services.configuration.subagent_apps.fetch('research')
        outputs = @delegation.run_inputs(child, inputs, context, batch: batch_size)
        after = research.merge('children' => research.fetch('children') + records(research, outputs, wave))
        outcome(wave_text(after.fetch('children').last(outputs.length), ledger(after)),
                research: after, work_trace: @delegation.trace(child, outputs, inputs))
      end

      def records(research, outputs, wave)
        number = ledger(research).used.fetch('waves') + 1
        outputs.zip(wave.assignments).map { |output, assignment| record(output, assignment, number) }
      end

      def child_input(wave, assignment)
        { task: wave.child_task(assignment),
          research: { 'mode' => 'child', 'sub_questions' => assignment.sub_question_ids,
                      'searches' => assignment.searches, 'page_reads' => assignment.page_reads } }
      end

      def record(output, assignment, wave)
        spent = output.fetch(:research) || {}
        { 'wave' => wave, 'sub_questions' => assignment.sub_question_ids,
          'sources' => (output.dig(:verification, 'report') if output.fetch(:terminal_reason) == 'reported'),
          'searches' => spent.fetch('search_count', 0), 'page_reads' => spent.fetch('read_count', 0) }
      end

      def batch_size = self.class.batch_for(@services.configuration.model)

      def wave_text(records, ledger)
        found = records.each_with_index.map do |record, index|
          sources = record['sources']
          body = sources ? Tamoz::Research.restore_sources(sources).render : 'It reported no sources.'
          "Child #{index + 1} (#{record['sub_questions'].join(', ')}): #{body}"
        end
        (found + ['', 'Coverage:', ledger.render, '', next_step(ledger)]).join("\n")
      end

      def next_step(ledger)
        stop = Tamoz::Research.stop_reason(ledger, budgets:)
        return keep_going(ledger) unless stop

        words = budgets.depth(ledger.brief.depth).words
        "You may now write the report (#{stop}). Aim for #{words.first} to #{words.last} words."
      end

      def keep_going(ledger)
        "Still open: #{ledger.open_ids.join(', ')}. Run another research_wave for them with a different angle or " \
          'different sources; the report can be written once they are covered or the budget is spent.'
      end

      def written(state, context, call, ledger, stop)
        unsupported = unsupported_claims(state, context, ledger, call.arguments)
        report = Tamoz::Research.report(call.arguments, ledger:, stop_reason: stop, unsupported:)
        record = Tamoz::Research.run_record(ledger:, report:, stop_reason: stop,
                                            extra: record_extra(state, report, unsupported))
        directory = run_directory(state, ledger)
        status = saved(context, directory, Tamoz::Research.run_folder_files(ledger:, report:, record:))
        return outcome("Error: the report could not be saved (#{status}).") unless status == :succeeded

        finished(report.reply(File.join(directory, 'report.md')), record)
      end

      def support_rate(report, unsupported)
        cited = report.cited.length
        cited.zero? ? nil : (cited - unsupported.length).fdiv(cited).round(3)
      end

      def record_extra(state, report, unsupported)
        { 'run_id' => state.fetch(:work_execution_id), 'plan_edits' => state.fetch(:research).fetch('plan_edits'),
          'date' => run_date(state), 'tokens' => TurnUsage.summarize(state.fetch(:work_trace)),
          'support_rate' => support_rate(report, unsupported) }
      end

      def run_date(state) = Time.at(state.fetch(:work_started_ms) / 1000).utc.strftime('%Y-%m-%d')

      def saved(context, directory, files)
        written = @services.effects.write_research(context, directory:, files:)
        raise LeaseLostError, "another owner still holds effect #{written.effect_key}" if written.status == :wait

        written.status
      end

      def run_directory(state, ledger)
        name = Tamoz::Research.run_folder_name(date: run_date(state), question: ledger.brief.question,
                                               run_id: state.fetch(:work_execution_id))
        File.join(research_dir, name)
      end

      # The worker names one (the runtime directory's); otherwise the report lands in the workspace.
      def research_dir
        @work.settings.research_dir || File.join(@services.configuration.toolbox.root.to_s, 'research')
      end

      def finished(answer, record)
        verification = SessionRecords.build(
          'verification', answer:, satisfied: true, configured_check_passed: false, terminal_reason: 'reported',
                          evidence: ['a research report whose every citation is a claim quoting a page a research ' \
                                     'subagent read'], report: record
        )
        outcome('Report written.', verification:, terminal_reason: 'reported', next_node: 'terminal')
      end

      # One journaled model call judges each cited sentence against the excerpts it cites.
      def unsupported_claims(state, context, ledger, arguments)
        items = Tamoz::Research.citations("#{arguments['summary']}\n#{arguments['body']}").map do |sentence, ids|
          { 'sentence' => sentence,
            'claims' => ids.filter_map do |id|
              ledger.claim(id)&.then do |claim|
                { 'id' => id, 'excerpt' => claim.excerpt }
              end
            end }
        end
        return [] if items.empty?

        call = @services.effects.model_call(context, stage: :research_verify,
                                                     system: Harness::PromptPack.fetch('research_verify'),
                                                     prompt: JSON.generate('items' => items), call_index: 0,
                                                     iteration: state.fetch(:work_step_count))
        verdict(call, items)
      end

      def verdict(call, items)
        cited = items.flat_map { |item| item.fetch('claims').map { |claim| claim.fetch('id') } }
        raise LeaseLostError, "another owner still holds effect #{call.effect_key}" if call.status == :wait
        return cited unless call.status == :succeeded

        listed = JSON.parse(call.value[/\{.*\}/m].to_s).fetch('unsupported', [])
        listed.is_a?(Array) ? listed.grep(String) & cited : cited
      rescue JSON::ParserError
        cited
      end
    end
  end
end
