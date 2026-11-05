# frozen_string_literal: true

module Tamoz
  module Agent
    class Runtime
      # Pipeline B's single call site: the SAME engine the durable sessions use
      # decides every step. :allow proceeds; :deny and an unanswered/refused ask
      # become the structured denial result Pipeline A feeds back (the turn
      # continues); an approved ask resolves :once against the ephemeral session.
      #
      # :nodoc:
      module StepGate
        private

        def gate_step(step, effect_arguments, event_context, &)
          return nil unless @approval_engine

          decision = @approval_engine.decide(approval_request(step, effect_arguments))
          request_event = approval_request_event(step, effect_arguments, event_context, decision)
          emit(:approval_requested, request_event, &)

          case decision.verdict
          when :allow
            emit(:approval_granted, request_event.except('preview'), &)
            nil
          when :deny
            emit(:approval_denied, request_event.except('preview'), &)
            denial_observation(step, event_context, decision)
          else
            resolve_ask(request_event, decision, &)
          end
        end

        def approval_request(step, effect_arguments)
          @approval_engine.build_request(
            tool: step.tool,
            argv: RequestProjection.argv(step.tool, effect_arguments),
            targets: RequestProjection.targets(step.tool, effect_arguments),
            effect_class: gate_effect_class(step.tool),
            session_id: 'one-shot',
            workspace_root: toolbox.root.to_s
          )
        end

        def approval_request_event(step, effect_arguments, event_context, decision)
          preview = decision.verdict == :allow ? nil : toolbox.preview(step.tool, effect_arguments)
          request_event = {
            **event_context,
            'step_id' => step.id,
            'tool' => step.tool,
            'arguments' => step.arguments,
            'verdict' => decision.verdict.to_s
          }
          request_event['preview'] = preview if preview
          request_event
        end

        def resolve_ask(request_event, decision, &)
          raw = @ask&.call(
            tool: request_event.fetch('tool'),
            preview: request_event['preview'],
            decision:
          )
          answer = raw.is_a?(Symbol) ? raw : Tamoz::Approval::Answer.parse(raw.to_s)
          if answer == :approve
            @approval_engine.resolve(decision_id: decision.id, answer: :approve, scope: :once)
            emit(:approval_granted, request_event.except('preview'), &)
            return nil
          end

          @approval_engine.resolve(decision_id: decision.id, answer: :deny, scope: nil)
          emit(:approval_denied, request_event.except('preview'), &)
          observation_for_denial(
            request_event.except('preview', 'verdict'),
            step_id: request_event.fetch('step_id'),
            tool: request_event.fetch('tool'),
            arguments: request_event.fetch('arguments'),
            reason: 'denied by operator'
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
      end
      private_constant :StepGate
    end
  end
end
