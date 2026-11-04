# frozen_string_literal: true

require_relative 'step_gate'
require_relative 'step_observations'

module Tamoz
  module Agent
    class Runtime
      # One accepted plan executed step by step against the toolbox: observation
      # budgets, approval gating through the same engine the durable sessions use,
      # typed tool rejections captured as evidence, and effect arguments whose
      # mutation digest resolves exactly once at step entry.
      #
      # :nodoc:
      module StepExecution
        include StepGate
        include StepObservations

        private

        def execute(plan, phase:, metadata:, initial_bytes: 0, &block)
          event_context = step_context(phase, metadata)
          observations = []
          total_bytes = initial_bytes
          last_check_receipt = nil
          tool_failure = nil
          plan.steps.each_with_index do |step, step_index|
            unless step.tool
              observations << no_tool_observation(step, event_context)
              next
            end

            observation, check_receipt = execute_step(step, step_index, event_context, total_bytes, &block)
            observations << observation
            total_bytes += observation.fetch('output').bytesize
            tool_failure = repairable_failure(observation, phase)
            last_check_receipt = check_receipt || last_check_receipt
            break if tool_failure || last_check_receipt&.failed?
          end
          frozen_execution(observations, last_check_receipt, tool_failure)
        end

        def step_context(phase, metadata)
          { 'phase' => phase.to_s }.merge(metadata)
        end

        def frozen_execution(observations, last_check_receipt, tool_failure)
          [Tamoz::Core.deep_freeze(observations), last_check_receipt, Tamoz::Core.deep_freeze(tool_failure)].freeze
        end

        # Returns [observation, check_receipt]; a denial or an invalid-argument rejection
        # (Invariant 17) is a typed result with no receipt, so it becomes evidence
        # rather than ending the run.
        def execute_step(step, step_index, event_context, total_bytes, &)
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
            ensure_observation_budget(step, total_bytes)
            denial = gate_step(step, effect_arguments, event_context, &)
            return [denial, nil] if denial

            tool_result = start_tool(step, step_index, effect_arguments, event_context, &)
          rescue ToolArgumentError => e
            return [rejected_observation(event_context, step, e, &), nil]
          end

          observation = completed_observation(step, tool_result, event_context, total_bytes)
          emit(:tool_completed, observation, &)
          [observation, (tool_result if tool_result.is_a?(CheckReceipt))]
        end

        def ensure_observation_budget(step, total_bytes)
          unless total_bytes + toolbox.maximum_effect_output_bytes(step.tool) > SessionNodes::MAX_OBSERVATION_BYTES
            return
          end

          raise ToolError, "insufficient observation budget for #{step.tool}"
        end

        def start_tool(step, step_index, effect_arguments, event_context, &)
          emit(
            :tool_started,
            event_context.merge(
              'step_id' => step.id,
              'tool' => step.tool,
              'arguments' => step.arguments
            ), &
          )
          execute_tool(step.tool, effect_arguments, step.id, step_index)
        end

        def rejected_observation(event_context, step, error, &)
          observation = tool_failure_observation(event_context, step, error)
          emit(:tool_rejected, observation, &)
          observation
        end

        # Only the action and repair phases own a repair budget. Discovery and
        # read-only keep a rejection as evidence and continue with the next step.
        def repairable_failure(observation, phase)
          observation['failure'] if owns_repair_budget?(phase)
        end

        def owns_repair_budget?(phase)
          %i[action repair].include?(phase)
        end

        def observation_bytes(observations)
          observations.sum { |entry| entry.fetch('output').bytesize }
        end

        def execute_tool(tool, arguments, step_id, step_index)
          effect_key = "ephemeral:#{@correlation.fetch(:execution_id)}:#{step_index}:#{step_id}"
          @observability.around(
            'tamoz.tool.call',
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
          return arguments if arguments.key?('expected_sha256')

          case tool
          when 'apply_patch'
            observed = EffectDispatcher.observe(toolbox.root.join(arguments.fetch('path')))
            arguments.merge('expected_sha256' => observed.fetch('state'))
          when 'create_file'
            arguments.merge('expected_sha256' => Digest::SHA256.hexdigest(arguments.fetch('content')))
          end
        end
      end
      private_constant :StepExecution
    end
  end
end
