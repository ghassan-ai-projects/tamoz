# frozen_string_literal: true

module Tamoz
  module Agent
    class Runtime
      # Bounded plan drafting for one phase: the model drafts a plan, structural
      # policy review adjudicates first, semantic review second, and each layer's
      # feedback feeds the next attempt until max_plan_attempts is exhausted.
      #
      # :nodoc:
      module PlanReview
        # What one phase's plan is drafted and reviewed against.
        PlanInputs = Data.define(:phase, :allowed_tools, :evidence, :planning_context) do
          def initialize(phase:, allowed_tools:, evidence: [], planning_context: {}) = super
        end

        private

        def accepted_plan(task, inputs, metadata: {}, &block)
          event_context = { 'phase' => inputs.phase.to_s }.merge(metadata)
          feedback = []
          # D-8 Fix C (RC-3): track the last attempt's feedback layer so the
          # PlanRejectedError discloses a bounded summary of STRUCTURAL-layer issues
          # only; semantic (model-authored) and protocol (provider-quoting) feedback
          # yields the generic phrase.
          last_layer = nil
          max_plan_attempts.times do |offset|
            accepted, feedback, last_layer =
              plan_attempt(task, inputs, feedback, event_context.merge('attempt' => offset + 1), &block)
            return accepted if accepted
          end

          raise PlanRejectedError, plan_rejected_message(last_layer, feedback)
        end

        def plan_attempt(task, inputs, feedback, context, &)
          plan = Plan.parse(
            model_generate(stage: :plan, system: PLAN_SYSTEM, prompt: planning_prompt(task, inputs, feedback))
          )
          emit(:plan_drafted, context.merge('plan' => plan.to_h), &)

          issues = structural_issues(plan, phase: inputs.phase, allowed_tools: inputs.allowed_tools)
          emit(:plan_reviewed,
               context.merge('layer' => 'structural', 'decision' => issues.empty? ? 'accept' : 'revise',
                             'issues' => issues), &)
          return [nil, issues, :structural] unless issues.empty?

          semantic_attempt(task, plan, inputs, context, &)
        rescue ProtocolError => e
          emit(:plan_reviewed, context.merge('layer' => 'protocol', 'decision' => 'revise', 'issues' => [e.message]), &)
          [nil, [e.message], :protocol]
        end

        def semantic_attempt(task, plan, inputs, context, &)
          review = semantic_review(task, plan, phase: inputs.phase, evidence: inputs.evidence,
                                               planning_context: inputs.planning_context)
          emit(:plan_reviewed, review.merge(context).merge('layer' => 'semantic'), &)
          return [nil, review.fetch('issues'), :semantic] unless review.fetch('decision') == 'accept'

          emit(:plan_accepted, context.merge('plan' => plan.to_h), &)
          [[plan, Tamoz::Core.deep_freeze(review)], nil, nil]
        end

        # D-8 Fix C (RC-3): bounded structural-only rejection disclosure, mirroring
        # `SessionNodes#plan_rejected_message`. `Error.disclosable_message` clamps and
        # scrubs again at the safe_message boundary.
        def plan_rejected_message(last_layer, feedback)
          prefix = "no plan passed review after #{max_plan_attempts} attempts"
          return "#{prefix}: the plan did not pass review; the last feedback is not discloseable" \
            unless last_layer == :structural

          "#{prefix}: #{feedback.first(3).join('; ')}"
        end

        def structural_issues(plan, phase:, allowed_tools:)
          Deliberation.structural_issues(plan, phase:, allowed_tools:, toolbox:)
        end

        def semantic_review(task, plan, phase:, evidence:, planning_context:)
          raw = model_generate(
            stage: :review,
            system: REVIEW_SYSTEM,
            prompt: Deliberation.review_prompt(
              task,
              plan,
              phase:,
              evidence:,
              planning_context:,
              tool_descriptions: Deliberation.merge_tool_surfaces(
                toolbox.descriptions,
                toolbox.names,
                {}
              )
            )
          )
          Deliberation.parse_review(raw)
        end

        def planning_prompt(task, inputs, feedback)
          Deliberation.planning_prompt(
            task, inputs.phase, inputs.allowed_tools, inputs.evidence, feedback, inputs.planning_context, toolbox:
          )
        end
      end
      private_constant :PlanReview
    end
  end
end
