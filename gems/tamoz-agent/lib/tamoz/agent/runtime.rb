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

      PLAN_SYSTEM = <<~TEXT.freeze
        You are the planning stage of Tamoz. You must plan before any task action.
        Return only one JSON object with keys: goal, done_when, steps.
        done_when is a non-empty array of observable completion conditions.
        steps is a non-empty array. Each step has id, purpose, tool, arguments, verification.
        tool is one available tool name, or null when no workspace evidence is needed.
        Use only the tools listed by the caller. Do not claim that an action already happened.
      TEXT

      REVIEW_SYSTEM = <<~TEXT.freeze
        You are Tamoz's isolated semantic plan reviewer. No task action is allowed here.
        Check goal fit, evidence needs, ordering, proportionality, and whether verification
        can demonstrate completion. Return only JSON with decision (accept or revise),
        issues (an array of concrete strings), and rationale (a string).
      TEXT

      VERIFY_SYSTEM = <<~TEXT.freeze
        You are Tamoz's final verification stage. Use only the supplied task, accepted plan,
        and tool observations. Do not invent evidence. Return only JSON with answer (string),
        satisfied (boolean), and evidence (array of strings). If evidence is insufficient,
        set satisfied to false and say exactly what remains unknown.
      TEXT

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
        issues = []
        issues << "goal must not be empty" if plan.goal.strip.empty?
        issues << "done_when must contain at least one condition" if plan.done_when.empty?
        issues << "steps must contain at least one step" if plan.steps.empty?
        issues << "step ids must be unique" if plan.steps.map(&:id).uniq.length != plan.steps.length
        plan.steps.each do |step|
          prefix = "step #{step.id.inspect}"
          issues << "#{prefix} id must not be empty" if step.id.strip.empty?
          issues << "#{prefix} purpose must not be empty" if step.purpose.strip.empty?
          issues << "#{prefix} verification must not be empty" if step.verification.strip.empty?
          if step.tool && !allowed_tools.include?(step.tool)
            issues << "#{prefix} uses unavailable tool #{step.tool.inspect}"
          end
          unless step.arguments.is_a?(Hash)
            issues << "#{prefix} arguments must be an object"
          end
          if step.tool.nil? && !step.arguments.empty?
            issues << "#{prefix} has arguments without a tool"
          elsif step.tool
            begin
              toolbox.validate(step.tool, step.arguments)
            rescue ToolError => error
              issues << "#{prefix} is invalid: #{error.message}"
            end
          end
        end
        if %i[action repair].include?(phase) && !toolbox.checks.empty?
          check_indexes = plan.steps.each_index.select { |index| plan.steps[index].tool == "run_check" }
          patch_indexes = plan.steps.each_index.select { |index| plan.steps[index].tool == "apply_patch" }
          issues << "action plan must run a configured check" if check_indexes.empty?
          if !patch_indexes.empty? && !check_indexes.empty? && patch_indexes.max > check_indexes.max
            issues << "action plan must not patch after its final configured check"
          end
        end
        issues.freeze
      end

      def semantic_review(task, plan, phase:, evidence:, planning_context:)
        review_input = {
          "task" => task,
          "phase" => phase.to_s,
          "evidence" => evidence,
          "plan" => plan.to_h
        }
        review_input["planning_context"] = planning_context unless planning_context.empty?
        raw = model.generate(
          stage: :review,
          system: REVIEW_SYSTEM,
          prompt: JSON.pretty_generate(review_input)
        )
        document = Plan.parse_object(raw)
        decision = Plan.string(document.fetch("decision"), name: "review decision")
        issues = Plan.strings(document.fetch("issues"), name: "review issues")
        rationale = Plan.string(document.fetch("rationale"), name: "review rationale")
        unless %w[accept revise].include?(decision)
          raise ProtocolError, "review decision must be accept or revise"
        end
        raise ProtocolError, "revised plan review must include issues" if decision == "revise" && issues.empty?

        {"decision" => decision, "issues" => issues, "rationale" => rationale}
      rescue KeyError, TypeError => error
        raise ProtocolError, "invalid plan review: #{error.message}"
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
        verification_input = {
          "task" => task,
          "accepted_plan" => plan.to_h,
          "review" => review,
          "observations" => observations
        }
        unless verification_context.empty?
          verification_input["verification_context"] = verification_context
        end
        raw = model.generate(
          stage: :verify,
          system: VERIFY_SYSTEM,
          prompt: JSON.pretty_generate(verification_input)
        )
        document = Plan.parse_object(raw)
        answer = Plan.string(document.fetch("answer"), name: "verification answer")
        satisfied = document.fetch("satisfied")
        evidence = Plan.strings(document.fetch("evidence"), name: "verification evidence")
        unless satisfied == true || satisfied == false
          raise ProtocolError, "verification satisfied must be boolean"
        end

        Result.new(answer:, satisfied:, evidence:, plan:, review:, observations:)
      rescue KeyError, TypeError => error
        raise ProtocolError, "invalid verification: #{error.message}"
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
        actions = plan.steps.filter_map do |step|
          next unless step.tool && toolbox.approval_required?(step.tool)

          {"tool" => step.tool, "arguments" => step.arguments}
        end
        Digest::SHA256.hexdigest(JSON.generate(canonical(actions)))
      end

      def canonical(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, entry), normalized|
            normalized[String(key)] = canonical(entry)
          end.sort.to_h
        when Array
          value.map { |entry| canonical(entry) }
        else
          value
        end
      end

      def planning_prompt(task, phase, allowed_tools, evidence, feedback, planning_context)
        phase_instruction = if phase == :discovery
                              "Gather only the evidence needed to prepare a later action plan. Do not mutate or run commands."
                            elsif phase == :action
                              "Use the discovery evidence to propose the exact bounded actions and verification checks."
                            elsif phase == :repair
                              "Use all prior plans and receipts to propose a different bounded repair and a configured verification check. Do not repeat a prior action signature."
                            else
                              "Answer using read-only workspace evidence."
                            end
        plan_input = {
          "task" => task,
          "phase" => phase.to_s,
          "phase_instruction" => phase_instruction,
          "workspace_root" => ".",
          "path_policy" => "All tool paths are relative to the workspace root.",
          "available_tools" => toolbox.descriptions.slice(*allowed_tools),
          "evidence_from_discovery" => evidence,
          "feedback_from_previous_attempt" => feedback
        }
        plan_input["planning_context"] = planning_context unless planning_context.empty?
        JSON.pretty_generate(plan_input)
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
