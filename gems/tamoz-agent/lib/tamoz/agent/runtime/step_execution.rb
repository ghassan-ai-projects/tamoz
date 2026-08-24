# frozen_string_literal: true

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
        private

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
              if total_bytes + toolbox.maximum_effect_output_bytes(step.tool) > SessionNodes::MAX_OBSERVATION_BYTES
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
            if total_bytes > SessionNodes::MAX_OBSERVATION_BYTES
              raise ToolError, "tool observations exceed #{SessionNodes::MAX_OBSERVATION_BYTES} bytes"
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
          [Tamoz::Core.deep_freeze(observations), last_check_receipt, Tamoz::Core.deep_freeze(tool_failure)].freeze
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
      end
      private_constant :StepExecution
    end
  end
end
