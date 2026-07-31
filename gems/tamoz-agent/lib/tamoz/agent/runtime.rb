# frozen_string_literal: true

require "json"

module Tamoz
  module Agent
    Event = Data.define(:type, :data)
    Result = Data.define(:answer, :satisfied, :evidence, :plan, :review, :observations)

    class Runtime
      MAX_TASK_BYTES = 16 * 1024
      MAX_OBSERVATION_BYTES = 160 * 1024

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
          discovery_plan, _discovery_review = accepted_plan(
            task,
            phase: :discovery,
            allowed_tools: toolbox.read_only_names,
            evidence: []
          ) { |event| yield event if block_given? }
          discovery_observations = execute(discovery_plan, phase: :discovery) do |event|
            yield event if block_given?
          end
          plan, review = accepted_plan(
            task,
            phase: :action,
            allowed_tools: toolbox.names,
            evidence: discovery_observations
          ) { |event| yield event if block_given? }
          action_observations = execute(
            plan,
            phase: :action,
            initial_bytes: observation_bytes(discovery_observations)
          ) do |event|
            yield event if block_given?
          end
          observations = Plan.deep_freeze(discovery_observations + action_observations)
        else
          plan, review = accepted_plan(
            task,
            phase: :read_only,
            allowed_tools: toolbox.names,
            evidence: []
          ) { |event| yield event if block_given? }
          observations = execute(plan, phase: :read_only) do |event|
            yield event if block_given?
          end
        end
        result = verify(task, plan, review, observations)
        emit(:completed, result_to_h(result)) { |event| yield event if block_given? }
        result
      end

      private

      def accepted_plan(task, phase:, allowed_tools:, evidence:)
        feedback = []
        max_plan_attempts.times do |offset|
          attempt = offset + 1
          raw = model.generate(
            stage: :plan,
            system: PLAN_SYSTEM,
            prompt: planning_prompt(task, phase, allowed_tools, evidence, feedback)
          )
          plan = Plan.parse(raw)
          emit(:plan_drafted, "phase" => phase.to_s, "attempt" => attempt, "plan" => plan.to_h) do |event|
            yield event
          end

          structural_issues = structural_issues(plan, allowed_tools:)
          emit(
            :plan_reviewed,
            "phase" => phase.to_s,
            "attempt" => attempt,
            "layer" => "structural",
            "decision" => structural_issues.empty? ? "accept" : "revise",
            "issues" => structural_issues
          ) { |event| yield event }
          unless structural_issues.empty?
            feedback = structural_issues
            next
          end

          review = semantic_review(task, plan, phase:, evidence:)
          emit(:plan_reviewed, review.merge("phase" => phase.to_s, "attempt" => attempt, "layer" => "semantic")) do |event|
            yield event
          end
          if review.fetch("decision") == "accept"
            emit(:plan_accepted, "phase" => phase.to_s, "attempt" => attempt, "plan" => plan.to_h) do |event|
              yield event
            end
            return [plan, Plan.deep_freeze(review)]
          end

          feedback = review.fetch("issues")
        rescue ProtocolError => error
          feedback = [error.message]
          emit(
            :plan_reviewed,
            "phase" => phase.to_s,
            "attempt" => attempt,
            "layer" => "protocol",
            "decision" => "revise",
            "issues" => feedback
          ) { |event| yield event }
        end

        raise PlanRejectedError, "no plan passed review after #{max_plan_attempts} attempts"
      end

      def structural_issues(plan, allowed_tools:)
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
        issues.freeze
      end

      def semantic_review(task, plan, phase:, evidence:)
        raw = model.generate(
          stage: :review,
          system: REVIEW_SYSTEM,
          prompt: JSON.pretty_generate(
            "task" => task,
            "phase" => phase.to_s,
            "evidence" => evidence,
            "plan" => plan.to_h
          )
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

      def execute(plan, phase:, initial_bytes: 0)
        observations = []
        total_bytes = initial_bytes
        plan.steps.each do |step|
          if step.tool.nil?
            observations << {
              "phase" => phase.to_s,
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
              "phase" => phase.to_s,
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
            "phase" => phase.to_s,
            "step_id" => step.id,
            "tool" => step.tool,
            "arguments" => step.arguments
          ) { |event| yield event }
          output = String(toolbox.execute(step.tool, step.arguments))
          total_bytes += output.bytesize
          if total_bytes > MAX_OBSERVATION_BYTES
            raise ToolError, "tool observations exceed #{MAX_OBSERVATION_BYTES} bytes"
          end
          observation = {
            "phase" => phase.to_s,
            "step_id" => step.id,
            "tool" => step.tool,
            "output" => output
          }
          observations << observation
          emit(:tool_completed, observation) { |event| yield event }
        end
        Plan.deep_freeze(observations)
      end

      def observation_bytes(observations)
        observations.sum { |entry| entry.fetch("output").bytesize }
      end

      def verify(task, plan, review, observations)
        raw = model.generate(
          stage: :verify,
          system: VERIFY_SYSTEM,
          prompt: JSON.pretty_generate(
            "task" => task,
            "accepted_plan" => plan.to_h,
            "review" => review,
            "observations" => observations
          )
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

      def planning_prompt(task, phase, allowed_tools, evidence, feedback)
        phase_instruction = if phase == :discovery
                              "Gather only the evidence needed to prepare a later action plan. Do not mutate or run commands."
                            elsif phase == :action
                              "Use the discovery evidence to propose the exact bounded actions and verification checks."
                            else
                              "Answer using read-only workspace evidence."
                            end
        JSON.pretty_generate(
          "task" => task,
          "phase" => phase.to_s,
          "phase_instruction" => phase_instruction,
          "workspace_root" => ".",
          "path_policy" => "All tool paths are relative to the workspace root.",
          "available_tools" => toolbox.descriptions.slice(*allowed_tools),
          "evidence_from_discovery" => evidence,
          "feedback_from_previous_attempt" => feedback
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
