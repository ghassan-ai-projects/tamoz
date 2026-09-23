# frozen_string_literal: true

module Tamoz
  module Agent
    # The work route's view of the context engine: its frozen header, its surface entries, its measurements.
    # rubocop:disable Metrics/AbcSize -- the opening surface is one ordered assembly.
    class WorkContext
      MUTATING_TOOLS = %w[apply_patch create_file].freeze
      SURFACES = %i[cli chat].freeze

      # Operator settings for the work route; all of it is trusted configuration.
      Settings = Data.define(:surface, :persona, :preferences, :guidance_files, :guidance_bytes, :context_policy,
                             :loop_policy) do
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
              loop_policy: Harness::LoopPolicy.from_h(options.fetch(:loop_policy, {})))
        end
      end

      def initialize(configuration:)
        @configuration = configuration
        @memo = {}
        freeze
      end

      # Built on first use: every session compiles every graph variant, and only a work turn needs these.
      def settings = @memo[:settings] ||= Settings.from(@configuration.harness)

      def header
        @memo[:header] ||= Harness::Header.build(tools: toolbox_schemas, model: model_name, surface: settings.surface,
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
        ContextEngine::Surface.entry(kind:, seq: ContextEngine::Surface.next_seq(entries), text:, store:, **fields)
      end

      def append(entries, kind, text, **fields) = entries + [entry(entries, kind, text, **fields)]

      def messages(entries) = ContextEngine::Surface.messages(entries, header:, resolve:)

      def estimate(entries, calibration)
        ContextEngine::TokenMeter.estimate(messages: messages(entries), tools: header.tools,
                                           calibration: ContextEngine::TokenMeter::Calibration.from_h(calibration))
      end

      def opening(task:, transcript:, previous_answer:, updates:)
        transcript = transcript[0...-1] if transcript.last == { 'role' => 'user', 'text' => task }
        entries = append([], 'runtime', runtime_text, pinned: true)
        entries = append(entries, 'guidance', scrub(guidance.text), pinned: true, source: guidance.sources.join(' ')) if
          guidance
        entries = append(entries, 'user', scrub(transcript_text(transcript)), pinned: true) unless transcript.empty?
        if previous_answer
          carried = format(Harness::PromptPack.fetch('previous_turn'), answer: previous_answer)
          entries = append(entries, 'user', scrub(carried), pinned: true)
        end
        entries = updates.reduce(entries) { |opened, update| append(opened, 'system_update', update, pinned: true) }
        append(entries, 'user', scrub(task), pinned: true)
      end

      def scrub(text) = Tamoz::Core::SECRET_VALUE_PATTERNS.reduce(text) { |value, pattern| value.gsub(pattern, '[REDACTED]') }

      private

      def toolbox_schemas
        toolbox = @configuration.toolbox
        allowed = @configuration.capabilities.names(:action)
        toolbox.schemas.filter_map do |name, parameters|
          next unless allowed.include?(name)

          ContextEngine::ToolSchema.new(name:, description: toolbox.descriptions.fetch(name), parameters:)
        end
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
