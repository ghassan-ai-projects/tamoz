# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # `tamoz setup`: one runtime's workspace, models and the chat profile every channel uses.
    module CLISetupCommands
      MODEL_ROLES = %w[chat transcription vision].freeze
      KEYED_ROLES = %w[transcription vision].freeze

      def cmd_setup(options, argv)
        request = { workspace: nil, models: {} }
        setup_parser(options, request).parse!(argv)
        directory = setup_runtime(runtime_dir_path(options), options[:root], **request)
        write_chat_profile(directory, directory.chat_profile_id) unless directory.chat_profile?
        options[:json] ? print_setup_json(directory) : print_setup_text(directory)
      end

      private

      def setup_parser(options, request)
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz setup [--workspace PATH] [--chat PROVIDER/MODEL] ' \
                          '[--transcription PROVIDER/MODEL] [--vision PROVIDER/MODEL]'
          parser.on('--workspace PATH', 'The folder the agent works in (a new runtime defaults to --root)') do |path|
            request[:workspace] = File.expand_path(path)
          end
          MODEL_ROLES.each { |role| model_option(parser, request[:models], role) }
          KEYED_ROLES.each { |role| key_options(parser, request[:models], role) }
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
