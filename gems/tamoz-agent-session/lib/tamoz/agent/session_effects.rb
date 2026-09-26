# frozen_string_literal: true

require 'digest'
require 'tamoz/agent/model_call_projection'

module Tamoz
  module Agent
    # Routes model and tool calls through the durable effect journal.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy
    # :reek:LongParameterList :reek:MissingSafeMethod :reek:NilCheck :reek:TooManyMethods
    # :reek:TooManyStatements :reek:UtilityFunction
    # Effect requests mirror the journal contract; refusal ordering stays explicit.
    # rubocop:disable Metrics/ClassLength, Metrics/ParameterLists
    class SessionEffects
      def initialize(configuration:)
        @configuration = configuration
      end

      def model_call(context, stage:, system:, prompt:, call_index:, iteration: call_index, sub_operation: 0)
        request = model_request(system:, prompt:)
        configuration_digest = model_configuration_digest
        outcome = EffectDispatcher.run(
          context:,
          operation: "model.generate.#{stage}",
          safety: model_safety,
          call_index:,
          request: request.merge(
            'stage' => stage.to_s,
            'provider_configuration_digest' => configuration_digest
          ),
          actor: 'tamoz.agent.session',
          logical_identity: logical_identity(
            context:, operation: "model.generate.#{stage}", capability_id: "model:#{stage}",
            arguments: request.merge(
              'stage' => stage.to_s,
              'provider_configuration_digest' => configuration_digest
            ),
            iteration:, sub_operation:
          )
        ) do
          response = @configuration.model.generate(stage:, system:, prompt:)
          if response.respond_to?(:content)
            ModelCallProjection.from_response(
              response,
              request_digest: request['request_digest'],
              settings_digest: model_settings_digest,
              provider_configuration_digest: configuration_digest
            )
          else
            response
          end
        end
        unwrap_model(outcome, request:, configuration_digest:)
      end

      # One tool-calling conversation turn. A model call changes nothing outside,
      # so an unanswered one is safely retried (:idempotent).
      def converse(context, stage:, messages:, tools:, iteration:, tool_choice: 'auto', attempt: 0)
        model = conversation_model
        request = conversation_request(model, stage, messages, tools, tool_choice)
        operation = "model.converse.#{stage}"
        outcome = EffectDispatcher.run(
          context:, operation:, safety: :idempotent, call_index: iteration, request:, actor: 'tamoz.agent.session',
          logical_identity: logical_identity(context:, operation:, capability_id: "model:#{stage}", arguments: request,
                                             iteration:, sub_operation: attempt)
        ) do
          response = until_cancelled(context) { model.converse(stage:, messages:, tools:, tool_choice:) }
          ConversationProjection.from_response(response, request_digest: request.fetch('request_digest'))
        end
        outcome.status == :succeeded ? outcome.with(value: ConversationProjection.validate!(outcome.value)) : outcome
      end

      # A stop from the user abandons the call in flight and records it as a failed attempt.
      def until_cancelled(context, &)
        token = Tamoz::Cancellation::Stops.token(context.thread_id)
        token ? Tamoz::Cancellation.race(token, &) : yield
      rescue Tamoz::CancelledError
        raise ToolError, 'cancelled by the user'
      end

      def conversation_model
        model = @configuration.model
        return model if model.respond_to?(:converse)

        raise ConfigurationError, 'the work route needs a model that supports tool calls'
      end

      def unwrap_model(outcome, request:, configuration_digest:)
        return outcome unless outcome.status == :succeeded

        value = outcome.value
        text = if value.is_a?(Hash) && value.key?('content')
                 ModelCallProjection.validate!(
                   value,
                   request_digest: request['request_digest'],
                   settings_digest: model_settings_digest,
                   provider_configuration_digest: configuration_digest
                 ).fetch('content')
               elsif value.is_a?(Hash)
                 value.fetch('output')
               else
                 String(value)
               end
        outcome.with(value: text)
      end

      def dispatch(context, intent, step, iteration: 0, sub_operation: 0)
        tool = intent.fetch('tool')
        arguments = resolved_execution_arguments(intent, step)
        safety = intent.fetch('safety').to_sym
        options = dispatch_options(context, intent, tool, arguments, safety).merge(
          logical_identity: logical_identity(
            context:, operation: intent.fetch('operation'), capability_id: tool,
            arguments:, iteration:, sub_operation:
          )
        )
        EffectDispatcher.run(**options) { execute_dispatch(context, intent, tool, arguments) }
      end

      def verify_intent_before_state!(intent)
        return unless intent.key?('before_state')

        observed = EffectDispatcher.observe(
          @configuration.toolbox.root.join(intent.fetch('path'))
        )
        return if observed.fetch('state') == intent.fetch('before_state')

        raise ToolPolicyError,
              'workspace no longer matches the approved before state for ' \
              "#{intent.fetch('path')}"
      end

      def reconciled_receipt(intent)
        case intent.fetch('tool')
        when 'apply_patch'
          <<~TEXT.chomp
            Applied #{intent.fetch('path')}
            before_sha256: #{intent.fetch('before_state')}
            after_sha256: #{intent.fetch('after_digest')}
            reconciled: after state proven on disk
          TEXT
        else
          <<~TEXT.chomp
            Created #{intent.fetch('path')}
            mode: #{format('%04o', intent.fetch('after_mode'))}
            sha256: #{intent.fetch('after_digest')}
            reconciled: after state proven on disk
          TEXT
        end
      end

      private

      def dispatch_options(context, intent, tool, arguments, safety)
        {
          context:,
          operation: intent.fetch('operation'),
          safety:,
          call_index: 0,
          request: dispatch_request(tool, arguments),
          actor: 'tamoz.agent.session',
          after_start: -> { after_effect_started(intent.fetch('operation')) },
          reconcile: reconciler_for(intent, safety)
        }
      end

      def logical_identity(context:, operation:, capability_id:, arguments:, iteration:, sub_operation:)
        {
          request_id: context.request_id,
          execution_id: context.execution_id,
          operation:,
          capability_id:,
          arguments: Tamoz::Agent::Deliberation.canonical(arguments),
          authority_revision: authority_revision,
          catalog_revision: catalog_revision,
          iteration: Integer(iteration),
          sub_operation: Integer(sub_operation)
        }
      end

      def authority_revision
        @configuration.profile&.canonical_digest || @configuration.toolbox.catalog_digest
      end

      def catalog_revision
        catalogs = @configuration.mcp&.mcp_catalogs || {}
        SessionRecords.digest(Tamoz::Agent::Deliberation.canonical(catalogs))
      end

      # Plan digests remain provenance on plan and intent records. They are not
      # part of the tool request semantics, so a repair re-plan can replay the
      # same logical effect instead of colliding with its recorded receipt.
      def dispatch_request(tool, arguments)
        {
          'tool' => tool,
          'arguments' => Tamoz::Agent::Deliberation.canonical(arguments)
        }
      end

      def reconciler_for(intent, safety)
        return unless safety == :reconcilable

        lambda do
          EffectDispatcher.reconcile_filesystem(
            toolbox: @configuration.toolbox,
            intent:,
            receipt: { 'output' => reconciled_receipt(intent) }
          )
        end
      end

      def execute_dispatch(context, intent, tool, arguments)
        verify_intent_before_state!(intent)
        result = @configuration.capabilities.execute(context, tool, arguments)
        result_payload(result)
      end

      # Sole counterparty: the autonomy scorecard's kill-after-effect-started
      # crash injector; production models deliberately do not implement the hook.
      def after_effect_started(operation)
        model = @configuration.model
        model.after_effect_started(operation:) if model.respond_to?(:after_effect_started)
      end

      def model_safety
        return @configuration.model.safety if @configuration.model.respond_to?(:safety)

        @configuration.model_call_safety
      end

      def model_configuration_digest
        return unless @configuration.model.respond_to?(:provider_configuration_digest)

        @configuration.model.provider_configuration_digest
      end

      def model_settings_digest
        return unless @configuration.model.respond_to?(:settings_digest)

        @configuration.model.settings_digest
      end

      def conversation_request(model, stage, messages, tools, tool_choice)
        bytes = model.build_conversation(messages:, tools:, tool_choice:)
        {
          'stage' => stage.to_s,
          'request_digest' => model.request_digest(bytes),
          'message_count' => messages.length,
          'provider_configuration_digest' => model_configuration_digest
        }.compact
      end

      def model_request(system:, prompt:)
        return { 'system' => system, 'prompt' => prompt } unless @configuration.model.respond_to?(:build_request)

        bytes = @configuration.model.build_request(system:, prompt:)
        {
          'system' => system,
          'prompt' => prompt,
          'request_digest' => @configuration.model.request_digest(bytes)
        }
      end

      def result_payload(result)
        return check_payload(result) if result.is_a?(Tamoz::Tools::CheckReceipt)
        return mcp_payload(result) if mcp_outcome?(result)

        { 'output' => String(result) }
      end

      def mcp_outcome?(result)
        result.respond_to?(:status) && result.respond_to?(:observation) &&
          result.respond_to?(:interrupt) && result.respond_to?(:denial)
      end

      def mcp_payload(result)
        case result.status
        when :succeeded
          observation = result.observation
          output = sanitize_remote_text(observation.text.to_s)
          {
            'output' => output,
            'source_id' => observation.server_id.to_s,
            'provenance' => 'remote_untrusted',
            'truncated' => observation.truncated == true,
            'output_bytes' => output.bytesize
          }
        when :denied
          raise ToolError, "MCP capability did not complete: #{safe_mcp_reason(result.denial)}"
        when :interrupt
          # An elicitation/input_required is not a tool failure: repairing it
          # replays the same call and the server asks again until the repair
          # budget is spent. Stop terminally as :unknown so the run surfaces the
          # server's question to the operator instead of livelocking.
          raise EffectUnknownError,
                "MCP capability needs operator input: #{safe_mcp_reason(result.interrupt)}"
        else
          raise EffectUnknownError, 'MCP capability returned an unknown outcome'
        end
      end

      def safe_mcp_reason(reason)
        text = reason.respond_to?(:to_h) ? reason.to_h.inspect : reason.to_s
        sanitize_remote_text(text.byteslice(0, 512) || '')
      end

      def sanitize_remote_text(text) = Tamoz::Core.scrub_secrets(text)

      def check_payload(result)
        {
          'output' => result.to_s,
          'shaped' => result.shaped,
          'check' => {
            'name' => result.name,
            'outcome' => result.outcome,
            'passed' => result.passed?,
            'failure_signature' => result.failure_signature
          }
        }
      end

      public

      def build_intent(step, accepted, arguments, iteration: 0, sub_operation: 0)
        tool = step.fetch('tool')
        fields = {
          step_id: step.fetch('id'),
          plan_id: accepted.fetch('plan_id'),
          plan_digest: accepted.fetch('plan_digest'),
          tool:,
          operation: "tool.#{tool}",
          safety: tool_safety(tool, arguments).to_s,
          arguments_digest: SessionRecords.digest(Tamoz::Agent::Deliberation.canonical(arguments)),
          iteration: Integer(iteration),
          sub_operation: Integer(sub_operation)
        }
        @configuration.capabilities.effect_intent(tool, arguments).each do |key, value|
          fields[key.to_sym] = value
        end
        fields[:check_name] = arguments.fetch('name') if tool == 'run_check'
        SessionRecords.build('effect_intent', **fields)
      end

      def resolved_effect_arguments(arguments, tool)
        return arguments unless %w[apply_patch create_file].include?(tool)
        return arguments if arguments.key?('expected_sha256')

        case tool
        when 'apply_patch'
          observed = EffectDispatcher.observe(
            @configuration.toolbox.root.join(arguments.fetch('path'))
          )
          arguments.merge('expected_sha256' => observed.fetch('state'))
        when 'create_file'
          arguments.merge('expected_sha256' => Digest::SHA256.hexdigest(arguments.fetch('content')))
        end
      end

      def resolved_execution_arguments(intent, step)
        tool = intent.fetch('tool')
        arguments = step.fetch('arguments')
        return arguments unless %w[apply_patch create_file].include?(tool)
        return arguments if arguments.key?('expected_sha256')

        digest =
          case tool
          when 'apply_patch' then intent.fetch('before_state')
          when 'create_file' then intent.fetch('after_digest')
          else raise ToolError, 'unreachable resolved execution arguments'
          end
        arguments.merge('expected_sha256' => digest)
      end

      def tool_safety(tool, arguments)
        @configuration.capabilities.safety(tool, arguments)
      end

      def mcp_tool?(tool)
        @configuration.capabilities.mcp_capability?(tool)
      end

      def mcp_planning_surface(allowed)
        source = @configuration.mcp
        return {} unless source

        allowed.filter_map { |name| probe_entry(source, name) || mcp_entry(source, name) }.to_h.freeze
      end

      def prompt_safe(value)
        text = String(value)
        text = text.encode('UTF-8', invalid: :replace, undef: :replace) unless text.valid_encoding?
        text.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, '')
      end

      def allowed_tool_names(phase)
        @configuration.capabilities.names(phase)
      end

      def maximum_effect_output_bytes(tool)
        @configuration.capabilities.maximum_effect_output_bytes(tool)
      end

      def preview_for(tool, arguments)
        @configuration.capabilities.preview(tool, arguments)
      end

      # Pipeline A's one policy owner: build the engine Request from the
      # prepared step and return the Decision. The argv/target projection is
      # the only place tool argument structure is translated into grant-key
      # material; unknown tools project nothing and fail closed to :once.
      def decide_step_tool(tool:, arguments:, session_id:, step_scope:)
        request = approval_engine.build_request(
          tool: tool,
          argv: approval_argv(tool, arguments),
          targets: approval_targets(tool, arguments),
          effect_class: @configuration.capabilities.effect_class(tool),
          session_id: session_id,
          workspace_root: @configuration.toolbox.root.to_s
        )
        approval_engine.decide_or_reuse(request, step_scope: step_scope)
      end

      def resolve_decision(decision_id:, answer:, scope:)
        approval_engine.resolve(decision_id: decision_id, answer: answer, scope: scope)
      end

      def approval_engine
        @configuration.approval_engine
      end

      private

      def approval_argv(tool, arguments) = RequestProjection.argv(tool, arguments)

      def approval_targets(tool, arguments) = RequestProjection.targets(tool, arguments)

      # A probe's description is operator-authored, not server text.
      def probe_entry(source, name)
        [name, source.probe_description(name)] if source.respond_to?(:probe?) && source.probe?(name)
      end

      def mcp_entry(source, name)
        return unless source.name?(name)

        descriptor = source.descriptor_for(name)
        snapshot = source.catalogs[descriptor.source_id]
        entry = snapshot&.entries&.find { |candidate| candidate.name == descriptor.name }
        description = entry&.description
        return if description.nil? || description.empty?

        # A server authors this text; bounding it is not marking it. Attribute it
        # in the planner prompt the way Invocation attributes remote blocks, so a
        # remote description is not indistinguishable from a trusted local one.
        [name, "remote content from server #{descriptor.source_id}: #{prompt_safe(description)}"]
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/ParameterLists
  end
end
