# frozen_string_literal: true

require 'digest'

module Tamoz
  module Agent
    # Owns the durable v2 intake route. The route decision is an ordinary journaled
    # model effect followed by a checkpointed route record, so a resumed thread never
    # asks the model to choose a different graph path.
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- the route owns the ordered intake/review protocol and its durable records.
    class SessionRouting
      def initialize(services:)
        @services = services
      end

      def route(state, context)
        planning_context = bounded_planning_context(state, context)
        call = @services.effects.model_call(
          context,
          stage: :route,
          system: Deliberation::ROUTING_SYSTEM,
          prompt: Deliberation.routing_prompt(
            state.fetch(:task),
            toolbox: routing_surface,
            planning_context:,
            capability_descriptions: routing_capability_descriptions
          ),
          call_index: 0
        )
        return blocked(call) unless call.status == :succeeded

        request = RequestRoute.parse(call.value)
        decision = RoutingDecision.from(request, toolbox: @services.configuration.toolbox)
        route_decision(state, context, call, decision)
      rescue ProtocolError => e
        fallback(raw_digest(call&.value), 'route_protocol_error', e.message)
      end

      private

      def route_decision(state, context, call, decision)
        if decision.direct_response?
          return fallback(route_digest(decision), 'unsafe_direct_response') unless
            RequestRoute.self_contained_task?(state.fetch(:task))

          return direct_response(state, call, decision)
        end

        plan_data, records = discovery_plan(decision)
        return fallback_with_records(decision, records, 'discovery_plan_rejected') unless plan_data

        if decision.route == 'managed_action'
          review = discovery_semantic_review(state, context, plan_data)
          records << review[:record]
          return fallback_with_records(decision, records, 'discovery_review_rejected') unless
            review[:value].fetch('decision') == 'accept'
        end

        acceptance = SessionPlanOutcomes::Acceptance.new(
          plan_data.plan,
          plan_data.plan_id,
          plan_data.plan_digest,
          plan_data.plan_hash,
          :discovery,
          records.select { |record| record.fetch('record') == 'plan' },
          records.select { |record| record.fetch('record') == 'review' },
          state.fetch(:provider_ambiguity) + (call.attempt_number > 1 ? 1 : 0)
        )
        @services.plan_outcomes.accept_plan(state, acceptance:).merge(
          phase: 'discovery',
          route: route_record(decision, route_digest(decision), plan_digest: plan_data.plan_digest)
        )
      end

      def discovery_plan(decision)
        plan = decision.plan
        plan_hash = Deliberation.canonical(plan.to_h)
        plan_digest = SessionRecords.digest(plan_hash)
        plan_id = 'discovery.route'
        plan_record = SessionRecords.build(
          'plan',
          plan_id:,
          phase: 'discovery',
          attempt: 1,
          plan: plan_hash,
          plan_digest:
        )
        issues = Deliberation.structural_issues(
          plan,
          phase: :discovery,
          allowed_tools: discovery_capability_names,
          toolbox: @services.configuration.toolbox,
          capabilities: @services.configuration.capabilities
        )
        review_record = SessionRecords.build(
          'review',
          review_id: "#{plan_id}.structural",
          plan_id:,
          plan_digest:,
          layer: 'structural',
          decision: issues.empty? ? 'accept' : 'revise',
          issues:,
          rationale: 'deterministic structural review'
        )
        records = [plan_record, review_record]
        return [nil, records] unless issues.empty?

        [
          SessionPlanAttempt::PlanData.new(
            plan:,
            plan_hash:,
            plan_digest:,
            plan_id:
          ),
          records
        ]
      rescue SensitiveValueError => e
        records = [
          SessionRecords.build(
            'review',
            review_id: 'discovery.route.credentials',
            plan_id: 'discovery.route',
            plan_digest: plan_digest || raw_digest(plan),
            layer: 'protocol',
            decision: 'revise',
            issues: [e.message],
            rationale: 'the discovery plan carries a credential-shaped value'
          )
        ]
        [nil, records]
      end

      def discovery_semantic_review(state, context, plan_data)
        call = @services.effects.model_call(
          context,
          stage: :route_review,
          system: Deliberation::REVIEW_SYSTEM,
          prompt: Deliberation.review_prompt(
            state.fetch(:task),
            plan_data.plan,
            phase: :discovery,
            evidence: [],
            planning_context: bounded_planning_context(state, context),
            tool_descriptions: routing_capability_descriptions.slice(*discovery_capability_names)
          ),
          call_index: 1
        )
        unless call.status == :succeeded
          return { value: { 'decision' => 'revise', 'issues' => ['route review outcome is unknown'] },
                   record: review_record(plan_data, 'revise', ['route review outcome is unknown'],
                                         'durable route review did not complete') }
        end

        value = Deliberation.parse_review(call.value)
        {
          value:,
          record: review_record(
            plan_data,
            value.fetch('decision'),
            value.fetch('issues'),
            value.fetch('rationale'),
            layer: 'semantic'
          )
        }
      rescue ProtocolError => e
        {
          value: { 'decision' => 'revise', 'issues' => [e.message] },
          record: review_record(plan_data, 'revise', [e.message], 'route review was invalid')
        }
      end

      def bounded_planning_context(state, context)
        conversation = @services.planning_context.conversation_transcript(context)
        @services.planning_context.compact_for(state, :discovery, conversation:).context
      end

      def discovery_capability_names
        @services.configuration.capabilities.names(:discovery)
      end

      def routing_capability_descriptions
        capabilities = @services.configuration.capabilities
        capabilities.descriptions.merge(
          capabilities.remote_planning_surface(capabilities.names(:action))
        )
      end

      def routing_surface
        capabilities = @services.configuration.capabilities
        Data.define(:names, :read_only_names, :descriptions).new(
          names: capabilities.names(:action),
          read_only_names: discovery_capability_names,
          descriptions: routing_capability_descriptions
        )
      end

      def review_record(plan_data, decision, issues, rationale, layer: 'semantic')
        SessionRecords.build(
          'review',
          review_id: "#{plan_data.plan_id}.#{layer}",
          plan_id: plan_data.plan_id,
          plan_digest: plan_data.plan_digest,
          layer:,
          decision:,
          issues:,
          rationale:
        )
      end

      def direct_response(state, call, decision)
        {
          route: route_record(decision, route_digest(decision)),
          verification: SessionRecords.build(
            'verification',
            answer: decision.answer,
            satisfied: false,
            evidence: [],
            configured_check_passed: false,
            terminal_reason: 'direct_response'
          ),
          provider_ambiguity: state.fetch(:provider_ambiguity) + (call.attempt_number > 1 ? 1 : 0),
          phase: 'terminal',
          next_node: 'terminal',
          terminal_reason: 'direct_response'
        }
      end

      def fallback(digest, reason, detail)
        fallback_with_records(
          nil,
          [],
          reason,
          route_digest: digest,
          detail:
        )
      end

      def fallback_with_records(decision, records, reason, route_digest: nil, detail: nil)
        decision ||= RoutingDecision.new(
          route: 'legacy_fallback',
          answer: nil,
          reason_class: 'ambiguous_context',
          plan: nil,
          fallback: reason
        )
        update = {
          route: route_record(
            decision,
            route_digest || route_digest(decision),
            fallback: reason
          ),
          next_node: 'deliberate'
        }
        update[:plan_versions] = records.select { |record| record.fetch('record') == 'plan' }
        update[:plan_reviews] = records.select { |record| record.fetch('record') == 'review' }
        update[:observations] = [route_fallback_observation(reason, detail)] if detail
        update
      end

      def route_fallback_observation(reason, detail)
        SessionRecords.build(
          'observation',
          phase: 'discovery',
          repair_attempt: 0,
          step_id: 'route',
          output: "Routing fell back to the durable planner: #{reason}. #{detail}"
        )
      end

      def blocked(call)
        @services.evidence.blocked_update(call, 'route model call outcome is unknown',
                                          operation: 'model.generate.route')
      end

      def route_record(decision, digest, plan_digest: nil, fallback: nil)
        fields = {
          route: decision.route,
          reason_class: decision.reason_class,
          route_digest: digest
        }
        fields[:plan_digest] = plan_digest if plan_digest
        fallback ||= decision.fallback
        fields[:fallback] = fallback if fallback
        SessionRecords.build('route', **fields)
      end

      def route_digest(decision)
        SessionRecords.digest(
          'route' => decision.route,
          'reason_class' => decision.reason_class,
          'answer' => decision.answer,
          'discovery_plan' => decision.plan&.to_h
        )
      end

      def raw_digest(value)
        Digest::SHA256.hexdigest(String(value))
      end
      # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
    end
  end
end
