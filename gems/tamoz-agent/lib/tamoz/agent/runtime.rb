# frozen_string_literal: true

require "json"
require "digest"

module Tamoz
  module Agent
    Event = Data.define(:type, :data)
    Result = Data.define(:answer, :satisfied, :evidence, :plan, :review, :observations)

    class Runtime
      MAX_TASK_BYTES = 16 * 1024
      MAX_OBSERVATION_BYTES = 160 * 1024
      MAX_REPAIR_ATTEMPTS = 2

      PLAN_SYSTEM = Deliberation::PLAN_SYSTEM
      REVIEW_SYSTEM = Deliberation::REVIEW_SYSTEM
      VERIFY_SYSTEM = Deliberation::VERIFY_SYSTEM

      attr_reader :model, :toolbox, :max_plan_attempts, :approval

      def initialize(model:, toolbox:, max_plan_attempts: 3, approval: nil)
        raise ArgumentError, "model must respond to generate" unless model.respond_to?(:generate)
        unless max_plan_attempts.is_a?(Integer) && max_plan_attempts.between?(1, 10)
          raise ArgumentError, "max_plan_attempts must be between 1 and 10"
        end

        @model = model
        @toolbox = toolbox
        @max_plan_attempts = max_plan_attempts
        @approval = approval
      end

      def run(task)
        task = String(task).strip
        raise ArgumentError, "task must not be empty" if task.empty?
        raise ArgumentError, "task exceeds #{MAX_TASK_BYTES} bytes" if task.bytesize > MAX_TASK_BYTES

        emit(:task_started, "task" => task) { |event| yield event if block_given? }
        if toolbox.action_capable?
          action = run_action_mode(task) { |event| yield event if block_given? }
          plan = action.fetch(:plan)
          review = action.fetch(:review)
          observations = action.fetch(:observations)
          verification_context = {
            "configured_check_passed" => action.fetch(:check_passed),
            "terminal_reason" => action.fetch(:terminal_reason)
          }
        else
          plan, review = accepted_plan(
            task,
            phase: :read_only,
            allowed_tools: toolbox.names,
            evidence: [],
            metadata: {},
            planning_context: {}
          ) { |event| yield event if block_given? }
          observations, = execute(plan, phase: :read_only, metadata: {}) do |event|
            yield event if block_given?
          end
          verification_context = {}
        end
        result = verify(task, plan, review, observations, verification_context:)
        result = enforce_configured_check(result, verification_context)
        emit(:completed, result_to_h(result)) { |event| yield event if block_given? }
        result
      end

      private

      def run_action_mode(task)
        discovery_plan, _discovery_review = accepted_plan(
          task,
          phase: :discovery,
          allowed_tools: toolbox.read_only_names,
          evidence: [],
          metadata: {},
          planning_context: {}
        ) { |event| yield event }
        discovery_observations, = execute(
          discovery_plan,
          phase: :discovery,
          metadata: {}
        ) { |event| yield event }

        all_observations = discovery_observations.dup
        prior_plans = []
        prior_reviews = []
        seen_actions = {}
        seen_failures = {}
        repair_attempt = 0
        plan = nil
        review = nil
        check_passed = false
        terminal_reason = "no_check"

        loop do
          phase = repair_attempt.zero? ? :action : :repair
          metadata = {"repair_attempt" => repair_attempt}
          planning_context = {
            "prior_action_plans" => prior_plans.map(&:to_h),
            "prior_action_reviews" => prior_reviews,
            "prior_action_signatures" => seen_actions.keys.sort,
            "prior_failure_signatures" => seen_failures.keys.sort
          }
          if repair_attempt.positive?
            emit(
              :repair_started,
              metadata.merge("observations" => all_observations.length)
            ) { |event| yield event }
          end

          begin
            candidate_plan, candidate_review = accepted_plan(
              task,
              phase:,
              allowed_tools: toolbox.names,
              evidence: all_observations,
              metadata:,
              planning_context:
            ) { |event| yield event }
          rescue PlanRejectedError
            raise if repair_attempt.zero?

            terminal_reason = "repair_plan_rejected"
            emit(:repair_stopped, metadata.merge("reason" => terminal_reason)) { |event| yield event }
            break
          end

          signature = action_signature(candidate_plan)
          if seen_actions.key?(signature)
            terminal_reason = "repeated_action"
            emit(
              :repair_stopped,
              metadata.merge("reason" => terminal_reason, "action_signature" => signature)
            ) { |event| yield event }
            break
          end
          seen_actions[signature] = true
          plan = candidate_plan
          review = candidate_review
          prior_plans << plan
          prior_reviews << review

          action_observations, check_receipt = execute(
            plan,
            phase:,
            metadata:,
            initial_bytes: observation_bytes(all_observations)
          ) { |event| yield event }
          all_observations.concat(action_observations)

          unless check_receipt
            terminal_reason = "completed_without_check"
            break
          end
          if check_receipt.passed?
            check_passed = true
            terminal_reason = "check_passed"
            break
          end

          failure_signature = check_receipt.failure_signature
          if seen_failures.key?(failure_signature)
            terminal_reason = "repeated_failure"
            emit(
              :repair_stopped,
              metadata.merge("reason" => terminal_reason, "failure_signature" => failure_signature)
            ) { |event| yield event }
            break
          end
          seen_failures[failure_signature] = true

          if repair_attempt >= MAX_REPAIR_ATTEMPTS
            terminal_reason = "repair_attempts_exhausted"
            emit(:repair_stopped, metadata.merge("reason" => terminal_reason)) { |event| yield event }
            break
          end
          repair_attempt += 1
        end

        {
          plan:,
          review:,
          observations: Plan.deep_freeze(all_observations),
          check_passed:,
          terminal_reason:
        }.freeze
      end

      def accepted_plan(
        task,
        phase:,
        allowed_tools:,
        evidence:,
        metadata:,
        planning_context:
      )
        event_context = {"phase" => phase.to_s}.merge(metadata)
        feedback = []
        max_plan_attempts.times do |offset|
          attempt = offset + 1
          raw = model.generate(
            stage: :plan,
            system: PLAN_SYSTEM,
            prompt: planning_prompt(
              task,
              phase,
              allowed_tools,
              evidence,
              feedback,
              planning_context
            )
          )
          plan = Plan.parse(raw)
          emit(:plan_drafted, event_context.merge("attempt" => attempt, "plan" => plan.to_h)) do |event|
            yield event
          end

          structural_issues = structural_issues(plan, phase:, allowed_tools:)
          emit(
            :plan_reviewed,
            event_context.merge(
              "attempt" => attempt,
              "layer" => "structural",
              "decision" => structural_issues.empty? ? "accept" : "revise",
              "issues" => structural_issues
            )
          ) { |event| yield event }
          unless structural_issues.empty?
            feedback = structural_issues
            next
          end

          review = semantic_review(task, plan, phase:, evidence:, planning_context:)
          emit(:plan_reviewed, review.merge(event_context).merge("attempt" => attempt, "layer" => "semantic")) do |event|
            yield event
          end
          if review.fetch("decision") == "accept"
            emit(:plan_accepted, event_context.merge("attempt" => attempt, "plan" => plan.to_h)) do |event|
              yield event
            end
            return [plan, Plan.deep_freeze(review)]
          end

          feedback = review.fetch("issues")
        rescue ProtocolError => error
          feedback = [error.message]
          emit(
            :plan_reviewed,
            event_context.merge(
              "attempt" => attempt,
              "layer" => "protocol",
              "decision" => "revise",
              "issues" => feedback
            )
          ) { |event| yield event }
        end

        raise PlanRejectedError, "no plan passed review after #{max_plan_attempts} attempts"
      end

      def structural_issues(plan, phase:, allowed_tools:)
        Deliberation.structural_issues(plan, phase:, allowed_tools:, toolbox:)
      end

      def semantic_review(task, plan, phase:, evidence:, planning_context:)
        raw = model.generate(
          stage: :review,
          system: REVIEW_SYSTEM,
          prompt: Deliberation.review_prompt(
            task,
            plan,
            phase:,
            evidence:,
            planning_context:
          )
        )
        Deliberation.parse_review(raw)
      end

      def execute(plan, phase:, metadata:, initial_bytes: 0)
        event_context = {"phase" => phase.to_s}.merge(metadata)
        observations = []
        total_bytes = initial_bytes
        last_check_receipt = nil
        plan.steps.each do |step|
          if step.tool.nil?
            observations << {
              **event_context,
              "step_id" => step.id,
              "tool" => nil,
              "output" => "No tool required."
            }
            next
          end

          if toolbox.approval_required?(step.tool)
            maximum_output = toolbox.maximum_effect_output_bytes(step.tool)
            if total_bytes + maximum_output > MAX_OBSERVATION_BYTES
              raise ToolError, "insufficient observation budget for #{step.tool}"
            end
            preview = toolbox.preview(step.tool, step.arguments)
            request = {
              **event_context,
              "step_id" => step.id,
              "tool" => step.tool,
              "arguments" => step.arguments,
              "preview" => preview
            }
            emit(:approval_requested, request) { |event| yield event }
            approved = approval&.call(
              tool: step.tool,
              arguments: step.arguments,
              preview:
            )
            unless approved == true
              emit(:approval_denied, request.except("preview")) { |event| yield event }
              raise ApprovalDeniedError, "approval denied for #{step.tool}"
            end
            emit(:approval_granted, request.except("preview")) { |event| yield event }
          end

          emit(
            :tool_started,
            event_context.merge(
              "step_id" => step.id,
              "tool" => step.tool,
              "arguments" => step.arguments
            )
          ) { |event| yield event }
          tool_result = toolbox.execute(step.tool, step.arguments)
          output = String(tool_result)
          total_bytes += output.bytesize
          if total_bytes > MAX_OBSERVATION_BYTES
            raise ToolError, "tool observations exceed #{MAX_OBSERVATION_BYTES} bytes"
          end
          observation = {
            **event_context,
            "step_id" => step.id,
            "tool" => step.tool,
            "output" => output
          }
          if tool_result.is_a?(CheckReceipt)
            observation["check"] = {
              "name" => tool_result.name,
              "outcome" => tool_result.outcome,
              "passed" => tool_result.passed?,
              "failure_signature" => tool_result.failure_signature
            }
          end
          observations << observation
          emit(:tool_completed, observation) { |event| yield event }
          if tool_result.is_a?(CheckReceipt)
            last_check_receipt = tool_result
            break if tool_result.failed?
          end
        end
        [Plan.deep_freeze(observations), last_check_receipt].freeze
      end

      def observation_bytes(observations)
        observations.sum { |entry| entry.fetch("output").bytesize }
      end

      def verify(task, plan, review, observations, verification_context:)
        raw = model.generate(
          stage: :verify,
          system: VERIFY_SYSTEM,
          prompt: Deliberation.verification_prompt(
            task,
            plan,
            review,
            observations,
            verification_context:
          )
        )
        document = Deliberation.parse_verification(raw)
        Result.new(
          answer: document.fetch("answer"),
          satisfied: document.fetch("satisfied"),
          evidence: document.fetch("evidence"),
          plan:,
          review:,
          observations:
        )
      end

      def enforce_configured_check(result, verification_context)
        return result unless toolbox.action_capable? && !toolbox.checks.empty?
        return result if verification_context.fetch("configured_check_passed") == true

        reason = verification_context.fetch("terminal_reason")
        Result.new(
          answer: result.answer,
          satisfied: false,
          evidence: (result.evidence + ["framework: no configured check passed (#{reason})"]).freeze,
          plan: result.plan,
          review: result.review,
          observations: result.observations
        )
      end

      def action_signature(plan)
        Deliberation.action_signature(plan, toolbox:)
      end

      def planning_prompt(task, phase, allowed_tools, evidence, feedback, planning_context)
        Deliberation.planning_prompt(
          task,
          phase,
          allowed_tools,
          evidence,
          feedback,
          planning_context,
          toolbox:
        )
      end

      def emit(type, data)
        yield Event.new(type:, data: Plan.deep_freeze(data))
      end

      def result_to_h(result)
        {
          "answer" => result.answer,
          "satisfied" => result.satisfied,
          "evidence" => result.evidence
        }
      end
    end
  end
end
