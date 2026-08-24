# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # Executes one ordered planner, structural-review, and semantic-review pass.
    # :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:LongParameterList
    # :reek:TooManyMethods :reek:TooManyStatements :reek:UncommunicativeVariableName :reek:UtilityFunction
    # The values and helper phases mirror the existing review wire records exactly.
    class SessionPlanAttempt
      # Immutable state passed through one plan/review attempt.
      Details = Data.define(
        :attempt, :phase, :repair_attempt, :task, :evidence, :allowed_tools,
        :mcp_tools, :planning_context, :feedback, :plans, :reviews, :ambiguity
      ) do
        def plan_id = "#{phase}.#{repair_attempt}.#{attempt}"
      end

      # Immutable result returned to the deliberation loop.
      Result = Data.define(:update, :feedback, :plans, :reviews, :ambiguity)
      # Canonical plan data shared by structural and semantic review.
      PlanData = Data.define(:plan, :plan_hash, :plan_digest, :plan_id)

      def initialize(services:)
        @services = services
      end

      def run(state, context, details:)
        call = plan_call(context, details)
        return blocked_result(call, details) unless call.status == :succeeded

        details = details.with(ambiguity: increment(details.ambiguity, call))
        plan, feedback = parse_plan(call, details)
        return result(details, feedback:) unless plan

        plan_data, feedback = record_plan(plan, details)
        return result(details, feedback:) unless plan_data

        structural = structural_review(plan, details)
        append_structural_review(details, plan_data, structural)
        return result(details, feedback: structural) unless structural.empty?

        semantic_result(state, context, details, plan_data)
      end

      private

      def plan_call(context, details)
        configuration = @services.configuration
        @services.effects.model_call(
          context,
          stage: :plan,
          system: Tamoz::Agent::Deliberation::PLAN_SYSTEM,
          prompt: Tamoz::Agent::Deliberation.planning_prompt(
            details.task,
            details.phase,
            details.allowed_tools,
            details.evidence,
            details.feedback,
            details.planning_context,
            toolbox: configuration.toolbox,
            mcp_tools: details.mcp_tools,
            capability_descriptions: configuration.capabilities.descriptions
          ),
          call_index: details.attempt * 2
        )
      end

      def increment(ambiguity, call)
        ambiguity + (call.attempt_number > 1 ? 1 : 0)
      end

      def parse_plan(call, details)
        [Plan.parse(call.value), details.feedback]
      rescue ProtocolError => e
        details.reviews << SessionRecords.build(
          'review',
          review_id: "#{details.plan_id}.protocol",
          plan_id: details.plan_id,
          plan_digest: Digest::SHA256.hexdigest(String(call.value)),
          layer: 'protocol',
          decision: 'revise',
          issues: [e.message],
          rationale: 'the planner did not return a usable plan document'
        )
        [nil, [e.message]]
      end

      def record_plan(plan, details)
        plan_hash = Tamoz::Agent::Deliberation.canonical(plan.to_h)
        plan_digest = SessionRecords.digest(plan_hash)
        details.plans << plan_record(details, plan_hash, plan_digest)
        [PlanData.new(plan:, plan_hash:, plan_digest:, plan_id: details.plan_id), details.feedback]
      rescue Tamoz::SensitiveValueError => e
        details.reviews << SessionRecords.build(
          'review',
          review_id: "#{details.plan_id}.credentials",
          plan_id: details.plan_id,
          plan_digest:,
          layer: 'protocol',
          decision: 'revise',
          issues: [e.message],
          rationale: 'the plan step arguments carry a credential-shaped value'
        )
        [nil, [e.message]]
      end

      def plan_record(details, plan_hash, plan_digest)
        SessionRecords.build(
          'plan',
          plan_id: details.plan_id,
          phase: details.phase.to_s,
          attempt: details.attempt,
          plan: plan_hash,
          plan_digest:
        )
      end

      def structural_review(plan, details)
        configuration = @services.configuration
        Tamoz::Agent::Deliberation.structural_issues(
          plan,
          phase: details.phase,
          allowed_tools: details.allowed_tools,
          toolbox: configuration.toolbox,
          capabilities: configuration.capabilities
        )
      end

      def append_structural_review(details, plan_data, issues)
        details.reviews << SessionRecords.build(
          'review',
          review_id: "#{plan_data.plan_id}.structural",
          plan_id: plan_data.plan_id,
          plan_digest: plan_data.plan_digest,
          layer: 'structural',
          decision: issues.empty? ? 'accept' : 'revise',
          issues:,
          rationale: 'deterministic structural review'
        )
      end

      def semantic_result(state, context, details, plan_data)
        call = semantic_call(context, details, plan_data)
        return blocked_result(call, details) unless call.status == :succeeded

        details = details.with(ambiguity: increment(details.ambiguity, call))
        review, feedback = parse_review(call, details)
        return result(details, feedback:) unless review

        details.reviews << semantic_record(plan_data, review)
        update = route_review(state, context, details, plan_data, review)
        result(details, feedback: review.fetch('issues'), update:)
      end

      # rubocop:disable Metrics/AbcSize -- the review prompt intentionally binds every visible capability surface.
      def semantic_call(context, details, plan_data)
        @services.effects.model_call(
          context,
          stage: :review,
          system: Tamoz::Agent::Deliberation::REVIEW_SYSTEM,
          prompt: Tamoz::Agent::Deliberation.review_prompt(
            details.task,
            plan_data.plan,
            phase: details.phase,
            evidence: details.evidence,
            planning_context: details.planning_context,
            tool_descriptions: Tamoz::Agent::Deliberation.merge_tool_surfaces(
              @services.configuration.toolbox.descriptions.merge(
                @services.configuration.capabilities.descriptions
              ),
              details.allowed_tools,
              details.mcp_tools
            )
          ),
          call_index: (details.attempt * 2) + 1
        )
      end
      # rubocop:enable Metrics/AbcSize

      def semantic_record(plan_data, review)
        SessionRecords.build(
          'review',
          review_id: "#{plan_data.plan_id}.semantic",
          plan_id: plan_data.plan_id,
          plan_digest: plan_data.plan_digest,
          layer: 'semantic',
          decision: review.fetch('decision'),
          issues: review.fetch('issues'),
          rationale: review.fetch('rationale')
        )
      end

      def parse_review(call, details)
        [Tamoz::Agent::Deliberation.parse_review(call.value), details.feedback]
      rescue ProtocolError => e
        details.reviews << SessionRecords.build(
          'review',
          review_id: "#{details.plan_id}.semantic",
          plan_id: details.plan_id,
          plan_digest: details.plan_digest,
          layer: 'protocol',
          decision: 'revise',
          issues: [e.message],
          rationale: 'the reviewer did not return a usable review document'
        )
        [nil, [e.message]]
      end

      def route_review(state, context, details, plan_data, review)
        case review.fetch('decision')
        when 'accept'
          accept_review(state, details, plan_data)
        when 'needs_input'
          clarify_review(state, context, details, plan_data, review)
        end
      end

      def accept_review(state, details, plan_data)
        acceptance = SessionPlanOutcomes::Acceptance.new(
          plan_data.plan, plan_data.plan_id, plan_data.plan_digest, plan_data.plan_hash,
          details.phase, details.plans, details.reviews, details.ambiguity
        )
        @services.plan_outcomes.accept_plan(state, acceptance:)
      end

      def clarify_review(state, context, details, plan_data, review)
        clarification = SessionPlanOutcomes::Clarification.new(
          context, plan_data.plan_id, plan_data.plan_digest, review, details.phase,
          details.repair_attempt, details.plans, details.reviews, details.ambiguity
        )
        @services.plan_outcomes.clarify_update(state, clarification:)
      end

      def result(details, feedback:, update: nil)
        Result.new(
          update:,
          feedback:,
          plans: details.plans,
          reviews: details.reviews,
          ambiguity: details.ambiguity
        )
      end

      def blocked_result(call, details)
        result(
          details,
          feedback: details.feedback,
          update: @services.evidence.blocked_update(call, 'model call outcome is unknown')
        )
      end
    end
  end
end
