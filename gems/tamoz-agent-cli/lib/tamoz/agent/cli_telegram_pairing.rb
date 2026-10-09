# frozen_string_literal: true

module Tamoz
  module Agent
    # Who owns a Telegram bot: the first private sender the operator confirms at the terminal.
    module CLITelegramPairing
      PAIRING_WAIT_S = 120

      private

      # The first private message proves who the owner is; the operator confirms it at the terminal.
      def pair_owner(client, bot)
        @out.puts "Now send any message to @#{bot.fetch('username')} on Telegram (waiting #{PAIRING_WAIT_S}s)..."
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PAIRING_WAIT_S
        offset = nil
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          updates = client.call('getUpdates', { 'timeout' => 10, 'offset' => offset }.compact, idempotent: true)
          updates.each do |update|
            offset = update.fetch('update_id') + 1
            message = update['message']
            next unless message && message.dig('chat', 'type') == 'private'

            return confirm_owner(client, message, offset)
          end
        end
        telegram_fail('no message arrived; run `tamoz channel add telegram` again, or pass --owner with your user id')
        nil
      end

      def confirm_owner(client, message, offset)
        sender = message.fetch('from')
        name = [sender['first_name'], sender['username'] && "@#{sender['username']}"].compact.join(' ')
        @out.print "Message from #{name} (id #{sender.fetch('id')}). Is that you? [y/N] "
        @out.flush
        return telegram_fail('not paired') && nil unless @input.gets.to_s.strip.casecmp?('y')

        # The pairing message is consumed here, so the running bot does not answer it.
        client.call('getUpdates', { 'offset' => offset, 'timeout' => 0 }, idempotent: true)
        client.call('sendMessage', { 'chat_id' => message.dig('chat', 'id'),
                                     'text' => "Hi #{sender['first_name']}! I'm paired with you. I'll answer " \
                                               'here once the bot is started.' })
        sender.fetch('id')
      end
    end
  end
end
