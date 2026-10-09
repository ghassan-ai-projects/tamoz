# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Agent
    # `tamoz channel add telegram` pairs a bot with its owner; `start` checks the token with one real call.
    module CLITelegramCommands
      SURFACE = 'telegram'
      TOKEN_ENV = 'TAMOZ_TELEGRAM_BOT_TOKEN'

      private

      def channel_add_telegram(options, argv)
        owner, env_file = telegram_channel_options(argv)
        problem = telegram_token_problem(env_file)
        return telegram_fail(problem) if problem

        directory = channel_runtime(options)
        surface = pair_telegram(directory, comms_client_factory.call(env_with_file(env_file).fetch(TOKEN_ENV)), owner)
        surface ? report_telegram_channel(directory, surface) : 1
      rescue Comms::AuthenticationError
        telegram_fail("Telegram refused the bot token in #{TOKEN_ENV}; copy it again from @BotFather")
      rescue Comms::CommsError => e
        telegram_fail("Telegram could not be reached (#{e.class.name.split('::').last}); check the token and network")
      end

      def telegram_channel_options(argv)
        owner = env_file = nil
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz channel add telegram [--owner TELEGRAM_USER_ID] [--env-file PATH]'
          parser.on('--owner ID', Integer, 'Your Telegram user id, instead of pairing by message') { |id| owner = id }
          parser.on('--env-file PATH', 'Read KEY=value secrets from this file') { |path| env_file = path }
          help_option(parser)
        end.parse!(argv)
        [owner, env_file]
      end

      def telegram_token_problem(env_file)
        env_file_problem(env_file) ||
          ("set #{TOKEN_ENV} to the token @BotFather gave you" if env_with_file(env_file)[TOKEN_ENV].to_s.empty?)
      end

      def pair_telegram(directory, client, owner)
        bot = client.call('getMe', {}, idempotent: true)
        @out.puts "Bot: @#{bot.fetch('username')}"
        if (paired = other_bot(directory, bot))
          telegram_fail("this runtime already serves @#{paired['bot_username']}; one bot per runtime")
          return
        end

        owner ||= pair_owner(client, bot)
        save_telegram_channel(directory, bot:, owner:) if owner
      end

      def other_bot(directory, bot)
        directory.channels.values.find do |entry|
          pinned = entry['expected_bot_id'].to_i
          entry['kind'] == 'telegram' && !pinned.zero? && pinned != bot.fetch('id')
        end
      end

      def report_telegram_channel(directory, surface)
        @out.puts "Telegram is paired. Start it with:\n  tamoz --runtime-dir #{directory.path} start --env-file .env"
        @out.puts "  (if `tamoz` is not on your PATH: bundle exec tamoz --runtime-dir #{directory.path} start)"
        @out.puts "Channel #{surface}, workspace #{directory.workspace_root}."
        0
      end

      def save_telegram_channel(directory, bot:, owner:)
        surface, existing = telegram_channel(directory.channels, bot)
        allowed = Array(existing&.dig('admission', 'correspondents')) | ["telegram:user:#{owner}"]
        save_channel(directory, surface, {
                       'kind' => 'telegram', 'enabled' => true,
                       'credential_ref' => { 'kind' => 'env', 'name' => TOKEN_ENV },
                       'expected_bot_id' => bot.fetch('id'), 'bot_username' => bot.fetch('username'),
                       # A short poll lets Ctrl-C stop the gateway quickly.
                       'transport' => { 'poll_timeout_s' => 10 },
                       'admission' => { 'direct' => 'allowlist', 'correspondents' => allowed },
                       'approvals' => { 'mode' => 'deny_only', 'prompt_ttl_s' => 900 }
                     })
        surface
      end

      # Reuse the channel pinned to this bot; else adopt a Telegram channel that
      # was created but never pinned (expected_bot_id 0), the state a half-finished
      # setup leaves, so a second run repairs it instead of adding a dead surface.
      def telegram_channel(channels, bot)
        pinned = channels.find { |_id, entry| entry['expected_bot_id'] == bot.fetch('id') }
        return pinned if pinned

        channels.find { |_id, entry| entry['kind'] == 'telegram' && entry['expected_bot_id'].to_i.zero? } ||
          [SURFACE, nil]
      end

      def write_private(path, text)
        Tamoz::Core::AtomicFile.replace(path, text, mode: 0o600)
      end

      # One real getMe, so a revoked token is a named error now, not a dead child.
      def telegram_problem(base)
        return "set #{TOKEN_ENV} (or pass --env-file)" if base[TOKEN_ENV].to_s.empty?

        token_problem(base)
      end

      def token_problem(base)
        comms_client_factory.call(base.fetch(TOKEN_ENV)).call('getMe', {}, idempotent: true)
        nil
      rescue Comms::AuthenticationError
        "Telegram refused the bot token in #{TOKEN_ENV}; copy it again from @BotFather"
      rescue Comms::CommsError
        'Telegram could not be reached; check the network and retry'
      rescue CLICommsShared::MissingAdapterError => e
        e.message
      end

      def telegram_fail(message)
        @err.puts "tamoz: #{message}"
        1
      end
    end
  end
end
