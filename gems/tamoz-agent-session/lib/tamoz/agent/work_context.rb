# frozen_string_literal: true

module Tamoz
  module Agent
    # The work route's view of the context engine: its frozen header, its surface entries, its measurements.
    # rubocop:disable Metrics/AbcSize -- the opening surface is one ordered assembly.
    class WorkContext
      MUTATING_TOOLS = %w[apply_patch create_file].freeze
      SURFACES = Harness::PromptPack::SURFACES.keys.freeze

      # Operator settings for the work route; all of it is trusted configuration.
      # `research` is nil for an ordinary turn, :lead for a deep-research turn, :child for a research subagent.
      # `research_dir` is where research runs are written; `research_budgets` may only narrow the shipped budgets.
      # `skill` is a skill the user invoked for this thread, loaded before the first model call.
      Settings = Data.define(:surface, :persona, :preferences, :guidance_files, :guidance_bytes, :context_policy,
                             :loop_policy, :research, :research_dir, :research_budgets, :skill) do
        def self.from(options)
          options = (options || {}).transform_keys(&:to_sym)
          surface = options.fetch(:surface, :cli).to_sym
          unless SURFACES.include?(surface)
            raise ConfigurationError,
                  "work surface must be one of #{SURFACES.join(', ')}"
          end

          new(surface:, persona: options[:persona], preferences: options.fetch(:preferences, {}),
              guidance_files: Array(options.fetch(:guidance_files, [])),
              guidance_bytes: options.fetch(:guidance_bytes, 16_384),
              context_policy: ContextEngine::Policy.from_h(options.fetch(:context_policy, {})),
              loop_policy: Harness::LoopPolicy.from_h(options.fetch(:loop_policy, {})),
              research: options[:research]&.to_sym, research_dir: options[:research_dir],
              research_budgets: options[:research_budgets], skill: options[:skill])
        end
      end

      # `research: :lead` views the same configuration as a deep-research turn.
      def initialize(configuration:, research: nil)
        @configuration = configuration
        @research = research
        @memo = {}
        freeze
      end

      # Built on first use: every session compiles every graph variant, and only a work turn needs these.
      def settings
        @memo[:settings] ||= Settings.from(@configuration.harness).then do |base|
          @research ? base.with(research: @research, loop_policy: Harness::ResearchPack.loop_policy) : base
        end
      end

      def header
        @memo[:header] ||= Harness::Header.build(tools: surface_tools, model: model_name, surface: settings.surface,
                                                 persona: settings.persona, preferences: settings.preferences)
      end

      def store
        @configuration.artifact_store || raise(ConfigurationError, 'the work route needs an artifact store')
      end

      def resolve = ContextEngine::Surface.resolver(store)

      def window
        (@configuration.model.respond_to?(:context_window) && @configuration.model.context_window) ||
          raise(ConfigurationError, 'the work route needs a context window: set the profile role ' \
                                    'context_window or TAMOZ_CONTEXT_WINDOW')
      end

      def entry(entries, kind, text, **fields)
        ContextEngine::Surface.entry(kind:, seq: ContextEngine::Surface.next_seq(entries), text: scrub(text),
                                     store:, **fields)
      end

      def append(entries, kind, text, **fields) = entries + [entry(entries, kind, text, **fields)]

      def messages(entries) = ContextEngine::Surface.messages(entries, header:, resolve:)

      def estimate(entries, calibration)
        ContextEngine::TokenMeter.estimate(messages: messages(entries), tools: header.tools,
                                           calibration: ContextEngine::TokenMeter::Calibration.from_h(calibration))
      end

      # `carried`: the memory brief and the thread checkpoint, pinned after project guidance.
      def opening(task:, transcript:, previous_answer:, updates:, carried: {})
        transcript = transcript[0...-1] if transcript.last == { 'role' => 'user', 'text' => task }
        entries = method_pinned(append([], 'runtime', runtime_text, pinned: true))
        entries = append(entries, 'guidance', scrub(guidance.text), pinned: true, source: guidance.sources.join(' ')) if
          guidance
        entries = skill_entries(entries)
        entries = append(entries, 'memory', scrub(carried[:memory]), pinned: true) if carried[:memory]
        if carried[:checkpoint]
          entries = append(entries, 'checkpoint', thread_checkpoint(carried[:checkpoint]), pinned: true,
                                                                                           source: 'thread')
        end
        entries = append(entries, 'user', scrub(transcript_text(transcript)), pinned: true) unless transcript.empty?
        if previous_answer
          carried = format(Harness::PromptPack.fetch('previous_turn'), answer: previous_answer)
          entries = append(entries, 'user', scrub(carried), pinned: true)
        end
        entries = updates.reduce(entries) { |opened, update| append(opened, 'system_update', update, pinned: true) }
        append(entries, 'user', scrub(task), pinned: true)
      end

      def scrub(text) = Tamoz::Core.scrub_secrets(text)

      # The catalog is shown exactly when load_skill is on the surface; a user-invoked skill follows it.
      def skill_entries(entries)
        return entries unless skills?

        entries = append(entries, 'guidance', toolbox.skill_catalog_prompt, pinned: true, source: 'skills')
        return entries unless settings.skill

        append(entries, 'guidance', toolbox.execute('load_skill', { 'skill' => settings.skill }), pinned: true,
                                                                                         source: 'skill')
      end

      def skills? = header.tool_names.include?('load_skill')

      # Provenance: which skill tree reached the model, and who chose it.
      def skill_loaded(reference, invoked_by:)
        { 'event' => 'skill_loaded', **toolbox.skill_identity(reference), 'invoked_by' => invoked_by }
      end

      def opening_trace = settings.skill && skills? ? [skill_loaded(settings.skill, invoked_by: 'user')] : []

      def toolbox = @configuration.toolbox

      def thread_checkpoint(summary) = ContextEngine::Compaction.checkpoint_text(summary)

      def reports? = header.tool_names.include?(Harness::PromptPack.report_tool.name)

      def probe?(name) = @configuration.mcp.respond_to?(:probe?) && @configuration.mcp.probe?(name)

      # {shown name => capability} for the remote tools an ordinary turn shows under a tool-name-safe name.
      def remote_tools
        @memo[:remote_tools] ||= begin
          shown = settings.research.nil? && settings.surface != :subagent
          shown ? chat_web_backings.merge(mcp_aliases) : {}
        end
      end

      # {tool_call_id => probe name} for this turn's probe calls that answered.
      def gathered(entries)
        entries.select { |entry| entry['kind'] == 'tool_result' && entry['source'] == 'probe' }
               .to_h { |entry| [entry.fetch('tool_call_id'), entry.fetch('name')] }
      end

      private

      # A research turn's method, pinned after the runtime snapshot; an ordinary turn pins nothing here.
      def method_pinned(entries)
        return entries unless settings.research == :lead

        method = Harness::PromptPack.fetch('research_method')
        append(entries, 'guidance', method, pinned: true, source: 'research method')
      end

      # A deep-research lead plans, sends waves and writes; a research child searches, reads and reports sources.
      def surface_tools
        case settings.research
        when :lead then Harness::ResearchPack.tools(:lead)
        when :child then web_schemas + Harness::ResearchPack.tools(:child)
        else toolbox_schemas + remote_schemas + delegate_schemas
        end
      end

      def chat_web_backings
        Harness::ResearchPack.chat_web_backings.select { |_, id| @configuration.capabilities.descriptor?(id) }
      end

      def mcp_aliases
        source = @configuration.mcp
        return {} unless source

        ids = @configuration.capabilities.names(:action).select do |id|
          source.name?(id) && !probe?(id) && source.descriptor_for(id).source_id != CapabilityBinding::WEBSEARCH_SERVER_ID
        end
        ids.each_with_object({}) do |id, aliases|
          shown = mcp_alias(id)
          next aliases[shown] = id unless aliases.key?(shown)

          warn "tamoz: MCP tool #{id} is not shown: its tool name #{shown} is taken by #{aliases[shown]}"
        end
      end

      def mcp_alias(id) = "mcp_#{id.delete_prefix('mcp:').gsub(/[^A-Za-z0-9_-]/, '_')}"[0, 64]

      def remote_schemas
        web = chat_web_backings
        Harness::ResearchPack.chat_web_tools(remote_tools.keys & web.keys) +
          (remote_tools.to_a - web.to_a).map { |shown, id| mcp_schema(shown, id) }
      end

      # A server authors the description and schema: both are shown attributed, never as Tamoz's own words.
      def mcp_schema(shown, id)
        descriptor = @configuration.mcp.descriptor_for(id)
        text = @configuration.capabilities.remote_planning_surface([id]).fetch(id, descriptor.name)
        schema = descriptor.input_schema
        parameters = schema.is_a?(Hash) && schema['type'] == 'object' ? schema : { 'type' => 'object' }
        description = "Remote tool from MCP server #{descriptor.source_id}: #{text}"
        ContextEngine::ToolSchema.new(name: shown, description:, parameters:)
      end

      def web_schemas
        allowed = @configuration.capabilities.names(:action)
        Harness::ResearchPack.web_tools(Harness::ResearchPack.web_backings.select { |_, id| allowed.include?(id) }.keys)
      end

      def delegate_schemas
        roles = @configuration.subagent_apps.values.map(&:role).reject(&:research?)
        return [] if roles.empty? || settings.surface == :subagent

        [Harness::PromptPack.delegate_tool(roles:)]
      end

      def toolbox_schemas
        toolbox = @configuration.toolbox
        allowed = @configuration.capabilities.names(:action)
        toolbox.schemas.filter_map do |name, parameters|
          next unless allowed.include?(name)

          ContextEngine::ToolSchema.new(name:, description: toolbox.descriptions.fetch(name), parameters:)
        end + probe_schemas(allowed) + memory_schemas
      end

      def memory_schemas = @configuration.memory ? Harness::PromptPack.memory_tools : []

      # The operator's probes, and report_findings to finish with on a read-only turn; none when no probe is admitted.
      def probe_schemas(allowed)
        source = @configuration.mcp
        return [] unless source.respond_to?(:session_tools)

        probes = source.session_tools.select { |tool| allowed.include?(tool.fetch('name')) }.map do |tool|
          ContextEngine::ToolSchema.new(name: tool.fetch('name'), description: tool.fetch('description'),
                                        parameters: tool.fetch('parameters'))
        end
        return probes if probes.empty? || allowed.intersect?(MUTATING_TOOLS)

        probes + [Harness::PromptPack.report_tool]
      end

      def model_name = @configuration.model.respond_to?(:model) ? String(@configuration.model.model) : 'model'

      def guidance
        return nil if settings.guidance_files.empty?

        Harness::Instructions.load(root: @configuration.toolbox.root, files: settings.guidance_files,
                                   max_bytes: settings.guidance_bytes)
      end

      def runtime_text
        policy = settings.loop_policy
        Harness::Header.runtime_snapshot(
          root: @configuration.toolbox.root.to_s, date: Time.now.utc.strftime('%Y-%m-%d'),
          budgets: { 'model calls' => policy.max_model_calls, 'tool calls' => policy.max_tool_calls,
                     'context window tokens' => window }
        )
      end

      def transcript_text(transcript)
        lines = transcript.map { |fragment| "#{fragment.fetch('role')}: #{fragment.fetch('text')}" }
        "Earlier messages in this conversation, oldest first:\n#{lines.join("\n")}"
      end
    end
    # rubocop:enable Metrics/AbcSize
  end
end
