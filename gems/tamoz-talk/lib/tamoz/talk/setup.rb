# frozen_string_literal: true

require 'optparse'
require 'securerandom'
require 'socket'

module Tamoz
  module Talk
    # `tamoz channel add talk` and its checks: the page's port and hosts, and the private link's token.
    class Setup
      include Comms::ChannelSetup

      TOKEN = 'TAMOZ_TALK_TOKEN'
      TOKEN_FILE = 'token'
      TOKEN_MIN = 32
      DEFAULT_PORT = 8787

      def summary = 'Add the browser talk page and its private link'

      def env_names = [TOKEN, Channel::TRACE]

      def add(existing:, argv:, env:, state_dir:, terminal:) # rubocop:disable Lint/UnusedMethodArgument
        request = options(argv, terminal)
        return unless request

        entry = entry(existing, **request.except(:rotate))
        token = token(state_dir, rotate: request.fetch(:rotate))
        terminal.say "Talk channel ready. The link `start` prints carries a private token (#{token.length} " \
                     'characters); whoever has it can talk to Tamoz and approve its changes.'
        terminal.say 'A running Tamoz keeps accepting the old link until it is restarted.' if request.fetch(:rotate)
        entry
      end

      def check(descriptor:, env:, state_dir:, poller_free:) # rubocop:disable Lint/UnusedMethodArgument
        port = descriptor.settings.fetch(:port)
        token = stored_token(state_dir).length >= TOKEN_MIN || 'the talk token is missing or damaged; ' \
                                                               'run `tamoz channel add talk`'
        [['token', token], ["port #{port}", poller_free ? port_free(Channel.host(descriptor.settings), port) : true]]
      end

      def announce(descriptor:, env:, terminal:)
        settings = descriptor.settings
        host = Channel.host(settings)
        unless Channel::LOOPBACK.include?(host)
          terminal.warn "#{host} is not loopback; the token crosses the network in clear text unless a TLS proxy " \
                        'fronts it'
        end
        token = env.fetch(TOKEN)
        terminal.say "Talk to Tamoz: http://#{Channel::LOOPBACK.include?(host) ? '127.0.0.1' : host}:" \
                     "#{settings.fetch(:port)}/#token=#{token}"
        Array(settings[:allow_hosts]).each { |name| terminal.say "  or https://#{name}/#token=#{token}" }
        terminal.say 'Whoever has this link can talk to Tamoz and approve its changes. Rotate it with ' \
                     '`tamoz channel add talk --rotate-token`.'
      end

      def gateway_env(env:, state_dir:, **) = env.slice(*env_names).merge(TOKEN => stored_token(state_dir))

      private

      def options(argv, terminal)
        request = { port: nil, hosts: [], host: nil, rotate: false }
        catch(:help) do
          option_parser(request, terminal).parse!(argv)
          request
        end
      rescue OptionParser::ParseError => e
        raise Comms::SetupError, e.message
      end

      def option_parser(request, terminal)
        OptionParser.new do |opts|
          opts.banner = 'Usage: tamoz channel add talk [--port N] [--host ADDRESS] [--allow-host NAME] ' \
                        '[--rotate-token] [--env-file PATH]'
          opts.on('--port N', Integer, "Local port for the talk page (default #{DEFAULT_PORT})") { request[:port] = _1 }
          opts.on('--host ADDRESS', "Address the page listens on (default #{Channel::DEFAULT_HOST})") do |address|
            request[:host] = address
          end
          opts.on('--allow-host NAME', 'A host name the page is reached by, e.g. a tailscale serve name') do |name|
            request[:hosts] << name.downcase
          end
          opts.on('--rotate-token', 'Replace the access link; old links stop working') { request[:rotate] = true }
          opts.on('-h', '--help', 'Show this help') do
            terminal.say(opts.help)
            throw :help
          end
        end
      end

      def entry(existing, port:, hosts:, host:)
        settings = existing&.fetch('settings', nil) || {}
        { 'kind' => 'talk', 'enabled' => true, 'credential_ref' => { 'kind' => 'env', 'name' => TOKEN },
          'expected_bot_id' => existing&.fetch('expected_bot_id') ||
            (SecureRandom.random_number(9 * (10**11)) + (10**11)),
          'transport' => { 'poll_timeout_s' => 10 },
          'settings' => { 'port' => port || settings['port'] || DEFAULT_PORT,
                          'allow_hosts' => Array(settings['allow_hosts']) | hosts,
                          'host' => host || settings['host'] || Channel::DEFAULT_HOST },
          'rendering' => { 'speech' => true },
          'admission' => { 'direct' => 'allowlist', 'correspondents' => ['talk:user:1'] },
          'approvals' => { 'mode' => 'deny_only', 'prompt_ttl_s' => 900 },
          'limits' => { 'per_chat_messages_per_s' => 20.0, 'global_messages_per_s' => 50.0 } }
      end

      def token(state_dir, rotate:)
        kept = stored_token(state_dir)
        return kept if kept.length >= TOKEN_MIN && !rotate

        SecureRandom.urlsafe_base64(32).tap do |token|
          Core::AtomicFile.replace(File.join(state_dir, TOKEN_FILE), "#{token}\n", mode: 0o600)
        end
      end

      def stored_token(state_dir)
        path = File.join(state_dir, TOKEN_FILE)
        File.exist?(path) ? File.read(path).strip : ''
      end

      def port_free(host, port)
        TCPServer.new(host, port).close
        true
      rescue SystemCallError => e
        "the talk page cannot listen on #{host}:#{port} (#{e.class.name.split('::').last}); is another program " \
        'using it? Pick another with `tamoz channel add talk --port N`'
      end
    end
  end
end
