# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # The bounded, read-only continuation branch of the durable Session graph.
    # Every model and capability boundary remains owned by SessionEffects; this
    # collaborator only validates protocol data and returns checkpoint updates.
    # rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists -- graph-node methods keep each durable transition visible and ordered.
    # The graph-node methods keep each durable transition visible and ordered;
    # splitting one transition across helper objects would obscure its checkpoint
    # boundary and make the protocol harder to audit.
    class SessionAdaptive
      MAX_ITERATIONS = 3
      DECISION_KIND = %w[action final].freeze
      AUTHORITY_FIELDS = %w[
        authority_revision catalog_revision model provider profile_id
        session_id thread_id tool_catalog_digest
      ].freeze

      ADAPTIVE_SYSTEM = <<~TEXT
        You are Tamoz's bounded read-only continuation stage. Return exactly one JSON object.
        Choose either one read-only action or a final evidence-backed answer.
        Action shape: {"decision":"action","capability_id":"<available id>","arguments":{}}
        Final shape: {"decision":"final","answer":"...","evidence_refs":["observation:<id>"]}
        Never request a mutation, command, approval, profile change, authority change,
        arbitrary thread access, or a second action. Use only the capabilities listed by
        the caller and cite observation refs from the supplied evidence.
      TEXT

      Prompt = Data.define(:text, :compaction)

      def initialize(services:)
        @services = services
      end

      def decide(state, context)
        iteration = state.fetch(:adaptive_iteration)
        return terminal_update('adaptive_iteration_limit') if iteration >= MAX_ITERATIONS

        prepared = decision_prompt(state, context)
        call = @services.effects.model_call(
          context,
          stage: :adaptive_decide,
          system: ADAPTIVE_SYSTEM,
          prompt: prepared.text,
          call_index: iteration,
          iteration:,
          sub_operation: 0
        )
        model_event = lifecycle_event(
          state, context, 'model_turn', effect_state: call.status.to_s,
                                        iteration:, sub_operation: 0, effect_key: call.effect_key,
                                        attempt_number: call.attempt_number
        )
        unless call.status == :succeeded
          return @services.evidence.blocked_update(
            call,
            'adaptive decision outcome is unknown',
            operation: 'model.generate.adaptive_decide'
          ).merge(lifecycle_events: [model_event]).merge(compaction_update(prepared))
        end

        decision, digest = parse_decision(call.value, iteration)
        record = decision_record(decision, iteration, digest)
        case decision.fetch(:decision)
        when 'final'
          update = final_update(state, decision, digest, record).merge(lifecycle_events: [model_event])
          update.merge(compaction_update(prepared))
        when 'action'
          {
            adaptive_action: {
              'capability_id' => decision.fetch(:capability_id),
              'arguments' => decision.fetch(:arguments),
              'decision_digest' => digest,
              'iteration' => iteration
            },
            adaptive_decisions: [record],
            lifecycle_events: [model_event],
            next_node: 'adaptive_validate'
          }.merge(compaction_update(prepared))
        end
      rescue ProtocolError, SensitiveValueError => e
        invalid_decision_update(state, e.message).merge(
          lifecycle_events: [
            lifecycle_event(
              state, context, 'model_turn', effect_state: 'invalid',
                                            iteration: state.fetch(:adaptive_iteration), sub_operation: 0
            )
          ]
        ).merge(compaction_update(prepared))
      end

      def validate(state, context)
        action = state.fetch(:adaptive_action)
        capability_id = action.fetch('capability_id')
        arguments = action.fetch('arguments')
        iteration = action.fetch('iteration')

        return terminal_update('adaptive_authority_field') if authority_field?(arguments)

        unless @services.effects.allowed_tool_names(:discovery).include?(capability_id)
          return handoff_update(state, action, context:) if
            @services.configuration.capabilities.descriptor?(capability_id)

          return terminal_update('adaptive_capability_unavailable')
        end

        unless @services.effects.tool_safety(capability_id, arguments).to_sym == :read_only
          return handoff_update(state, action, context:)
        end

        @services.configuration.capabilities.validate(capability_id, arguments)
        signature = action_signature(capability_id, arguments)
        return terminal_update('adaptive_repeated_action') if
          state.fetch(:adaptive_seen_actions).include?(signature)

        accepted = {
          'plan_id' => "adaptive.#{iteration}",
          'plan_digest' => action.fetch('decision_digest')
        }
        step = {
          'id' => "adaptive.#{iteration}",
          'tool' => capability_id,
          'arguments' => arguments
        }
        intent = @services.effects.build_intent(
          step,
          accepted,
          arguments,
          iteration:,
          sub_operation: 1
        )
        {
          effect_intents: [intent],
          adaptive_seen_actions: [signature],
          lifecycle_events: [
            lifecycle_event(
              state, context, 'tool_started', effect_state: 'prepared',
                                              capability_id:, iteration:, sub_operation: 1
            )
          ],
          next_node: 'adaptive_dispatch'
        }
      rescue ToolError => e
        terminal_update('adaptive_invalid_action', detail: e.message)
      end

      def dispatch(state, context)
        action = state.fetch(:adaptive_action)
        intent = state.fetch(:effect_intents).reverse.find do |record|
          record.fetch('step_id') == "adaptive.#{action.fetch('iteration')}"
        end
        raise ToolError, 'adaptive effect intent is missing' unless intent

        step = {
          'id' => intent.fetch('step_id'),
          'tool' => intent.fetch('tool'),
          'arguments' => action.fetch('arguments')
        }
        outcome = @services.effects.dispatch(
          context,
          intent,
          step,
          iteration: action.fetch('iteration'),
          sub_operation: 1
        )
        if %i[unknown wait].include?(outcome.status)
          update = @services.evidence.blocked_update(
            outcome,
            'adaptive effect outcome is unknown',
            step_id: step.fetch('id'),
            operation: intent.fetch('operation')
          )
          return update.merge(
            lifecycle_events: [
              lifecycle_event(
                state, context, 'tool_result', effect_state: outcome.status.to_s,
                                               effect_key: outcome.effect_key, attempt_number: outcome.attempt_number,
                                               capability_id: step.fetch('tool'), iteration: action.fetch('iteration'),
                                               sub_operation: 1
              )
            ]
          )
        end

        return failed_update(state, context, action, intent, outcome) unless outcome.status == :succeeded

        value = outcome.value.is_a?(Hash) ? outcome.value : { 'output' => String(outcome.value) }
        output = String(value.fetch('output'))
        actual_bytes = output.bytesize
        remaining = [SessionNodes::MAX_OBSERVATION_BYTES - @services.evidence.observation_bytes(state), 0].max
        bounded_output = output.byteslice(0, remaining).to_s
        if remaining.zero? && actual_bytes.positive?
          return {
            effect_receipts: [receipt(intent, outcome)],
            terminal_reason: 'adaptive_observation_budget_exhausted',
            lifecycle_events: [
              lifecycle_event(
                state, context, 'tool_result', effect_state: 'budget_exhausted',
                                               effect_key: outcome.effect_key, attempt_number: outcome.attempt_number,
                                               capability_id: step.fetch('tool'), truncated: true,
                                               iteration: action.fetch('iteration'), sub_operation: 1
              )
            ],
            next_node: 'terminal'
          }
        end
        pending = {
          'output' => bounded_output,
          'output_bytes' => actual_bytes,
          'truncated' => value.fetch('truncated', false) || bounded_output.bytesize < actual_bytes,
          'provenance' => value.fetch('provenance', 'workspace'),
          'source_id' => value['source_id'],
          'effect_key' => outcome.effect_key,
          'attempt_number' => outcome.attempt_number,
          'reconciliation' => outcome.reconciliation,
          'tool' => step.fetch('tool'),
          'step_id' => step.fetch('id'),
          'iteration' => action.fetch('iteration'),
          'decision_digest' => action.fetch('decision_digest')
        }
        {
          adaptive_pending_observation: pending,
          effect_receipts: [receipt(intent, outcome)],
          lifecycle_events: [
            lifecycle_event(
              state, context, 'tool_result', effect_state: outcome.status.to_s,
                                             effect_key: outcome.effect_key, attempt_number: outcome.attempt_number,
                                             capability_id: step.fetch('tool'), source_id: value['source_id'],
                                             provenance: value.fetch('provenance', 'workspace'),
                                             truncated: value.fetch('truncated', false),
                                             iteration: action.fetch('iteration'), sub_operation: 1
            )
          ],
          next_node: 'adaptive_observe'
        }
      end

      def observe(state, context)
        pending = state.fetch(:adaptive_pending_observation)
        evidence_ref = "observation:#{pending.fetch('iteration')}"
        observation = SessionRecords.build(
          'observation',
          phase: 'adaptive_read_only',
          repair_attempt: 0,
          step_id: pending.fetch('step_id'),
          output: pending.fetch('output'),
          tool: pending.fetch('tool'),
          effect_key: pending.fetch('effect_key'),
          iteration: pending.fetch('iteration'),
          sub_operation: 1,
          provenance: pending.fetch('provenance'),
          source_id: pending['source_id'],
          truncated: pending.fetch('truncated'),
          output_bytes: pending.fetch('output_bytes'),
          result_class: 'succeeded',
          decision_digest: pending.fetch('decision_digest'),
          evidence_ref:
        )
        {
          adaptive_iteration: pending.fetch('iteration') + 1,
          adaptive_pending_observation: nil,
          observations: [observation],
          lifecycle_events: [
            lifecycle_event(
              state, context, 'checkpoint', effect_state: 'observed',
                                            effect_key: pending.fetch('effect_key'),
                                            capability_id: pending.fetch('tool'),
                                            source_id: pending['source_id'], provenance: pending.fetch('provenance'),
                                            truncated: pending.fetch('truncated'),
                                            iteration: pending.fetch('iteration'),
                                            sub_operation: 1
            )
          ],
          next_node: 'adaptive_decide'
        }
      end

      private

      def decision_prompt(state, durable_context)
        effects = @services.effects
        allowed = effects.allowed_tool_names(:discovery)
        descriptions = @services.configuration.toolbox.descriptions.slice(*allowed)
        descriptions = descriptions.merge(effects.mcp_planning_surface(allowed))
        observations = state.fetch(:observations).filter_map do |record|
          next unless record['phase'] == 'adaptive_read_only'

          {
            'evidence_ref' => record['evidence_ref'],
            'capability_id' => record['tool'],
            'output' => record['output'],
            'provenance' => record['provenance'],
            'truncated' => record['truncated'],
            'output_bytes' => record['output_bytes']
          }
        end
        compaction = { effects:, durable_context: }
        compacted = @services.planning_context.compact_for(
          state,
          :read_only,
          observations:,
          compaction:
        )
        Prompt.new(
          text: JSON.pretty_generate(
            'task' => state.fetch(:task),
            'iteration' => state.fetch(:adaptive_iteration),
            'max_iterations' => MAX_ITERATIONS,
            'available_capabilities' => descriptions,
            'planning_context' => compacted.context,
            'observations' => compacted.observations
          ),
          compaction: compacted.record
        )
      end

      def compaction_update(prompt)
        prompt&.compaction ? { compactions: [prompt.compaction] } : {}
      end

      def parse_decision(raw, iteration)
        document = Plan.parse_object(raw)
        unknown = document.keys - %w[decision capability_id arguments answer evidence_refs]
        raise ProtocolError, 'adaptive decision has unknown fields' unless unknown.empty?

        kind = Plan.string(document.fetch('decision'), name: 'adaptive decision')
        raise ProtocolError, 'adaptive decision must be action or final' unless DECISION_KIND.include?(kind)

        expected_keys = kind == 'action' ? %w[decision capability_id arguments] : %w[decision answer evidence_refs]
        raise ProtocolError, "adaptive #{kind} decision has contradictory fields" unless
          document.keys.sort == expected_keys.sort

        decision = if kind == 'action'
                     arguments = document.fetch('arguments')
                     raise ProtocolError, 'adaptive action arguments must be an object' unless arguments.is_a?(Hash)

                     capability_id = Plan.string(document.fetch('capability_id'), name: 'capability_id')
                     SessionRecords.reject_credential_values!(arguments)
                     { decision: kind, capability_id:, arguments: Plan.deep_freeze(arguments) }
                   else
                     answer = Plan.string(document.fetch('answer'), name: 'answer')
                     evidence_refs = Plan.strings(document.fetch('evidence_refs'), name: 'evidence_refs')
                     { decision: kind, answer:, evidence_refs: }
                   end
        [decision, SessionRecords.digest('adaptive_iteration' => iteration, **decision)]
      rescue KeyError, TypeError => e
        raise ProtocolError, "invalid adaptive decision: #{e.message}"
      end

      def decision_record(decision, iteration, digest)
        fields = {
          decision: decision.fetch(:decision),
          iteration:,
          decision_digest: digest
        }
        fields[:capability_id] = decision[:capability_id] if decision[:capability_id]
        fields[:arguments_digest] = SessionRecords.digest(decision[:arguments]) if decision[:arguments]
        fields[:answer] = decision[:answer] if decision[:answer]
        fields[:evidence_refs] = decision[:evidence_refs] if decision[:evidence_refs]
        SessionRecords.build('adaptive_decision', **fields)
      end

      def final_update(state, decision, _digest, record)
        refs = decision.fetch(:evidence_refs)
        known = state.fetch(:observations).filter_map { |observation| observation['evidence_ref'] }
        return invalid_decision_update(state, 'final evidence_refs do not cite observations') unless
          refs.any? && refs.all? { |ref| known.include?(ref) }

        {
          adaptive_decisions: [record],
          verification: SessionRecords.build(
            'verification',
            answer: decision.fetch(:answer),
            satisfied: true,
            evidence: refs,
            configured_check_passed: false,
            terminal_reason: 'adaptive_final'
          ),
          terminal_reason: 'adaptive_final',
          next_node: 'terminal'
        }
      end

      def invalid_decision_update(state, detail)
        digest = SessionRecords.digest(
          'iteration' => state.fetch(:adaptive_iteration),
          'reason' => detail.to_s.byteslice(0, 512)
        )
        {
          adaptive_decisions: [
            SessionRecords.build(
              'adaptive_decision',
              decision: 'invalid',
              iteration: state.fetch(:adaptive_iteration),
              decision_digest: digest,
              reason: detail.to_s.byteslice(0, 512)
            )
          ],
          terminal_reason: 'adaptive_invalid_decision',
          next_node: 'terminal'
        }
      end

      def handoff_update(state, action, context:)
        observation = SessionRecords.build(
          'observation',
          phase: 'adaptive_read_only',
          repair_attempt: 0,
          step_id: "adaptive.handoff.#{action.fetch('iteration')}",
          output: 'Adaptive read-only mode handed the request to the reviewed planner.',
          tool: action.fetch('capability_id'),
          result_class: 'mutation_handoff',
          decision_digest: action.fetch('decision_digest')
        )
        {
          phase: 'action', step_cursor: 0, observations: [observation],
          lifecycle_events: [
            lifecycle_event(
              state, context, 'handoff', effect_state: 'reviewed_planner',
                                         capability_id: action.fetch('capability_id'),
                                         iteration: action.fetch('iteration'), sub_operation: 0
            )
          ],
          next_node: 'deliberate'
        }
      end

      def failed_update(state, context, action, intent, outcome)
        output = 'Read-only capability failed before producing an observation.'
        observation = SessionRecords.build(
          'observation',
          phase: 'adaptive_read_only',
          repair_attempt: 0,
          step_id: intent.fetch('step_id'),
          output:,
          tool: intent.fetch('tool'),
          effect_key: outcome.effect_key,
          iteration: action.fetch('iteration'),
          sub_operation: 1,
          provenance: 'framework',
          truncated: false,
          output_bytes: output.bytesize,
          result_class: 'failed',
          decision_digest: action.fetch('decision_digest')
        )
        {
          observations: [observation],
          effect_receipts: [receipt(intent, outcome, status: 'failed')],
          lifecycle_events: [
            lifecycle_event(
              state, context, 'tool_result', effect_state: 'failed',
                                             effect_key: outcome.effect_key, attempt_number: outcome.attempt_number,
                                             capability_id: intent.fetch('tool'), iteration: action.fetch('iteration'),
                                             sub_operation: 1
            )
          ],
          terminal_reason: 'adaptive_effect_failed',
          next_node: 'terminal'
        }
      end

      def receipt(intent, outcome, status: 'succeeded')
        SessionRecords.build(
          'effect_receipt',
          effect_key: outcome.effect_key,
          logical_key: outcome.effect_key,
          attempt_identity: outcome.attempt_identity ||
            "#{outcome.effect_key}/attempt/#{outcome.attempt_number}",
          step_id: intent.fetch('step_id'),
          operation: intent.fetch('operation'),
          safety: intent.fetch('safety'),
          status:,
          attempt_number: outcome.attempt_number,
          reconciliation: outcome.reconciliation,
          iteration: intent.fetch('iteration'),
          sub_operation: intent.fetch('sub_operation')
        )
      end

      def action_signature(capability_id, arguments)
        SessionRecords.digest(
          'capability_id' => capability_id,
          'arguments' => Tamoz::Agent::Deliberation.canonical(arguments)
        )
      end

      def authority_field?(arguments)
        arguments.keys.any? { |key| AUTHORITY_FIELDS.include?(String(key)) }
      end

      def terminal_update(reason, detail: nil)
        update = { terminal_reason: reason, next_node: 'terminal' }
        update[:adaptive_terminal_detail] = detail if detail
        update
      end

      def lifecycle_event(
        state, context, event_type, effect_state:, iteration: nil, sub_operation: nil,
        effect_key: nil, attempt_number: nil, capability_id: nil, source_id: nil,
        provenance: nil, truncated: nil
      )
        fields = {
          event_type:, sequence: state.fetch(:lifecycle_events, []).length,
          request_id: context.request_id, thread_id: context.thread_id || state.dig(:session, 'session_id'),
          execution_id: context.execution_id, phase: state.fetch(:phase), effect_state:,
          delivery_state: 'pending'
        }
        {
          iteration:, sub_operation:, effect_key:, logical_key: effect_key,
          attempt_number:, capability_id:, source_id:, provenance:, truncated:
        }.each { |key, value| fields[key] = value unless value.nil? }
        SessionRecords.build('lifecycle_event', **fields)
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
  end
end
