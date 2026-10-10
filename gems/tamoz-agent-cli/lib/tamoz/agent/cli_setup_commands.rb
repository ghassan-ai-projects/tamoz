# frozen_string_literal: true

require 'json'
require 'optparse'
require 'psych'

module Tamoz
  module Agent
    # `tamoz setup`: one runtime's workspace, models and the chat profile every channel uses.
    module CLISetupCommands
      MODEL_ROLES = %w[chat transcription voice vision].freeze
      KEYED_ROLES = %w[transcription voice vision].freeze
      TOOLS = %w[read_file list_directory search_text glob apply_patch create_file].freeze
      SKILL_TOOLS = %w[load_skill read_skill_resource].freeze

      def cmd_setup(options, argv)
        request = { workspace: nil, models: {} }
        setup_parser(options, request).parse!(argv)
        directory = setup_runtime(runtime_dir_path(options), options[:root], **request)
        ensure_chat_profile(directory)
        options[:json] ? print_setup_json(directory) : print_setup_text(directory)
      end

      private

      # A written profile is never rewritten: every thread bound to it pinned its digest.
      def ensure_chat_profile(directory)
        return if directory.chat_profile?

        Tamoz::Core::PrivateDirectory.secure(directory.profiles_path)
        path = File.join(directory.profiles_path, "#{directory.chat_profile_id}.yaml")
        Tamoz::Core::AtomicFile.create(path, Psych.dump(chat_profile(directory)), mode: 0o600)
      end

      def chat_profile(directory)
        root = directory.workspace_root
        skills = chat_skills(directory, root)
        tools = skills.empty? ? TOOLS : TOOLS + SKILL_TOOLS
        digest = Toolbox.new(root:, allow_changes: true, checks: {}, allowed_tools: tools, skills:).catalog_digest
        { 'profile' => { 'schema_version' => 1, 'profile_id' => directory.chat_profile_id, 'profile_version' => '1.0',
                         'canonical_root' => root },
          'roots' => { 'workspace' => root }, 'tools' => { 'allowed' => tools },
          'policy' => { 'allow_changes' => true, 'default_check_safety' => 'read_only', 'graph_version' => '1',
                        'behavior_version' => '1.0', 'tool_catalog_digest' => digest,
                        'unattended_catalog_digest' => digest } }
      end

      # Chat offers the skill tools only when the operator enabled a skills source that holds a skill.
      def chat_skills(directory, root)
        return Tamoz::Skills.empty unless directory.enabled_sources.include?('skills')

        settings = directory.source_settings('skills')
        skills_root = directory.skills_root
        skills_root = nil unless settings.key?('root') || File.directory?(skills_root)
        Tamoz::Skills.operator_snapshot(root: skills_root, workspace_root: root, bundled: settings['bundled'] == true)
      end

      def setup_parser(options, request)
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz setup [--workspace PATH] [--chat PROVIDER/MODEL] ' \
                          '[--transcription PROVIDER/MODEL] [--voice PROVIDER/MODEL --voice-name NAME] ' \
                          '[--vision PROVIDER/MODEL]'
          parser.on('--workspace PATH', 'The folder the agent works in (a new runtime defaults to --root)') do |path|
            request[:workspace] = File.expand_path(path)
          end
          MODEL_ROLES.each { |role| model_option(parser, request[:models], role) }
          KEYED_ROLES.each { |role| key_options(parser, request[:models], role) }
          parser.on('--voice-name NAME', 'The voice the voice model speaks in') do |name|
            (request[:models]['voice'] ||= {})['voice'] = name
          end
          accept_json(parser, options)
        end
      end

      def model_option(parser, models, role)
        parser.on("--#{role} PROVIDER/MODEL", "The #{role} model") do |value|
          provider, model = value.split('/', 2)
          raise OptionParser::InvalidArgument, 'takes PROVIDER/MODEL' if [provider, model].any? { _1.to_s.empty? }

          (models[role] ||= {}).merge!('provider' => provider, 'model' => model)
        end
      end

      def key_options(parser, models, role)
        parser.on("--#{role}-credential NAME", "The *_API_KEY variable that holds the #{role} key") do |name|
          (models[role] ||= {})['credential'] = name
        end
        parser.on("--#{role}-api-base URL", "The #{role} endpoint") { |url| (models[role] ||= {})['api_base'] = url }
      end

      def setup_runtime(path, root, workspace:, models:)
        if File.exist?(File.join(path, RuntimeDirectory::CONFIG_FILE))
          return RuntimeDirectory.configure!(path, workspace:, models:, env: @env)
        end

        RuntimeDirectory.create!(path, workspace: workspace || File.expand_path(root), models:)
      end

      def print_setup_json(directory)
        @out.puts JSON.generate(setup_summary(directory))
        0
      end

      def print_setup_text(directory)
        summary = setup_summary(directory)
        @out.puts "Runtime ready: #{summary.fetch('runtime_dir')}"
        @out.puts "  workspace: #{summary.fetch('workspace')}"
        summary.fetch('models').each { |role, name| @out.puts "  #{role}: #{name}" }
        @out.puts "  chat profile: #{summary.fetch('chat_profile')}"
        summary.fetch('missing_keys').each { |key| @out.puts "note: #{key} is not set in this environment yet" }
        0
      end

      def setup_summary(directory)
        configured = MODEL_ROLES.filter_map { |role| [role, directory.models[role]] if directory.models[role] }
        { 'runtime_dir' => directory.path, 'workspace' => directory.workspace_root,
          'models' => configured.to_h { |role, model| [role, "#{model.provider}/#{model.model}"] },
          'chat_profile' => directory.chat_profile_id,
          'missing_keys' => configured.filter_map { |_role, model| missing_key(model) }.uniq }
      end

      def missing_key(model)
        key = model.credential || Providers::ENV_KEYS[model.provider.to_sym]
        key if key && @env[key].to_s.empty?
      end
    end
  end
end
