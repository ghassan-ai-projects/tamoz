# frozen_string_literal: true

require 'digest'

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
        outcome = EffectDispatcher.run(
          context:,
          operation: "model.generate.#{stage}",
          safety: @configuration.model_call_safety,
          call_index:,
          request: { 'stage' => stage.to_s, 'system' => system, 'prompt' => prompt },
          actor: 'tamoz.agent.session',
          logical_identity: logical_identity(
            context:, capability_id: "model:#{stage}",
            arguments: { 'stage' => stage.to_s, 'system' => system, 'prompt' => prompt },
            iteration:, sub_operation:
          )
        ) do
          { 'output' => String(@configuration.model.generate(stage:, system:, prompt:)) }
        end
        unwrap_model(outcome)
      end

      def unwrap_model(outcome)
        return outcome unless outcome.status == :succeeded

        value = outcome.value
        text = value.is_a?(Hash) ? value.fetch('output') : String(value)
        outcome.with(value: text)
      end

      def dispatch(context, intent, step, iteration: 0, sub_operation: 0)
        tool = intent.fetch('tool')
        arguments = resolved_execution_arguments(intent, step)
        safety = intent.fetch('safety').to_sym
        options = dispatch_options(context, intent, tool, arguments, safety).merge(
          logical_identity: logical_identity(
            context:, capability_id: tool, arguments:, iteration:, sub_operation:
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
          request: dispatch_request(intent, tool, arguments),
          actor: 'tamoz.agent.session',
          after_start: -> { after_effect_started(intent.fetch('operation')) },
          reconcile: reconciler_for(intent, safety)
        }
      end

      def logical_identity(context:, capability_id:, arguments:, iteration:, sub_operation:)
        {
          request_id: context.request_id,
          execution_id: context.execution_id,
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

      def dispatch_request(intent, tool, arguments)
        {
          'tool' => tool,
          'arguments' => Tamoz::Agent::Deliberation.canonical(arguments),
          'plan_digest' => intent.fetch('plan_digest')
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

      def after_effect_started(operation)
        model = @configuration.model
        model.after_effect_started(operation:) if model.respond_to?(:after_effect_started)
      end

      def result_payload(result)
        return check_payload(result) if result.is_a?(CheckReceipt)
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
        when :denied, :interrupt
          reason = result.denial || result.interrupt
          raise ToolError, "MCP capability did not complete: #{safe_mcp_reason(reason)}"
        else
          raise EffectUnknownError, 'MCP capability returned an unknown outcome'
        end
      end

      def safe_mcp_reason(reason)
        text = reason.respond_to?(:to_h) ? reason.to_h.inspect : reason.to_s
        text.byteslice(0, 512)
      end

      def sanitize_remote_text(text)
        Tamoz::Core::SECRET_VALUE_PATTERNS.reduce(String(text)) do |sanitized, pattern|
          sanitized.gsub(pattern, '[REDACTED]')
        end
      end

      def check_payload(result)
        {
          'output' => result.to_s,
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

        allowed.filter_map { |name| mcp_entry(source, name) }.to_h.freeze
      end

      def prompt_safe(value)
        text = String(value)
        text = text.encode('UTF-8', invalid: :replace, undef: :replace) unless text.valid_encoding?
        text.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, '')
      end

      def allowed_tool_names(phase)
        @configuration.capabilities.names(phase)
      end

      def approval_required?(tool)
        @configuration.capabilities.approval_required?(tool)
      end

      def maximum_effect_output_bytes(tool)
        @configuration.capabilities.maximum_effect_output_bytes(tool)
      end

      def preview_for(tool, arguments)
        @configuration.capabilities.preview(tool, arguments)
      end

      private

      def mcp_entry(source, name)
        return unless source.name?(name)

        descriptor = source.descriptor_for(name)
        snapshot = source.catalogs[descriptor.source_id]
        entry = snapshot&.entries&.find { |candidate| candidate.name == descriptor.name }
        description = entry&.description
        return if description.nil? || description.empty?

        [name, prompt_safe(description)]
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/ParameterLists
  end
end
