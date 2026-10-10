# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Telegram
    # `tamoz channel add telegram` and its checks: pair a bot with its owner, then prove the token with real calls.
    class Setup
      include Comms::ChannelSetup

      TOKEN = 'TAMOZ_TELEGRAM_BOT_TOKEN'
      PAIRING_WAIT_S = 120
      REFUSED = "Telegram refused the bot token in #{TOKEN}; copy it again from @BotFather".freeze

      def initialize(client_factory: nil)
        @channel = Channel.new(client_factory:)
      end

      def summary = 'Pair a Telegram bot with you'

      def env_names = [TOKEN, Channel::ORIGIN]

      # rubocop:disable Lint/UnusedMethodArgument
      def add(existing:, argv:, env:, state_dir:, terminal:)
        request = options(argv, terminal)
        return unless request

        client = client_for(env)
        bot = identify_bot(client, existing, terminal)
        owner = paired_owner(request, client, bot, terminal)
        terminal.say 'Telegram is paired.'
        entry(existing, bot, owner)
      rescue Comms::SetupError
        raise
      rescue Comms::ValidationError => e
        raise Comms::SetupError, e.message
      rescue Comms::AuthenticationError
        raise Comms::SetupError, REFUSED
      rescue Comms::CommsError => e
        raise Comms::SetupError, "Telegram could not be reached (#{e.class.name.split('::').last}); check the token " \
                                 'and network'
      end

      # One real getMe, so a revoked token is a named problem now, not a dead gateway.
      def check(descriptor:, env:, state_dir:, poller_free:)
        name = descriptor.transport.fetch(:credential_ref).fetch(:name)
        if env[name].to_s.empty?
          return [["token #{name}",
                   "credential #{name} is not set; set #{name} in the environment or the env file"]]
        end

        client = @channel.client(env.fetch(name), env)
        [["token #{name}", true], ['bot id', bot_id_check(client, descriptor)], ['webhook', webhook_check(client)]]
      rescue Comms::AuthenticationError
        [["token #{name}", REFUSED]]
      rescue Comms::ValidationError => e
        [['bot api origin', e.message]]
      rescue Comms::CommsError
        [['bot id', 'Telegram could not be reached; check the network and retry']]
      end
      # rubocop:enable Lint/UnusedMethodArgument

      private

      def options(argv, terminal)
        owner = nil
        OptionParser.new do |opts|
          opts.banner = 'Usage: tamoz channel add telegram [--owner TELEGRAM_USER_ID] [--env-file PATH]'
          opts.separator '    --env-file PATH                  Read KEY=value secrets from this file'
          opts.on('--owner ID', Integer, 'Your Telegram user id, instead of pairing by message') { owner = _1 }
          opts.on('-h', '--help', 'Show this help') do
            terminal.say(opts.help)
            return nil
          end
        end.parse!(argv)
        { owner: }
      rescue OptionParser::ParseError => e
        raise Comms::SetupError, e.message
      end

      def client_for(env)
        raise Comms::SetupError, "set #{TOKEN} to the token @BotFather gave you" if env[TOKEN].to_s.empty?

        @channel.client(env.fetch(TOKEN), env)
      end

      def identify_bot(client, existing, terminal)
        bot = client.call('getMe', {}, idempotent: true)
        terminal.say "Bot: @#{bot.fetch('username')}"
        refuse_other_bot(existing, bot)
        bot
      end

      def paired_owner(request, client, bot, terminal)
        owner, offset = request[:owner] ? [request[:owner], nil] : pair_owner(client, bot, terminal)
        confirm_backlog(client, offset)
        owner
      end

      def refuse_other_bot(existing, bot)
        pinned = existing.to_h['expected_bot_id'].to_i
        return if pinned.zero? || pinned == bot.fetch('id')

        raise Comms::SetupError, "this runtime already serves @#{existing['bot_username']}; one bot per runtime"
      end

      # The first private message proves who the owner is; the operator confirms it at the terminal.
      def pair_owner(client, bot, terminal)
        terminal.say "Now send any message to @#{bot.fetch('username')} on Telegram (waiting #{PAIRING_WAIT_S}s)..."
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PAIRING_WAIT_S
        offset = nil
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          client.call('getUpdates', { 'timeout' => 10, 'offset' => offset }.compact, idempotent: true).each do |update|
            offset = update.fetch('update_id') + 1
            message = update['message']
            return [confirm_owner(client, message, terminal), offset] if message && message.dig('chat',
                                                                                                'type') == 'private'
          end
        end
        raise Comms::SetupError, 'no message arrived; run `tamoz channel add telegram` again, or pass --owner with ' \
                                 'your user id'
      end

      def confirm_owner(client, message, terminal)
        sender = message.fetch('from')
        name = [sender['first_name'], sender['username'] && "@#{sender['username']}"].compact.join(' ')
        raise Comms::SetupError, 'not paired' unless
          terminal.confirm("Message from #{name} (id #{sender.fetch('id')}). Is that you?")

        client.call('sendMessage', { 'chat_id' => message.dig('chat', 'id'),
                                     'text' => "Hi #{sender['first_name']}! I'm paired with you. I'll answer here " \
                                               'once the bot is started.' })
        sender.fetch('id')
      end

      # Everything sent before the bot was paired is confirmed now, so the gateway never answers it later: each
      # call confirms what lies below its offset, until a call past the newest update returns nothing.
      def confirm_backlog(client, offset)
        loop do
          updates = client.call('getUpdates', { 'offset' => offset, 'timeout' => 0 }.compact, idempotent: true)
          return if updates.empty?

          offset = updates.map { |update| update.fetch('update_id') }.max + 1
        end
      end

      def entry(existing, bot, owner)
        allowed = Array(existing&.dig('admission', 'correspondents')) | ["telegram:user:#{owner}"]
        { 'kind' => 'telegram', 'enabled' => true, 'credential_ref' => { 'kind' => 'env', 'name' => TOKEN },
          'expected_bot_id' => bot.fetch('id'), 'bot_username' => bot.fetch('username'),
          # A short poll lets Ctrl-C stop the gateway quickly.
          'transport' => { 'poll_timeout_s' => 10 },
          'admission' => { 'direct' => 'allowlist', 'correspondents' => allowed },
          'approvals' => { 'mode' => 'deny_only', 'prompt_ttl_s' => 900 } }
      end

      def bot_id_check(client, descriptor)
        actual = client.call('getMe', {}, idempotent: true).fetch('id')
        expected = descriptor.identity.fetch(:expected_bot_id)
        return true if actual == expected

        "token authenticates bot #{actual}, config expects #{expected} (a token swap is a different surface)"
      end

      def webhook_check(client)
        url = client.call('getWebhookInfo', {}, idempotent: true).fetch('url').to_s
        url.empty? || "a webhook is set at #{url}; long polling will conflict"
      end
    end
  end
end
