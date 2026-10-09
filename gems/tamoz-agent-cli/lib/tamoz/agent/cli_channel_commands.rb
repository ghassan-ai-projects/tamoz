# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Agent
    # `tamoz channel add telegram|talk`: a way in to the runtime `tamoz setup` made, serving its one chat profile.
    module CLIChannelCommands
      CHANNELS = { 'telegram' => 'Pair a Telegram bot with you',
                   'talk' => 'Add the browser talk page and its private link' }.freeze

      def cmd_channel(options, argv)
        verb, kind, *rest = argv
        case [verb, kind]
        in ['add', 'telegram'] then channel_add_telegram(options, rest)
        in ['add', 'talk'] then channel_add_talk(options, rest)
        in ['-h' | '--help', _] then channel_usage
        in [nil, _] then channel_usage(1)
        else raise OptionParser::InvalidArgument, "usage: tamoz channel add #{CHANNELS.keys.join('|')}"
        end
      rescue Comms::ValidationError => e
        @err.puts "tamoz: #{e.message}"
        1
      end

      private

      def channel_usage(status = 0)
        @out.puts "Usage: tamoz channel add #{CHANNELS.keys.join('|')}"
        CHANNELS.each { |kind, purpose| @out.puts format('  add %-9<kind>s %<purpose>s', kind:, purpose:) }
        status
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
    end
  end
end
