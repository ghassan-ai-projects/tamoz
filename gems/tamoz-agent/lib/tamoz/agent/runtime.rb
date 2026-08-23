# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"

module Tamoz
  module Agent
    Event = Data.define(:type, :data)
    Result = Data.define(:answer, :satisfied, :evidence, :plan, :review, :observations) do
      def responded?
        plan.nil? && review.nil? && observations.empty? && !satisfied
      end

      def outcome
        return "responded" if responded?
        return "completed" if satisfied

        "incomplete"
      end

      def exit_status
        %w[responded completed].include?(outcome) ? 0 : 2
      end
    end

    class Runtime
      MAX_TASK_BYTES = 16 * 1024
      MAX_OBSERVATION_BYTES = 160 * 1024
      MAX_REPAIR_ATTEMPTS = 2

      PLAN_SYSTEM = Deliberation::PLAN_SYSTEM
      REVIEW_SYSTEM = Deliberation::REVIEW_SYSTEM
      VERIFY_SYSTEM = Deliberation::VERIFY_SYSTEM

      attr_reader :model, :toolbox, :max_plan_attempts, :ask, :routing, :approval_engine

      def initialize(model:, toolbox:, max_plan_attempts: 3, ask: nil, routing: :legacy,
                     recorder: Tamoz::Observability::Recorder::Null::INSTANCE, approval_engine: nil)
        raise ArgumentError, "model must respond to generate" unless model.respond_to?(:generate)
        unless max_plan_attempts.is_a?(Integer) && max_plan_attempts.between?(1, 10)
          raise ArgumentError, "max_plan_attempts must be between 1 and 10"
        end
        raise ArgumentError, "routing must be :legacy, :shadow, or :experimental" unless
          %i[legacy shadow experimental].include?(routing)

        @model = model
        @toolbox = toolbox
        @max_plan_attempts = max_plan_attempts
        @ask = ask
        @approval_engine = approval_engine
        @routing = routing
        @observability = Tamoz::Observability::Producer.new(recorder:)
        @correlation = nil
        @model_call_count = 0
        @capabilities = CapabilityBinding.build(toolbox:)
      end

      def run(task)
        task = String(task).strip
        raise ArgumentError, "task must not be empty" if task.empty?
        raise ArgumentError, "task exceeds #{MAX_TASK_BYTES} bytes" if task.bytesize > MAX_TASK_BYTES

        turn_id = SecureRandom.uuid
        @correlation = {
          thread_id: "ephemeral",
          execution_id: turn_id,
          request_id: turn_id,
          task_id: turn_id
        }
        @turn_started_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        @model_call_count = 0
        emit(:task_started, "task" => task) { |event| yield event if block_given? }
        if routing == :shadow
          return run_shadow(task) { |event| yield event if block_given? }
        end
        if routing == :experimental
          routed = run_routed(task) { |event| yield event if block_given? }
          return finish(routed) { |event| yield event if block_given? } if routed
        end

        result, verification_context = run_legacy(task) { |event| yield event if block_given? }
        finish(result, verification_context:) do |event|
          yield event if block_given?
        end
      end

      private

      def run_legacy(task)
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
        [verify(task, plan, review, observations, verification_context:), verification_context]
      end

      def finish(result, verification_context: {})
        result = enforce_configured_check(result, verification_context)
        emit(:completed, result_to_h(result).merge("duration_ms" => turn_duration_ms)) { |event| yield event }
        result
      end

      def run_shadow(task)
        decision = routing_decision(task) { |event| yield event }
        result, verification_context = run_legacy(task) { |event| yield event }
        emit(:route_shadow, shadow_data(decision, result)) { |event| yield event }
        finish(result, verification_context:) do |event|
          yield event if block_given?
        end
      end

      def shadow_data(decision, result)
        route = decision ? decision.route : "legacy_fallback"
        {
          "route" => route,
          "legacy_outcome" => result.outcome,
          "total_model_call_count" => @model_call_count,
          "disagreement_reason" => shadow_disagreement(decision, result)
        }.compact
      end

      def shadow_disagreement(decision, result)
        return "route_protocol_fallback" unless decision
        return unless decision.direct_response? && result.outcome != "responded"

        "direct_response_vs_#{result.outcome}"
      end

      def turn_duration_ms
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - @turn_started_ms
        [elapsed, 0].max
      end

      def run_routed(task)
        decision = routing_decision(task) { |event| yield event }
        return unless decision

        emit(:route_selected, route_data(decision)) { |event| yield event }
        return direct_result(decision) if decision.direct_response?

        routed_work(task, decision) { |event| yield event }
      end

      def routing_decision(task)
        raw = model_generate(
          stage: :route,
          system: Deliberation::ROUTING_SYSTEM,
          prompt: Deliberation.routing_prompt(task, toolbox:)
        )
        request = RequestRoute.parse(raw)
        unless !request.direct_response? || RequestRoute.self_contained_task?(task)
          emit(:route_fallback, "reason" => "unsafe_direct_route") { |event| yield event }
          return nil
        end
        RoutingDecision.from(request, toolbox:)
      rescue ProtocolError
        emit(:route_fallback, "reason" => "invalid_route") { |event| yield event }
        nil
      end

      def route_data(decision)
        {
          "route" => decision.route,
          "reason_class" => decision.reason_class,
          "fallback" => decision.fallback
        }.compact
      end

      def direct_result(decision)
        Result.new(
          answer: decision.answer,
          satisfied: false,
          evidence: [].freeze,
          plan: nil,
          review: nil,
          observations: [].freeze
        )
      end

      def routed_work(task, decision)
        if decision.route == "managed_action"
          accepted = routed_discovery_plan(task, decision) { |event| yield event }
          return unless accepted

          action = run_action_mode(task, discovery: accepted) { |event| yield event }
          return verify(
            task,
            action.fetch(:plan),
            action.fetch(:review),
            action.fetch(:observations),
            verification_context: {
              "configured_check_passed" => action.fetch(:check_passed),
              "terminal_reason" => action.fetch(:terminal_reason)
            }
          )
        end

        discovery_plan, = routed_discovery_plan(task, decision) { |event| yield event }
        return unless discovery_plan

        discovery_observations, = execute(
          discovery_plan,
          phase: :discovery,
          metadata: {}
        ) { |event| yield event }
        plan, review = routed_read_only_plan(task, discovery_observations) do |event|
          yield event
        end
        return unless plan
        observations, = execute(
          plan,
          phase: :read_only,
          metadata: {"discovery_pass" => 0},
          initial_bytes: observation_bytes(discovery_observations)
        ) do |event|
          yield event
        end
        verify(
          task,
          plan,
          review,
          discovery_observations + observations,
          verification_context: {}
        )
      end

      def routed_discovery_plan(task, decision)
        plan = decision.plan
        issues = structural_issues(
          plan,
          phase: :discovery,
          allowed_tools: toolbox.read_only_names
        )
        issues = issues.dup
        issues << "discovery plan must gather evidence" unless plan.steps.any?(&:tool)
        emit(:plan_drafted, "attempt" => 0, "phase" => "discovery", "source" => "route",
                            "plan" => plan.to_h) { |event| yield event }
        emit(:plan_reviewed, "attempt" => 0, "phase" => "discovery", "layer" => "structural",
                             "decision" => issues.empty? ? "accept" : "revise", "issues" => issues) do |event|
          yield event
        end
        return route_plan_fallback { |event| yield event } if issues.any?

        review = if decision.route == "managed_action"
                   semantic_review(task, plan, phase: :discovery, evidence: [], planning_context: {})
                 end
        if review
          emit(:plan_reviewed, review.merge("attempt" => 0, "phase" => "discovery", "layer" => "semantic")) do |event|
            yield event
          end
          return route_plan_fallback { |event| yield event } unless review.fetch("decision") == "accept"
        end

        emit(:plan_accepted, "attempt" => 0, "phase" => "discovery", "source" => "route",
                             "plan" => plan.to_h) { |event| yield event }
        [plan, review && Plan.deep_freeze(review)]
      rescue PlanRejectedError, ProtocolError
        route_plan_fallback { |event| yield event }
        nil
      end

      def routed_read_only_plan(task, discovery_observations)
        accepted_plan(
          task,
          phase: :read_only,
          allowed_tools: toolbox.read_only_names,
          evidence: discovery_observations,
          metadata: {"discovery_pass" => 0},
          planning_context: {}
        ) { |event| yield event }
      rescue PlanRejectedError, ProtocolError
        route_plan_fallback("route_read_only_plan_rejected") { |event| yield event }
        nil
      end

      def route_plan_fallback(reason = "route_plan_rejected")
        emit(:route_fallback, "reason" => reason) { |event| yield event }
        nil
      end

      def run_action_mode(task, discovery: nil)
        discovery_plan, _discovery_review = discovery || accepted_plan(
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
          raw = model_generate(
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

      def model_generate(stage:, system:, prompt:)
        @model_call_count += 1
        @observability.around(
          "tamoz.model.call",
          correlation: @correlation,
          attributes: {provider: model_identity(:provider), model: model_identity(:model)}
        ) { model.generate(stage:, system:, prompt:) }
      end

      def model_identity(method)
        value = model.respond_to?(method) ? model.public_send(method) : model.class.name
        value.to_s.gsub(/[^a-zA-Z0-9_.:-]/, "_")[0, 128]
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

      def execute(plan, phase:, metadata:, initial_bytes: 0)
        event_context = {"phase" => phase.to_s}.merge(metadata)
        observations = []
        total_bytes = initial_bytes
        last_check_receipt = nil
        tool_failure = nil
        plan.steps.each_with_index do |step, step_index|
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
            if total_bytes + toolbox.maximum_effect_output_bytes(step.tool) > MAX_OBSERVATION_BYTES
              raise ToolError, "insufficient observation budget for #{step.tool}"
            end
            denial = gate_step(step, effect_arguments, event_context) { |event| yield event }
            if denial
              observations << denial
              total_bytes += denial.fetch("output").bytesize
              next unless %i[action repair].include?(phase)

              tool_failure = denial.fetch("failure")
              break
            end

            emit(
              :tool_started,
              event_context.merge(
                "step_id" => step.id,
                "tool" => step.tool,
                "arguments" => step.arguments
              )
            ) { |event| yield event }
            tool_result = execute_tool(step.tool, effect_arguments, step.id, step_index)
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

      # Pipeline B's single call site: the SAME engine the durable sessions use
      # decides every step. :allow proceeds; :deny and an unanswered/refused ask
      # become the structured denial result Pipeline A feeds back (the turn
      # continues); an approved ask resolves :once against the ephemeral session.
      def gate_step(step, effect_arguments, event_context)
        return nil unless @approval_engine

        request = @approval_engine.build_request(
          tool: step.tool,
          argv: RequestProjection.argv(step.tool, effect_arguments),
          targets: RequestProjection.targets(step.tool, effect_arguments),
          effect_class: gate_effect_class(step.tool),
          session_id: "one-shot",
          workspace_root: toolbox.root.to_s
        )
        decision = @approval_engine.decide(request)
        preview = decision.verdict == :allow ? nil : toolbox.preview(step.tool, effect_arguments)
        request_event = {
          **event_context,
          "step_id" => step.id,
          "tool" => step.tool,
          "arguments" => step.arguments,
          "verdict" => decision.verdict.to_s
        }
        request_event["preview"] = preview if preview
        emit(:approval_requested, request_event) { |event| yield event }

        case decision.verdict
        when :allow
          emit(:approval_granted, request_event.except("preview")) { |event| yield event }
          nil
        when :deny
          emit(:approval_denied, request_event.except("preview")) { |event| yield event }
          denial_observation(step, event_context, decision)
        else
          resolve_ask(request_event, decision) { |event| yield event }
        end
      end

      def resolve_ask(request_event, decision)
        raw = @ask&.call(
          tool: request_event.fetch("tool"),
          preview: request_event["preview"],
          decision:
        )
        answer = raw.is_a?(Symbol) ? raw : Tamoz::Approval::Answer.parse(raw.to_s)
        if answer == :approve
          @approval_engine.resolve(decision_id: decision.id, answer: :approve, scope: :once)
          emit(:approval_granted, request_event.except("preview")) { |event| yield event }
          return nil
        end

        @approval_engine.resolve(decision_id: decision.id, answer: :deny, scope: nil)
        emit(:approval_denied, request_event.except("preview")) { |event| yield event }
        observation_for_denial(
          request_event.except("preview", "verdict"),
          step_id: request_event.fetch("step_id"),
          tool: request_event.fetch("tool"),
          arguments: request_event.fetch("arguments"),
          reason: "denied by operator"
        )
      end

      # Mirrors `SessionSteps#denied_update`: same failure record shape, same
      # "denied: <reason>, rule <rule_id>" phrasing, ToolPolicyError class —
      # the two pipelines must never disagree about what a denial looks like.
      def denial_observation(step, event_context, decision)
        observation_for_denial(
          event_context,
          step_id: step.id,
          tool: step.tool,
          arguments: step.arguments,
          reason: "denied: #{decision.reason}, rule #{decision.rule_id}"
        )
      end

      # The capability binding owns classification; a tool the host cannot
      # route fails closed to :bounded like `CapabilityBinding#closed_effect_class`.
      def gate_effect_class(tool)
        @capabilities.effect_class(tool)
      rescue ToolError
        :bounded
      end

      def observation_for_denial(event_context, step_id:, tool:, arguments:, reason:)
        {
          **event_context,
          "step_id" => step_id,
          "tool" => tool,
          "output" => <<~TEXT.chomp,
            Tool #{tool} was rejected: #{reason}
            The workspace was not changed. Re-read the target with read_file and use its
            exact current bytes and digest before proposing a different action.
          TEXT
          "failure" => {
            "kind" => "tool_error",
            "tool" => tool,
            "error_class" => "ToolPolicyError",
            "reason" => reason,
            "failure_signature" => Digest::SHA256.hexdigest(
              JSON.generate(
                "kind" => "tool_error",
                "tool" => tool,
                "reason" => reason,
                "arguments_digest" => SessionRecords.digest(
                  Deliberation.canonical(arguments)
                )
              )
            )
          }
        }
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

      def execute_tool(tool, arguments, step_id, step_index)
        effect_key = "ephemeral:#{@correlation.fetch(:execution_id)}:#{step_index}:#{step_id}"
        @observability.around(
          "tamoz.tool.call",
          correlation: @correlation.merge(effect_key:),
          attributes: {
            tool:,
            argument_digest: Tamoz::Core.digest("tamoz.agent.tool_arguments.v1\n", arguments)
          }
        ) { toolbox.execute(tool, arguments) }
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
        raw = model_generate(
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
        return result if result.responded?
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

      def action_signature(plan) = Deliberation.action_signature(plan)

      # The engine is the only classification owner; the one-shot runtime asks
      # its operator exactly when the active policy would not auto-allow.
      def policy_gated?(tool)
        request = @approval_engine.build_request(
          tool: tool, argv: [], targets: [],
          effect_class: :bounded, session_id: 'one-shot'
        )
        @approval_engine.simulate(request).verdict != :allow
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
          "outcome" => result.outcome,
          "evidence" => result.evidence
        }
      end
    end
  end
end
