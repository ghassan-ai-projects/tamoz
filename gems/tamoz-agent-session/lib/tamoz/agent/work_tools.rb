# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # The harness tools that never touch the workspace: update_plan (reviewed once per scope), recall_output,
    # and report_findings.
    # rubocop:disable Metrics/AbcSize -- one plan transition per call.
    class WorkTools
      MAX_PLAN_REVIEWS = 3

      # The model-visible result of a harness tool and the state it changes.
      Outcome = Data.define(:text, :update)

      def initialize(services:, work:)
        @services = services
        @work = work
      end

      def update_plan(state, context, call, iteration:)
        plan = Harness::PlanDocument.parse(call.arguments)
        unknown = plan.checks - @services.configuration.toolbox.checks.keys
        unless unknown.empty?
          raise Harness::PlanError,
                "unknown checks #{unknown.join(', ')}; configured: #{configured_checks}"
        end

        previous = state[:work_plan] && Harness::PlanDocument.new(state.fetch(:work_plan).fetch('document'))
        return keep_plan(plan, state) if previous && !plan.widens?(previous)

        review(state, context, plan, iteration)
      rescue Harness::PlanError => e
        Outcome.new(text: "Plan not accepted: #{e.message}", update: {})
      end

      def recall_output(call)
        arguments = call.arguments
        text = ContextEngine::Spill.recall(@work.store, arguments['locator'], offset: arguments.fetch('offset', 1),
                                                                              limit: arguments.fetch('limit', 200),
                                                                              pattern: arguments['pattern'])
        Outcome.new(text:, update: {})
      rescue ContextEngine::Error, TypeError => e
        Outcome.new(text: "Error: #{e.message}", update: {})
      end

      # A grounded report ends the turn: its rendering is the answer; the proposals are not executed. It must be the
      # step's last call, or the calls after it would never answer.
      def report_findings(state, call)
        unless state.fetch(:work_cursor) == state.fetch(:work_pending).length - 1
          return Outcome.new(text: 'Error: call report_findings alone, as the last call of its step.', update: {})
        end

        report = Harness::FindingsReport.parse(call.arguments, gathered: @work.gathered(state.fetch(:work_entries)))
        verification = SessionRecords.build(
          'verification', answer: report.render, satisfied: true, configured_check_passed: false,
                          evidence: ['a findings report whose every finding cites a probe call that answered'],
                          terminal_reason: 'reported', report: report.document
        )
        Outcome.new(text: 'Report accepted.',
                    update: { verification:, terminal_reason: 'reported', next_node: 'terminal' })
      rescue Harness::ReportError => e
        Outcome.new(text: "Report not accepted: #{e.message}", update: {})
      end

      private

      def configured_checks
        names = @services.configuration.toolbox.checks.keys.sort
        names.empty? ? '(none)' : names.join(', ')
      end

      def keep_plan(plan, state)
        accepted = state.fetch(:work_plan)
        Outcome.new(text: 'Plan updated.',
                    update: { work_plan: accepted.merge('document' => plan.document, 'digest' => plan.digest) })
      end

      def review(state, context, plan, iteration)
        reviews = state.fetch(:work_plan_reviews)
        return Outcome.new(text: limit_text, update: {}) if reviews >= MAX_PLAN_REVIEWS

        call = review_call(state, context, plan, iteration, reviews)
        return Outcome.new(text: 'Plan review did not complete; try update_plan again.', update: {}) unless
          call.status == :succeeded

        decide(plan, Deliberation.parse_review(call.value), reviews)
      rescue ProtocolError => e
        Outcome.new(text: "Plan review was invalid (#{e.message}); try update_plan again.",
                    update: { work_plan_reviews: reviews + 1 })
      end

      def review_call(state, context, plan, iteration, reviews)
        @services.effects.model_call(
          context, stage: :work_plan_review, system: Harness::PromptPack.fetch('plan_review'),
                   prompt: JSON.pretty_generate('task' => state.fetch(:task), 'plan' => plan.document,
                                                'available_tools' => @work.header.tool_names),
                   call_index: 0, iteration:, sub_operation: reviews
        )
      end

      def decide(plan, review, reviews)
        count = { work_plan_reviews: reviews + 1 }
        unless review.fetch('decision') == 'accept'
          issues = review.fetch('issues').map { |issue| "- #{issue}" }.join("\n")
          return Outcome.new(text: "Plan not accepted. Reviewer issues:\n#{issues}", update: count)
        end

        accepted = { 'document' => plan.document, 'digest' => plan.digest,
                     'review_digest' => SessionRecords.digest(review) }
        Outcome.new(text: 'Plan accepted.', update: count.merge(work_plan: accepted, work_boundary: true))
      end

      def limit_text
        "Plan not accepted and the review limit (#{MAX_PLAN_REVIEWS}) is reached. " \
          'Stop and explain what blocks the plan.'
      end
    end
    # rubocop:enable Metrics/AbcSize
  end
end
