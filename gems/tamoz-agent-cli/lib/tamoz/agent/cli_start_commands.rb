# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Agent
    # `tamoz start`: each channel of one runtime through its own gateway, and one worker, checked and then supervised.
    module CLIStartCommands
      RUNTIME_IN_WORKSPACE = 'the runtime folder is inside the workspace, so the agent could read its secrets; ' \
                             'choose another --runtime-dir'
      NO_CHAT_MODEL = 'the runtime names no chat model; set one with `tamoz setup --chat PROVIDER/MODEL`'

      def cmd_start(options, argv)
        request = start_request(argv)
        problem = env_file_problem(request[:env_file])
        return start_fail(problem) if problem

        base = env_with_file(request[:env_file])
        directory = RuntimeDirectory.resolve(path: runtime_dir_path(options), env: base)
        problem = start_problem(options, directory, base)
        return start_fail(problem) if problem

        announce(directory, base)
        warn_voice(directory, base) if speaking_channel?(directory)
        serve(directory, base)
      end

      private

      def start_request(argv)
        request = { env_file: nil }
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz start [--env-file PATH]'
          parser.on('--env-file PATH', 'Read KEY=value secrets from this file') { |path| request[:env_file] = path }
          help_option(parser)
        end.parse!(argv)
        request
      end

      def start_problem(options, directory, base)
        runtime_problem(directory) || service_problem(directory) ||
          enabled_channels(directory).each_key.lazy.filter_map do |surface|
            channel_problem(options, directory, surface, base)
          end.first ||
          models_problem(directory, base)
      end

      def runtime_problem(directory)
        return RUNTIME_IN_WORKSPACE if directory.inside_workspace?
        return no_channels if enabled_channels(directory).empty?

        NO_CHAT_MODEL unless directory.models['chat']
      end

      def no_channels
        "the runtime has no channel; add one with #{channel_kinds.keys.map { "`tamoz channel add #{_1}`" }
                                                                .join(' or ')}"
      end

      def enabled_channels(directory) = directory.channels.reject { |_surface, entry| entry['enabled'] == false }

      def descriptors(directory)
        enabled_channels(directory).map { |surface, entry| build_descriptor(surface, entry, directory) }
      end

      def speaking_channel?(directory) = descriptors(directory).any?(&:speech?)

      def channel_problem(options, directory, surface, base)
        descriptor = build_descriptor(surface, directory.channels.fetch(surface), directory)
        already_running(options, descriptor) || first_failure(directory, descriptor, base)
      rescue Comms::ValidationError, CLICommsShared::MissingAdapterError => e
        e.message
      end

      def first_failure(directory, descriptor, base)
        kind = channel_kind(descriptor.kind)
        state_dir = channel_state_dir(directory, descriptor.surface_id)
        env = kind.setup.gateway_env(descriptor:, env: channel_env(kind, base), state_dir:)
        kind.setup.check(descriptor:, env:, state_dir:, poller_free: true).find { |_name, detail| detail != true }&.last
      end

      def models_problem(directory, base)
        chat_problem(directory, base) || (speaking_channel?(directory) && speech_models_problem(directory, base)) ||
          channel_named_model_key(directory) || transcription_problem(directory, base)
      end

      def announce(directory, base)
        chat = directory.models['chat']
        channels = enabled_channels(directory).keys.join(', ')
        @out.puts "Tamoz is starting #{channels} with #{chat.provider}/#{chat.model}."
        terminal = CLIChannelCommands::Terminal.new(@out, @err, @input)
        descriptors(directory).each do |descriptor|
          kind = channel_kind(descriptor.kind)
          env = gateway_vars(directory, descriptor, base)
          kind.setup.announce(descriptor:, env:, terminal:)
        end
      end

      def serve(directory, base)
        logs = File.join(directory.path, 'logs')
        Tamoz::Core::PrivateDirectory.secure(logs)
        children = spawn_children(directory, base.merge(child_runtime_env), logs)
        @out.puts "Running. Ctrl-C stops it. Logs: #{logs}"
        @out.flush
        supervise(children, logs)
      end

      def start_fail(message)
        @err.puts "tamoz: #{message}"
        1
      end
    end
  end
end
