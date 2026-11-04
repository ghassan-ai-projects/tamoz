# frozen_string_literal: true

module Tamoz
  module Agent
    class Runtime
      # The evidence one executed step leaves behind: the no-tool note, the tool's
      # output with its check summary, and the typed failure records for denials
      # and rejected tools.
      #
      # :nodoc:
      module StepObservations
        private

        def no_tool_observation(step, event_context)
          {
            **event_context,
            'step_id' => step.id,
            'tool' => nil,
            'output' => 'No tool required.'
          }
        end

        def completed_observation(step, tool_result, event_context, total_bytes)
          output = String(tool_result)
          if total_bytes + output.bytesize > SessionNodes::MAX_OBSERVATION_BYTES
            raise ToolError, "tool observations exceed #{SessionNodes::MAX_OBSERVATION_BYTES} bytes"
          end

          observation = {
            **event_context,
            'step_id' => step.id,
            'tool' => step.tool,
            'output' => output
          }
          observation['check'] = check_summary(tool_result) if tool_result.is_a?(CheckReceipt)
          observation
        end

        def check_summary(receipt)
          {
            'name' => receipt.name,
            'outcome' => receipt.outcome,
            'passed' => receipt.passed?,
            'failure_signature' => receipt.failure_signature
          }
        end

        def observation_for_denial(event_context, step_id:, tool:, arguments:, reason:)
          {
            **event_context,
            'step_id' => step_id,
            'tool' => tool,
            'output' => <<~TEXT.chomp,
              Tool #{tool} was rejected: #{reason}
              The workspace was not changed. Re-read the target with read_file and use its
              exact current bytes and digest before proposing a different action.
            TEXT
            'failure' => {
              'kind' => 'tool_error',
              'tool' => tool,
              'error_class' => 'ToolPolicyError',
              'reason' => reason,
              'failure_signature' => build_failure_signature(
                tool, reason, arguments
              )
            }
          }
        end

        # Mirrors `SessionNodes#tool_failure_update`: the two drivers must never disagree
        # about what a rejected tool looks like as evidence.
        def tool_failure_observation(event_context, step, error)
          {
            **event_context,
            'step_id' => step.id,
            'tool' => step.tool,
            'output' => <<~TEXT.chomp,
              Tool #{step.tool} was rejected: #{error.message}
              The workspace was not changed. Re-read the target with read_file and use its
              exact current bytes and digest before proposing a different action.
            TEXT
            'failure' => {
              'kind' => 'tool_error',
              'tool' => step.tool,
              # P16: map the core taxonomy name back to the public
              # `Tamoz::Agent::Tool*` spelling (see `Tamoz::Core::TOOL_ERROR_CLASS_NAMES`).
              'error_class' => Tamoz::Core.serialized_tool_error_name(error.class.name),
              'reason' => error.message,
              'failure_signature' => build_failure_signature(
                step.tool, error.message, step.arguments
              )
            }
          }
        end

        def build_failure_signature(tool, reason, arguments)
          Digest::SHA256.hexdigest(
            JSON.generate(
              'kind' => 'tool_error',
              'tool' => tool,
              'reason' => reason,
              'arguments_digest' => SessionRecords.digest(
                Deliberation.canonical(arguments)
              )
            )
          )
        end
      end
      private_constant :StepObservations
    end
  end
end
