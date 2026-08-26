# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"

require_relative "runtime/plan_review"
require_relative "runtime/step_execution"
require_relative "runtime/effects_journal"

module Tamoz
  module Agent
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
      PLAN_SYSTEM = Deliberation::PLAN_SYSTEM
      REVIEW_SYSTEM = Deliberation::REVIEW_SYSTEM
      VERIFY_SYSTEM = Deliberation::VERIFY_SYSTEM

      include PlanReview
      include StepExecution

      EMPTY_CATALOG_REVISION = Tamoz::Core.digest("tamoz.agent.runtime.catalog.v1\n", {}).freeze

      # Inverse of Tamoz::Core.serialized_tool_error_name: the dispatcher
      # journals a model failure as a detail hash, and the caller-facing error
      # must keep its typed identity and message bytes.
      JOURNALED_ERROR_CLASSES = {
        "Tamoz::Agent::ToolError" => Tamoz::Core::ToolError,
        "Tamoz::Agent::ToolArgumentError" => Tamoz::Core::ToolArgumentError,
        "Tamoz::Agent::ToolPolicyError" => Tamoz::Core::ToolPolicyError
      }.freeze

      # The four values EffectDispatcher reads off a graph Context; the
      # ephemeral runtime supplies its turn correlation instead.
      EffectContext = Data.define(:effects, :execution_id, :task_id, :request_id)

      attr_reader :model, :toolbox, :max_plan_attempts, :ask, :routing, :approval_engine, :effects

      def initialize(model:, toolbox:, max_plan_attempts: 3, ask: nil, routing: :legacy,
                     recorder: Tamoz::Observability::Recorder::Null::INSTANCE, approval_engine: nil,
                     effects: nil)
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
        @effects = effects || EffectsJournal.new
        @capabilities = CapabilityBinding.build(toolbox:)
      end

      def run(task)
        task = normalize_task(task)
        start_turn
        emit(:task_started, "task" => task) { |event| yield event if block_given? }
        dispatch_task(task) { |event| yield event if block_given? }
      end

      private

      def dispatch_task(task)
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

      def normalize_task(raw)
        task = String(raw).strip
        raise ArgumentError, "task must not be empty" if task.empty?

        if task.bytesize > SessionNodes::MAX_TASK_BYTES
          raise ArgumentError, "task exceeds #{SessionNodes::MAX_TASK_BYTES} bytes"
        end

        task
      end

      # One ephemeral turn: a fresh correlation identity, the clock origin for
      # duration telemetry, and a reset model-call budget.
      def start_turn
        turn_id = SecureRandom.uuid
        @correlation = {
          thread_id: "ephemeral",
          execution_id: turn_id,
          request_id: turn_id,
          task_id: turn_id
        }
        @turn_started_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        @model_call_count = 0
      end

      def run_legacy(task)
        work = if toolbox.action_capable?
                 run_action_work(task) { |event| yield event if block_given? }
               else
                 run_read_only_work(task) { |event| yield event if block_given? }
               end
        result = verify(
          task:,
          plan: work.fetch(:plan),
          review: work.fetch(:review),
          observations: work.fetch(:observations),
          verification_context: work.fetch(:verification_context)
        )
        [result, work.fetch(:verification_context)]
      end

      def run_action_work(task)
        action = run_action_mode(task) { |event| yield event if block_given? }
        {
          plan: action.fetch(:plan),
          review: action.fetch(:review),
          observations: action.fetch(:observations),
          verification_context: action_verification_context(action)
        }
      end

      def run_read_only_work(task)
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
        {plan:, review:, observations:, verification_context: {}}
      end

      def action_verification_context(action)
        {
          "configured_check_passed" => action.fetch(:check_passed),
          "terminal_reason" => action.fetch(:terminal_reason)
        }
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
        if request.direct_response? && !RequestRoute.self_contained_task?(task)
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
          routed_managed_action(task, decision) { |event| yield event }
        else
          routed_read_only_work(task, decision) { |event| yield event }
        end
      end

      def routed_managed_action(task, decision)
        accepted = routed_discovery_plan(task, decision) { |event| yield event }
        return unless accepted

        action = run_action_mode(task, discovery: accepted) { |event| yield event }
        verify(
          task:,
          plan: action.fetch(:plan),
          review: action.fetch(:review),
          observations: action.fetch(:observations),
          verification_context: action_verification_context(action)
        )
      end

      def routed_read_only_work(task, decision)
        discovery_plan, = routed_discovery_plan(task, decision) { |event| yield event }
        return unless discovery_plan

        discovery_observations = routed_discovery_observations(discovery_plan) { |event| yield event }
        plan, review = routed_read_only_plan(task, discovery_observations) do |event|
          yield event
        end
        return unless plan
        observations = routed_read_only_observations(plan, discovery_observations) do |event|
          yield event
        end
        verify(
          task:,
          plan:,
          review:,
          observations: discovery_observations + observations,
          verification_context: {}
        )
      end

      def routed_discovery_observations(discovery_plan)
        observations, = execute(
          discovery_plan,
          phase: :discovery,
          metadata: {}
        ) { |event| yield event }
        observations
      end

      def routed_read_only_observations(plan, discovery_observations)
        observations, = execute(
          plan,
          phase: :read_only,
          metadata: {"discovery_pass" => 0},
          initial_bytes: observation_bytes(discovery_observations)
        ) { |event| yield event }
        observations
      end

      def routed_discovery_plan(task, decision)
        plan = decision.plan
        issues = routed_discovery_issues(plan)
        emit_discovery_structural_review(plan, issues) { |event| yield event }
        return route_plan_fallback { |event| yield event } if issues.any?

        review = routed_discovery_semantic_review(task, decision, plan)
        if review
          emit(:plan_reviewed, review.merge("attempt" => 0, "phase" => "discovery", "layer" => "semantic")) do |event|
            yield event
          end
          return route_plan_fallback { |event| yield event } unless semantic_review_accepted?(review)
        end

        emit(:plan_accepted, "attempt" => 0, "phase" => "discovery", "source" => "route",
                             "plan" => plan.to_h) { |event| yield event }
        [plan, review && Tamoz::Core.deep_freeze(review)]
      rescue PlanRejectedError, ProtocolError
        route_plan_fallback { |event| yield event }
        nil
      end

      def emit_discovery_structural_review(plan, issues)
        emit(:plan_drafted, "attempt" => 0, "phase" => "discovery", "source" => "route",
                            "plan" => plan.to_h) { |event| yield event }
        emit(:plan_reviewed, "attempt" => 0, "phase" => "discovery", "layer" => "structural",
                             "decision" => issues.empty? ? "accept" : "revise", "issues" => issues) do |event|
          yield event
        end
      end

      def semantic_review_accepted?(review) = review.fetch("decision") == "accept"

      def routed_discovery_issues(plan)
        issues = structural_issues(
          plan,
          phase: :discovery,
          allowed_tools: toolbox.read_only_names
        ).dup
        issues << "discovery plan must gather evidence" unless plan.steps.any?(&:tool)
        issues
      end

      def routed_discovery_semantic_review(task, decision, plan)
        return unless decision.route == "managed_action"

        semantic_review(task, plan, phase: :discovery, evidence: [], planning_context: {})
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
        discovery_observations = discover_action_observations(task, discovery:) do |event|
          yield event
        end
        state = action_state(discovery_observations)
        run_action_repair_loop(task, state) { |event| yield event }
        action_result(state)
      end

      def discover_action_observations(task, discovery:)
        discovery_plan, = discovery || accepted_plan(
          task,
          phase: :discovery,
          allowed_tools: toolbox.read_only_names,
          evidence: [],
          metadata: {},
          planning_context: {}
        ) { |event| yield event }
        observations, = execute(
          discovery_plan,
          phase: :discovery,
          metadata: {}
        ) { |event| yield event }
        observations
      end

      def action_state(discovery_observations)
        {
          all_observations: discovery_observations.dup,
          prior_plans: [],
          prior_reviews: [],
          seen_actions: {},
          seen_failures: {},
          repair_attempt: 0,
          plan: nil,
          review: nil,
          check_passed: false,
          terminal_reason: "no_check"
        }
      end

      def run_action_repair_loop(task, state)
        loop do
          context = action_iteration_context(state)
          emit_repair_started(state, context) { |event| yield event }
          candidate_plan, candidate_review = draft_action_plan(task, state, context) do |event|
            yield event
          end
          break unless candidate_plan

          signature = action_signature(candidate_plan)
          if repeated_action?(state, signature)
            stop_repair(
              state,
              context:,
              reason: "repeated_action",
              detail: {"action_signature" => signature}
            ) { |event| yield event }
            break
          end
          record_action_plan(state, candidate_plan, candidate_review, signature)

          execute_action_plan(state, context) { |event| yield event }
          break unless resolve_action_outcome(state, context) { |event| yield event }
        end
      end

      def action_iteration_context(state)
        {
          phase: state.fetch(:repair_attempt).zero? ? :action : :repair,
          metadata: {"repair_attempt" => state.fetch(:repair_attempt)},
          planning_context: {
            "prior_action_plans" => state.fetch(:prior_plans).map(&:to_h),
            "prior_action_reviews" => state.fetch(:prior_reviews),
            "prior_action_signatures" => state.fetch(:seen_actions).keys.sort,
            "prior_failure_signatures" => state.fetch(:seen_failures).keys.sort
          }
        }
      end

      def emit_repair_started(state, context)
        return unless state.fetch(:repair_attempt).positive?

        emit(
          :repair_started,
          context.fetch(:metadata).merge("observations" => state.fetch(:all_observations).length)
        ) { |event| yield event }
      end

      def stop_repair(state, context:, reason:, detail: nil)
        state[:terminal_reason] = reason
        data = context.fetch(:metadata).merge("reason" => reason)
        data.merge!(detail) if detail
        emit(:repair_stopped, data) { |event| yield event }
      end

      def draft_action_plan(task, state, context)
        accepted_plan(
          task,
          phase: context.fetch(:phase),
          allowed_tools: toolbox.names,
          evidence: state.fetch(:all_observations),
          metadata: context.fetch(:metadata),
          planning_context: context.fetch(:planning_context)
        ) { |event| yield event }
      rescue PlanRejectedError
        raise if state.fetch(:repair_attempt).zero?

        stop_repair(state, context:, reason: "repair_plan_rejected") { |event| yield event }
        nil
      end

      def repeated_action?(state, signature) = state.fetch(:seen_actions).key?(signature)

      def record_action_plan(state, plan, review, signature)
        state.fetch(:seen_actions)[signature] = true
        state[:plan] = plan
        state[:review] = review
        state.fetch(:prior_plans) << plan
        state.fetch(:prior_reviews) << review
      end

      def execute_action_plan(state, context)
        observations, check_receipt, tool_failure = execute(
          state.fetch(:plan),
          phase: context.fetch(:phase),
          metadata: context.fetch(:metadata),
          initial_bytes: observation_bytes(state.fetch(:all_observations))
        ) { |event| yield event }
        state.fetch(:all_observations).concat(observations)
        state[:check_receipt] = check_receipt
        state[:tool_failure] = tool_failure
      end

      def resolve_action_outcome(state, context)
        # A repairable tool rejection short-circuits the plan and enters the same
        # bounded repair loop a failed configured check uses: one shared
        # `repair_attempt` counter, one shared failure-signature set.
        if state[:tool_failure]
          failure_signature = state.fetch(:tool_failure).fetch("failure_signature")
          repeated_reason = "repeated_tool_failure"
        elsif state[:check_receipt].nil?
          state[:terminal_reason] = "completed_without_check"
          return false
        elsif state.fetch(:check_receipt).passed?
          state[:check_passed] = true
          state[:terminal_reason] = "check_passed"
          return false
        else
          failure_signature = state.fetch(:check_receipt).failure_signature
          repeated_reason = "repeated_failure"
        end

        continue_repair?(state, failure_signature:, repeated_reason:, context:) do |event|
          yield event
        end
      end

      def continue_repair?(state, failure_signature:, repeated_reason:, context:)
        if state.fetch(:seen_failures).key?(failure_signature)
          stop_repair(
            state,
            context:,
            reason: repeated_reason,
            detail: {"failure_signature" => failure_signature}
          ) { |event| yield event }
          return false
        end
        state.fetch(:seen_failures)[failure_signature] = true

        if state.fetch(:repair_attempt) >= SessionNodes::MAX_REPAIR_ATTEMPTS
          stop_repair(state, context:, reason: "repair_attempts_exhausted") { |event| yield event }
          return false
        end
        state[:repair_attempt] += 1
        true
      end

      def action_result(state)
        {
          plan: state.fetch(:plan),
          review: state.fetch(:review),
          observations: Tamoz::Core.deep_freeze(state.fetch(:all_observations)),
          check_passed: state.fetch(:check_passed),
          terminal_reason: state.fetch(:terminal_reason)
        }.freeze
      end

      def action_signature(plan) = Deliberation.action_signature(plan)

      def verify(task:, plan:, review:, observations:, verification_context:)
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

      def model_generate(stage:, system:, prompt:)
        @model_call_count += 1
        ordinal = @model_call_count
        @observability.around(
          "tamoz.model.call",
          correlation: @correlation,
          attributes: {provider: model_identity(:provider), model: model_identity(:model)}
        ) do
          outcome = EffectDispatcher.run(
            context: effect_context,
            operation: "model.generate.#{stage}",
            safety: :idempotent,
            call_index: ordinal,
            request: {"stage" => stage.to_s, "system" => system, "prompt" => prompt},
            actor: "tamoz.agent.runtime",
            logical_identity: {
              operation: "model.generate.#{stage}",
              capability_id: "model:#{stage}",
              arguments: {"stage" => stage.to_s, "system" => system, "prompt" => prompt},
              authority_revision: toolbox.catalog_digest,
              catalog_revision: EMPTY_CATALOG_REVISION,
              iteration: ordinal,
              sub_operation: 0
            }
          ) { model.generate(stage:, system:, prompt:) }
          case outcome.status
          when :succeeded then outcome.value
          when :failed then raise journaled_model_failure(outcome)
          else raise ProtocolError, "model receipt #{outcome.status}"
          end
        end
      end

      def journaled_model_failure(outcome)
        detail = outcome.error || {}
        klass = JOURNALED_ERROR_CLASSES.fetch(String(detail["class"]), ProtocolError)
        klass.new(String(detail["message"]))
      end

      def effect_context
        EffectContext.new(
          effects: @effects,
          execution_id: @correlation.fetch(:execution_id),
          task_id: @correlation.fetch(:task_id),
          request_id: @correlation.fetch(:request_id)
        )
      end

      def model_identity(method)
        value = model.respond_to?(method) ? model.public_send(method) : model.class.name
        value.to_s.gsub(/[^a-zA-Z0-9_.:-]/, "_")[0, 128]
      end

      def emit(type, data)
        yield Event.new(type:, data: Tamoz::Core.deep_freeze(data))
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
