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

          action_observations, check_receipt, tool_failure = execute(
            plan,
            phase:,
            metadata:,
            initial_bytes: observation_bytes(all_observations)
          ) { |event| yield event }
          all_observations.concat(action_observations)

          # A repairable tool rejection short-circuits the plan and enters the same
          # bounded repair loop a failed configured check uses: one shared
          # `repair_attempt` counter, one shared failure-signature set.
          if tool_failure
            failure_signature = tool_failure.fetch("failure_signature")
            repeated_reason = "repeated_tool_failure"
          elsif check_receipt.nil?
            terminal_reason = "completed_without_check"
            break
          elsif check_receipt.passed?
            check_passed = true
            terminal_reason = "check_passed"
            break
          else
            failure_signature = check_receipt.failure_signature
            repeated_reason = "repeated_failure"
          end

          if seen_failures.key?(failure_signature)
            terminal_reason = repeated_reason
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
        # D-8 Fix C (RC-3): track the last attempt's feedback layer so the
        # PlanRejectedError discloses a bounded summary of STRUCTURAL-layer issues
        # only; semantic (model-authored) and protocol (provider-quoting) feedback
        # yields the generic phrase.
        last_layer = nil
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
            last_layer = :structural
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
          last_layer = :semantic
        rescue ProtocolError => error
          feedback = [error.message]
          last_layer = :protocol
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

        raise PlanRejectedError, plan_rejected_message(last_layer, feedback)
      end

      # D-8 Fix C (RC-3): bounded structural-only rejection disclosure, mirroring
      # `SessionNodes#plan_rejected_message`. `Error.disclosable_message` clamps and
      # scrubs again at the safe_message boundary.
      def plan_rejected_message(last_layer, feedback)
        prefix = "no plan passed review after #{max_plan_attempts} attempts"
        return "#{prefix}: the plan did not pass review; the last feedback is not discloseable" \
          unless last_layer == :structural

        "#{prefix}: #{feedback.first(3).join("; ")}"
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
        tool_failure = nil
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

          # D-8 Fix A (RC-1): resolve an absent mutation digest exactly once, at the
          # start of this step. The SAME resolved arguments feed the preview, the
          # approval callback, and the actual execute, so a mutation between preview
          # and execute — or inside the approval callback — trips `prepare_patch`'s
          # live equality check ("file changed") and never patches unapproved bytes.
          # Emitted events keep the PLAN's arguments so the execution always matches
          # the accepted plan step for audit purposes; the injected digest is
          # execution metadata binding execution to the approved state.
          effect_arguments = resolved_effect_arguments(step)
          begin
            if toolbox.approval_required?(step.tool)
              maximum_output = toolbox.maximum_effect_output_bytes(step.tool)
              if total_bytes + maximum_output > MAX_OBSERVATION_BYTES
                raise ToolError, "insufficient observation budget for #{step.tool}"
              end
              preview = toolbox.preview(step.tool, effect_arguments)
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
                arguments: effect_arguments,
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
            tool_result = toolbox.execute(step.tool, effect_arguments)
          rescue ToolArgumentError => error
            # Invariant 17: an invalid-argument rejection is a typed result. Nothing was
            # mutated, so it becomes evidence rather than ending the run.
            observation = tool_failure_observation(event_context, step, error)
            observations << observation
            emit(:tool_rejected, observation) { |event| yield event }
            total_bytes += observation.fetch("output").bytesize
            # Only the action and repair phases own a repair budget. Discovery and
            # read-only keep the rejection as evidence and continue with the next step.
            next unless %i[action repair].include?(phase)

            tool_failure = observation.fetch("failure")
            break
          end

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
        [Plan.deep_freeze(observations), last_check_receipt, Plan.deep_freeze(tool_failure)].freeze
      end

      # Mirrors `SessionNodes#tool_failure_update`: the two drivers must never disagree
      # about what a rejected tool looks like as evidence.
      def tool_failure_observation(event_context, step, error)
        {
          **event_context,
          "step_id" => step.id,
          "tool" => step.tool,
          "output" => <<~TEXT.chomp,
            Tool #{step.tool} was rejected: #{error.message}
            The workspace was not changed. Re-read the target with read_file and use its
            exact current bytes and digest before proposing a different action.
          TEXT
          "failure" => {
            "kind" => "tool_error",
            "tool" => step.tool,
            # P16: map the core taxonomy name back to the public
            # `Tamoz::Agent::Tool*` spelling (see `Tamoz::Core::TOOL_ERROR_CLASS_NAMES`).
            "error_class" => Tamoz::Core.serialized_tool_error_name(error.class.name),
            "reason" => error.message,
            "failure_signature" => Digest::SHA256.hexdigest(
              JSON.generate(
                "kind" => "tool_error",
                "tool" => step.tool,
                "reason" => error.message,
                "arguments_digest" => SessionRecords.digest(
                  Deliberation.canonical(step.arguments)
                )
              )
            )
          }
        }
      end

      def observation_bytes(observations)
        observations.sum { |entry| entry.fetch("output").bytesize }
      end

      # D-8 Fix A (RC-1): single resolution of an absent mutation digest, at step
      # entry. apply_patch digests come from observation of the current bytes
      # (`EffectDispatcher.observe`), create_file digests are content-derived. A
      # present digest is never touched, so the stale-digest refusal stays live.
      def resolved_effect_arguments(step)
        tool = step.tool
        arguments = step.arguments
        return arguments unless %w[apply_patch create_file].include?(tool)
        return arguments if arguments.key?("expected_sha256")

        case tool
        when "apply_patch"
          observed = EffectDispatcher.observe(toolbox.root.join(arguments.fetch("path")))
          arguments.merge("expected_sha256" => observed.fetch("state"))
        when "create_file"
          arguments.merge("expected_sha256" => Digest::SHA256.hexdigest(arguments.fetch("content")))
        end
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
