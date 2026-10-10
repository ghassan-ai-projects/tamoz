# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Agent
    # `tamoz start`: each channel of one runtime through its own gateway, and one worker, checked and then supervised.
    module CLIStartCommands
      RUNTIME_IN_WORKSPACE = 'the runtime folder is inside the workspace, so the agent could read its secrets; ' \
                             'choose another --runtime-dir'
      NO_CHANNELS = 'the runtime has no channel; add one with `tamoz channel add telegram` or `tamoz channel add talk`'
      NO_CHAT_MODEL = 'the runtime names no chat model; set one with `tamoz setup --chat PROVIDER/MODEL`'

      def cmd_start(options, argv)
        request = start_request(argv)
        problem = env_file_problem(request[:env_file])
        return start_fail(problem) if problem

        base = start_env(request)
        directory = RuntimeDirectory.resolve(path: runtime_dir_path(options), env: base)
        problem = start_problem(options, directory, base)
        return start_fail(problem) if problem

        base = base.merge(talk_token_env(directory))
        announce(directory, base)
        warn_voice(directory, base) if talk_channel(directory)
        serve(directory, base)
      end

      private

      def start_request(argv)
        request = { env_file: nil, host: nil }
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz start [--env-file PATH] [--host ADDRESS]'
          parser.on('--env-file PATH', 'Read KEY=value secrets from this file') { |path| request[:env_file] = path }
          parser.on('--host ADDRESS', 'Address the talk page listens on (default 127.0.0.1)') do |address|
            request[:host] = address
          end
          help_option(parser)
        end.parse!(argv)
        request
      end

      def start_env(request)
        base = env_with_file(request[:env_file])
        base.merge('TAMOZ_TALK_HOST' => request[:host] || base['TAMOZ_TALK_HOST'] || '127.0.0.1')
      end

      def start_problem(options, directory, base)
        runtime_problem(directory) || service_problem(directory) ||
          enabled_channels(directory).each_value.lazy.filter_map do |entry|
            channel_problem(options, directory, entry, base)
          end.first ||
          models_problem(directory, base)
      end

      def runtime_problem(directory)
        return RUNTIME_IN_WORKSPACE if directory.inside_workspace?
        return NO_CHANNELS if enabled_channels(directory).empty?

        NO_CHAT_MODEL unless directory.models['chat']
      end

      def enabled_channels(directory) = directory.channels.reject { |_surface, entry| entry['enabled'] == false }

      def talk_channel(directory) = enabled_channels(directory).values.find { |entry| entry['kind'] == 'talk' }

      def channel_problem(options, directory, entry, base)
        already_running(options, entry) ||
          (entry['kind'] == 'talk' ? talk_problem(directory, entry, base) : telegram_problem(base))
      end

      def models_problem(directory, base)
        chat_problem(directory, base) || (talk_channel(directory) && talk_models_problem(directory, base)) ||
          transcription_problem(directory, base)
      end

      def talk_token_env(directory)
        talk_channel(directory) ? { CLITalkCommands::TOKEN_ENV => talk_access_token(directory) } : {}
      end

      def announce(directory, base)
        chat = directory.models['chat']
        channels = enabled_channels(directory).keys.join(', ')
        @out.puts "Tamoz is starting #{channels} with #{chat.provider}/#{chat.model}."
        talk = talk_channel(directory)
        announce_talk(talk, base) if talk
      end

      def serve(directory, base)
        logs = File.join(directory.path, 'logs')
        Tamoz::Core::PrivateDirectory.secure(logs)
        children = spawn_children(directory, base.merge(child_runtime_env), logs)
        @out.puts "Running. Ctrl-C stops it. Logs: #{logs}"
        @out.flush
        supervise(children, logs)
      end

      def spawn_children(directory, base, logs)
        children = {}
        child_plan(directory, base).each do |name, (env, args)|
          children[name] = spawn_child(name, env, ['--runtime-dir', directory.path, *args], logs)
        end
        children
      rescue StandardError
        children.each_value { |pid| stop_child(pid) }
        raise
      end

      def child_plan(directory, base)
        gateways = enabled_channels(directory).keys.to_h do |surface|
          ["#{surface}-gateway",
           [ChildEnvironments.gateway_env(base, directory:, surface:), ['comms', 'serve', '--surface', surface]]]
        end
        gateways.merge('worker' => [ChildEnvironments.worker_env(base, directory:), %w[--work-routing worker --json]])
      end

      def start_fail(message)
        @err.puts "tamoz: #{message}"
        1
      end
    end
  end
end
