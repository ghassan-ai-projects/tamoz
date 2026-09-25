# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # The operator's MCP source narrowed to governed probes: a server that backs a probe exposes no raw tool.
    class ProbeSource
      # A call the probe refuses before or instead of reaching the server.
      class Refusal < Tamoz::Tools::ToolArgumentError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

      EpisodeCall = Data.define(:probe, :scope, :arguments)

      TRUNCATION_MARK = "\n[truncated]"
      CATALOG_DIGEST_KEY = 'probes:catalog'

      attr_reader :catalog, :descriptors, :names, :read_only_names

      def initialize(source:, catalog:, clock: -> { Time.now.utc })
        @source = source
        @catalog = catalog
        @clock = clock
        check_backing_tools!
        # One stdio MCP server answers one request at a time; concurrent episodes would read each other's replies.
        @locks = catalog.backing_servers.to_h { |server| [server, Mutex.new] }.freeze
        @implicit_slots = { 'target' => { 'free' => 'enum', 'values' => catalog.targets.keys },
                            'lookback_minutes' => { 'free' => 'integer', 'min' => 1,
                                                    'max' => ProbeCatalog::MAX_LOOKBACK_MINUTES } }.freeze
        @descriptors = build_descriptors
        @names = @descriptors.map(&:id).freeze
        @read_only_names = @descriptors.select { |descriptor| descriptor.effect_class == :read_only }.map(&:id).freeze
      end

      def catalogs = @source.catalogs
      def mcp_catalogs = @source.mcp_catalogs
      def empty? = @source.empty?
      def close = @source.close
      def mcp_source_digests = @source.mcp_source_digests.merge(CATALOG_DIGEST_KEY => @catalog.digest)
      def name?(name) = @names.include?(String(name))
      def descriptor_for(name) = @descriptors.find { |descriptor| descriptor.id == String(name) }
      def probe?(name) = @catalog.probes.key?(String(name))
      def probe_description(name) = @catalog.probe(name).description

      def descriptor_for!(name)
        descriptor_for(name) || raise(Tamoz::Agent::ToolError, "unknown tool #{String(name).inspect}")
      end

      def source_id_for(name) = descriptor_for!(name).source_id
      def read_only?(name) = probe?(name) || @source.read_only?(visible!(name))

      def validate(name, arguments)
        probe = @catalog.probe(name)
        return @source.validate(visible!(name), arguments) unless probe

        session_free_arguments(probe, arguments)
        arguments
      end

      def effect_intent(name, arguments)
        return @source.effect_intent(visible!(name), arguments) unless probe?(name)

        validate(name, arguments)
        {}
      end

      def preview(name, arguments)
        probe = @catalog.probe(name)
        return @source.preview(visible!(name), arguments) unless probe

        canonical = JSON.generate(Deliberation.canonical(arguments))
        "Probe #{probe.name} (reads #{probe.backing_id})\narguments: #{canonical}"
      end

      def maximum_effect_output_bytes(name)
        probe = @catalog.probe(name)
        probe ? probe.max_result_bytes : @source.maximum_effect_output_bytes(visible!(name))
      end

      # Runs inside the session's journaled effect, so the call time that anchors the window is recorded with it.
      def execute(context, name, arguments)
        probe = @catalog.probe(name)
        return @source.execute(context, visible!(name), arguments) unless probe

        resolved = resolve(probe, session_free_arguments(probe, arguments), session_scope(probe, arguments))
        bounded_outcome(probe, backing_call(context, probe, resolved))
      end

      def session_tools = tool_surface { |probe| probe.session_schema(@catalog.targets.keys) }
      def episode_surface = tool_surface(&:episode_schema)

      # Episode callables in the EpisodeCapabilityHost adapter shape. The target and window come from the verified
      # snapshot; a refusal or a failed call is a result the model sees, never an episode failure.
      def episode_tools(entity_id:, time_range:)
        scope = { 'target' => @catalog.targets[String(entity_id)], 'window' => time_range }
        @catalog.probes.values.to_h do |probe|
          [probe.name, ->(arguments, context) { episode_call(EpisodeCall.new(probe:, scope:, arguments:), context) }]
        end
      end

      private

      def check_backing_tools!
        @catalog.probes.each_value do |probe|
          next if @source.name?(probe.backing_id) && @source.read_only?(probe.backing_id)

          raise ProbeCatalog::Error,
                "probe #{probe.name} backs onto #{probe.backing_id}, which the server does not offer"
        end
      end

      def tool_surface
        @catalog.probes.values.map do |probe|
          { 'name' => probe.name, 'description' => probe.description, 'parameters' => yield(probe) }
        end
      end

      def visible!(name)
        descriptor_for!(name)
        String(name)
      end

      def episode_call(call, context)
        outcome = run_episode_probe(call, context)
        return refusal_result('probe_failed', "#{call.probe.name} did not complete (#{outcome.status})") unless
          outcome.status == :succeeded

        episode_result(bounded_outcome(call.probe, outcome).observation)
      rescue Refusal => e
        refusal_result(e.code, e.message)
      rescue Tamoz::Agent::ToolError, Tamoz::EffectUnknownError => e
        refusal_result('probe_failed', e.message)
      end

      def run_episode_probe(call, context)
        probe = call.probe
        free = free_arguments(probe, call.arguments, allowed: probe.free.keys)
        check_still_wanted!(context)
        backing_call(context, probe, resolve(probe, free, call.scope))
      end

      def backing_call(context, probe, arguments)
        @locks.fetch(probe.server).synchronize { @source.execute(context, probe.backing_id, arguments) }
      end

      # The episode host hands over its cancellation token and monotonic deadline; neither is a tool result.
      def check_still_wanted!(context)
        raise Tamoz::CancelledError, 'probe cancelled' if context[:cancellation]&.cancelled?

        deadline = context[:deadline]
        raise Tamoz::TimeoutError, 'probe deadline exceeded' if
          deadline.is_a?(Numeric) && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      end

      def episode_result(observation)
        text = observation.text
        { 'json' => text, 'truncated' => observation.truncated, 'result_bytes' => text.bytesize }
      end

      def refusal_result(code, message)
        { 'json' => message, 'is_error' => true, 'error_code' => code, 'result_bytes' => message.bytesize }
      end

      def session_free_arguments(probe, arguments)
        implicit = []
        implicit << 'target' if probe.targeted?
        implicit << 'lookback_minutes' if probe.windowed?
        free_arguments(probe, arguments, allowed: probe.free.keys + implicit).except(*implicit)
      end

      def session_scope(probe, arguments)
        scope = {}
        scope['target'] = @catalog.targets[arguments['target']] if probe.targeted?
        if probe.windowed?
          now = @clock.call
          scope['window'] = { 'from' => (now - (arguments.fetch('lookback_minutes') * 60)).iso8601,
                              'until' => now.iso8601 }
        end
        scope
      end

      def free_arguments(probe, arguments, allowed:)
        raise Refusal.new('arguments_not_object', "#{probe.name} arguments must be an object") unless
          arguments.is_a?(Hash)

        check_argument_names!(probe, arguments.keys, allowed)
        arguments.each { |key, value| check_free_value!(probe, key, value) }
        arguments
      end

      def check_argument_names!(probe, names, allowed)
        unknown = names - allowed
        unless unknown.empty?
          raise Refusal.new('argument_not_free', "#{probe.name} does not accept #{unknown.first.inspect}; " \
                                                 "it accepts only #{allowed.join(', ')}")
        end
        missing = allowed - names
        raise Refusal.new('argument_missing', "#{probe.name} needs #{missing.first}") unless missing.empty?
      end

      def check_free_value!(probe, key, value)
        return if ProbeCatalog.free_value?(probe.free.fetch(key) { @implicit_slots.fetch(key) }, value)

        raise Refusal.new('argument_invalid', "#{probe.name} argument #{key} is out of bounds")
      end

      def resolve(probe, free, scope)
        pinned = probe.pinned.transform_values { |value| interpolate(probe, value, scope) }
        chosen = free.to_h do |key, value|
          [key, probe.free.dig(key, 'free') == 'enum' ? interpolate(probe, value, scope) : value]
        end
        pinned.merge(chosen)
      end

      def interpolate(probe, value, scope)
        return value.map { |item| interpolate(probe, item, scope) } if value.is_a?(Array)
        return value unless value.is_a?(String)

        value.gsub(ProbeCatalog::PLACEHOLDER) do
          placeholder = ::Regexp.last_match
          scope.dig(placeholder[1], placeholder[2]) ||
            raise(Refusal.new('scope_unresolved', "#{probe.name} cannot resolve #{placeholder} for this situation"))
        end
      end

      def bounded_outcome(probe, outcome)
        observation = outcome.respond_to?(:observation) && outcome.observation
        return outcome unless observation

        text, cut = bounded_text(probe, observation)
        block = { 'type' => 'text', 'text' => text,
                  'attribution' => format(Tamoz::Mcp::Invocation::ATTRIBUTION_TEMPLATE, probe.server) }
        outcome.with(observation: observation.with(text:, content_blocks: [block], structured_content: nil,
                                                   truncated: observation.truncated || cut))
      end

      def bounded_text(probe, observation)
        text = observation.text.to_s
        text = JSON.generate(observation.structured_content) if text.empty? && observation.structured_content
        text = Tamoz::Core.scrub_secrets(text)
        return [text, false] if text.bytesize <= probe.max_result_bytes

        [text.byteslice(0, probe.max_result_bytes - TRUNCATION_MARK.bytesize).scrub('') + TRUNCATION_MARK, true]
      end

      def build_descriptors
        visible = @source.descriptors.reject { |descriptor| @catalog.backing_servers.include?(descriptor.source_id) }
        (visible + @catalog.probes.values.map { |probe| build_descriptor(probe) }).freeze
      end

      def build_descriptor(probe)
        Tamoz::Mcp::Invocation::Descriptor.new(
          id: probe.name, name: probe.name, source_id: probe.server,
          definition_digest: Tamoz::Core.digest(ProbeCatalog::DIGEST_PREFIX, probe.to_h),
          input_schema: probe.session_schema(@catalog.targets.keys),
          output_schema: nil, effect_class: :read_only, protocol_profile: 'probe'
        )
      end
    end
  end
end
