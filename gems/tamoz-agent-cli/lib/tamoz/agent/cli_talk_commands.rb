# frozen_string_literal: true

require 'optparse'
require 'securerandom'
require 'socket'

module Tamoz
  module Agent
    # `tamoz channel add talk` writes the browser talk page; `start` checks its token, host and port.
    module CLITalkCommands
      SURFACE = 'talk'
      TOKEN_ENV = 'TAMOZ_TALK_TOKEN'
      DEFAULT_PORT = 8787
      TOKEN_MIN = 32
      LOOPBACK = %w[127.0.0.1 localhost ::1].freeze
      RUNTIME_IN_WORKSPACE = 'the runtime folder is inside the workspace, so the agent could read the talk token; ' \
                             'choose another --runtime-dir'

      private

      def channel_add_talk(options, argv)
        request = talk_channel_options(argv)
        directory = channel_runtime(options)
        return talk_fail(RUNTIME_IN_WORKSPACE) if directory.inside_workspace?

        save_channel(directory, SURFACE, talk_entry(directory.channels[SURFACE], **request.except(:rotate)))
        token = talk_token(directory, rotate: request.fetch(:rotate))
        @out.puts "Talk channel ready. Start it with:\n  tamoz --runtime-dir #{directory.path} start --env-file .env"
        @out.puts "The link it prints carries a private token (#{token.length} characters); whoever has it can talk to " \
                  'Tamoz and approve its changes.'
        @out.puts 'A running Tamoz keeps accepting the old link until it is restarted.' if request.fetch(:rotate)
        0
      end

      def talk_channel_options(argv)
        request = { port: nil, hosts: [], rotate: false }
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz channel add talk [--port N] [--allow-host NAME] [--rotate-token]'
          parser.on('--port N', Integer, "Local port for the talk page (default #{DEFAULT_PORT})") do |value|
            request[:port] = value
          end
          parser.on('--allow-host NAME', 'A host name the page is reached by, e.g. a tailscale serve name') do |name|
            request[:hosts] << name.downcase
          end
          parser.on('--rotate-token', 'Replace the access link; old links stop working') { request[:rotate] = true }
          help_option(parser)
        end.parse!(argv)
        request
      end

      def talk_entry(existing, port:, hosts:)
        talk = existing&.fetch('talk', nil) || {}
        { 'kind' => 'talk', 'enabled' => true, 'credential_ref' => { 'kind' => 'env', 'name' => TOKEN_ENV },
          'expected_bot_id' => existing&.fetch('expected_bot_id') ||
            (SecureRandom.random_number(9 * (10**11)) + (10**11)),
          'transport' => { 'poll_timeout_s' => 10 },
          'talk' => { 'port' => port || talk['port'] || DEFAULT_PORT,
                      'allow_hosts' => Array(talk['allow_hosts']) | hosts },
          'admission' => { 'direct' => 'allowlist', 'correspondents' => ['talk:user:1'] },
          'approvals' => { 'mode' => 'deny_only', 'prompt_ttl_s' => 900 },
          'limits' => { 'per_chat_messages_per_s' => 20.0, 'global_messages_per_s' => 50.0 } }
      end

      def talk_token(directory, rotate:)
        folder = File.join(directory.path, 'talk')
        Tamoz::Core::PrivateDirectory.secure(folder)
        path = File.join(folder, 'token')
        kept = File.exist?(path) ? File.read(path).strip : ''
        return kept if kept.length >= TOKEN_MIN && !rotate

        SecureRandom.urlsafe_base64(32).tap { |token| write_private(path, "#{token}\n") }
      end

      def port_problem(host, port)
        TCPServer.new(host, port).close
        nil
      rescue SystemCallError => e
        "the talk page cannot listen on #{host}:#{port} (#{e.class.name.split('::').last}); is another program " \
        'using it? Pick another with `tamoz channel add talk --port N`'
      end

      def print_talk_link(entry, host, token)
        port = entry.dig('talk', 'port') || DEFAULT_PORT
        local = LOOPBACK.include?(host) ? '127.0.0.1' : host
        @out.puts "Talk to Tamoz: http://#{local}:#{port}/#token=#{token}"
        Array(entry.dig('talk', 'allow_hosts')).each { |name| @out.puts "  or https://#{name}/#token=#{token}" }
        @out.puts 'Whoever has this link can talk to Tamoz and approve its changes. Rotate it with ' \
                  '`tamoz channel add talk --rotate-token`.'
      end

      def talk_problem(directory, entry, base)
        host = base.fetch('TAMOZ_TALK_HOST')
        if !LOOPBACK.include?(host) && Array(entry.dig('talk', 'allow_hosts')).empty?
          return "listening on #{host} needs `tamoz channel add talk --allow-host NAME` for the name the page is " \
                 'reached by'
        end
        if talk_access_token(directory).length < TOKEN_MIN
          return 'the talk token is missing or damaged; run `tamoz channel add talk`'
        end

        port_problem(host, entry.dig('talk', 'port') || DEFAULT_PORT)
      end

      def talk_access_token(directory)
        path = File.join(directory.path, 'talk', 'token')
        File.exist?(path) ? File.read(path).strip : ''
      end

      def announce_talk(entry, base)
        host = base.fetch('TAMOZ_TALK_HOST')
        unless LOOPBACK.include?(host)
          @err.puts "tamoz: #{host} is not loopback; the token crosses the network in clear text unless a TLS proxy " \
                    'fronts it'
        end
        print_talk_link(entry, host, base.fetch(TOKEN_ENV))
      end

      def talk_fail(message)
        @err.puts "tamoz: #{message}"
        1
      end
    end
  end
end
