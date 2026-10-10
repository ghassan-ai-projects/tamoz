# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Agent
    # `tamoz channel add KIND`: a way in to the runtime `tamoz setup` made, serving its one chat profile.
    module CLIChannelCommands
      RUNTIME_IN_WORKSPACE = "the runtime folder is inside the workspace, so the agent could read the channel's " \
                             'secrets; choose another --runtime-dir'

      # What a channel's setup may say and ask at the terminal.
      Terminal = Struct.new(:out, :err, :input) do
        def say(text) = out.puts(text)

        def warn(text) = err.puts("tamoz: #{text}")

        def confirm(question) # rubocop:disable Naming/PredicateMethod -- interface name used by channel adapters
          out.print "#{question} [y/N] "
          out.flush
          input.gets.to_s.strip.casecmp?('y')
        end
      end

      def cmd_channel(options, argv)
        verb, kind, *rest = argv
        return channel_usage if %w[-h --help].include?(verb)
        return channel_usage(1) if verb.nil?
        unless verb == 'add' && channel_kinds.key?(kind)
          raise OptionParser::InvalidArgument, "usage: tamoz channel add #{channel_kinds.keys.join('|')}"
        end
        return channel_help(kind, rest) if rest.intersect?(%w[-h --help])

        channel_add(options, kind, rest)
      rescue Comms::ValidationError, Comms::SetupError, CLICommsShared::MissingAdapterError => e
        @err.puts "tamoz: #{e.message}"
        1
      end

      private

      def channel_usage(status = 0)
        @out.puts "Usage: tamoz channel add #{channel_kinds.keys.join('|')}"
        channel_kinds.each do |kind, channel|
          purpose = begin
            channel.setup.summary
          rescue CLICommsShared::MissingAdapterError => e
            e.message
          end
          @out.puts format('  add %-9<kind>s %<purpose>s', kind:, purpose:)
        end
        status
      end

      # A setup prints its own options and stops before it touches anything.
      def channel_help(kind, argv)
        channel_kind(kind).setup.add(existing: nil, argv:, env: {}, state_dir: nil,
                                     terminal: Terminal.new(@out, @err, @input))
        0
      end

      def channel_add(options, kind, argv)
        env_file, argv = env_file_option(argv)
        problem = env_file_problem(env_file)
        return channel_fail(problem) if problem

        directory = channel_runtime(options)
        return channel_fail(RUNTIME_IN_WORKSPACE) if directory.inside_workspace?

        surface = directory.channels.find { |_id, entry| entry['kind'] == kind }&.first || kind
        entry = add_channel_entry(kind, directory, surface, argv, env_file)
        return 0 unless entry

        save_channel(directory, surface, entry)
        report_channel(directory, surface)
      end

      def add_channel_entry(kind, directory, surface, argv, env_file)
        setup = channel_kind(kind).setup
        setup.add(existing: directory.channels[surface], argv:,
                  env: env_with_file(env_file).slice(*setup.env_names),
                  state_dir: channel_state_dir(directory, surface), terminal: Terminal.new(@out, @err, @input))
      end

      def env_file_option(argv)
        rest = argv.dup
        index = rest.index { |arg| arg == '--env-file' || arg.start_with?('--env-file=') }
        return [nil, rest] unless index

        flag = rest.delete_at(index)
        [flag.include?('=') ? flag.split('=', 2).last : rest.delete_at(index), rest]
      end

      def channel_runtime(options)
        directory = RuntimeDirectory.resolve(path: runtime_dir_path(options), env: @env)
        return directory if directory.chat_profile?

        raise RuntimeDirectory::Error, "#{directory.path} has no chat profile yet; run 'tamoz setup' first"
      end

      # A revision bump is what makes a running gateway deploy a changed surface; an unchanged one is left alone.
      def save_channel(directory, surface, entry)
        existing = directory.channels[surface]
        entry = entry.merge('profile' => directory.chat_profile_id, 'revision' => existing&.fetch('revision') || 1)
        return if entry == existing

        entry['revision'] += 1 if existing
        build_descriptor(surface, entry, directory)
        RuntimeDirectory.put_channel!(directory.path, surface, entry, env: @env)
      end

      def report_channel(directory, surface)
        @out.puts "Start it with:\n  tamoz --runtime-dir #{directory.path} start --env-file .env"
        @out.puts "  (if `tamoz` is not on your PATH: bundle exec tamoz --runtime-dir #{directory.path} start)"
        @out.puts "Channel #{surface}, workspace #{directory.workspace_root}."
        0
      end

      def channel_fail(message)
        @err.puts "tamoz: #{message}"
        1
      end
    end
  end
end
