# frozen_string_literal: true

require 'json'
require 'optparse'
require 'psych'
require 'securerandom'
require 'socket'

module Tamoz
  module Agent
    # `tamoz channel add talk` and `tamoz talk start`: a browser voice chat from a model key, a speech key and a link.
    # rubocop:disable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength -- two guided operator flows.
    module CLITalkCommands
      SURFACE = 'talk'
      TOKEN_ENV = 'TAMOZ_TALK_TOKEN'
      DEFAULT_PORT = 8787
      TOKEN_MIN = 32
      LOOPBACK = %w[127.0.0.1 localhost ::1].freeze
      NO_CHANNEL = 'no talk channel is configured; run `tamoz channel add talk` first'
      RUNTIME_IN_WORKSPACE = 'the runtime folder is inside the workspace, so the agent could read the talk token; ' \
                             'choose another --runtime-dir'

      def cmd_talk(options, argv)
        case argv.first
        when 'start' then talk_start(options, argv.drop(1))
        when '-h', '--help' then talk_usage
        when nil then talk_usage(1)
        else raise OptionParser::InvalidArgument, 'usage: tamoz talk start'
        end
      end

      # The gateway process's half: one hub per talk surface, shared by its poller and drainer transports.
      def talk_hub(descriptor, store)
        @talk_hubs ||= {}
        @talk_hubs[descriptor.surface_id] ||= begin
          begin
            require 'tamoz/talk'
          rescue LoadError
            raise CLICommsShared::MissingAdapterError, 'the talk channel (tamoz-talk) is not installed'
          end
          hub = Tamoz::Talk::Hub.new(
            descriptor:, token: credential(descriptor), synthesize: voice_synthesizer,
            floor: store.poll_offset(bot_id: descriptor.identity.fetch(:expected_bot_id)).to_i,
            host: @env.to_h.fetch('TAMOZ_TALK_HOST', '127.0.0.1'), trace: @env.to_h['TAMOZ_TALK_TRACE'] == '1'
          )
          hub.seed(store.delivered_messages(surface_id: descriptor.surface_id, limit: 50))
          hub
        end
      end

      def talk_hubs = (@talk_hubs || {}).values

      private

      def talk_usage(status = 0)
        @out.puts 'Usage: tamoz talk start'
        @out.puts '  start  Check the chat, speech-to-text and voice models, then run the gateway and worker'
        @out.puts 'Add the channel first with `tamoz channel add talk`.'
        status
      end

      def channel_add_talk(options, argv)
        request = talk_channel_options(argv)
        directory = channel_runtime(options)
        return talk_fail(RUNTIME_IN_WORKSPACE) if inside?(directory.path, directory.workspace_root)

        save_channel(directory, SURFACE, talk_entry(directory.channels[SURFACE], **request.except(:rotate)))
        token = talk_token(directory, rotate: request.fetch(:rotate))
        @out.puts "Talk channel ready. Start it with:\n  tamoz --runtime-dir #{directory.path} talk start --env-file .env"
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
          telegram_help(parser)
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

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      #   -- one guard per operator mistake, each named before anything is spawned.
      def talk_start(options, argv)
        env_file = nil
        host = nil
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz talk start [--env-file PATH] [--host ADDRESS] [--provider NAME --model NAME]'
          parser.on('--env-file PATH', 'Read KEY=value secrets from this file') { |path| env_file = path }
          parser.on('--host ADDRESS', 'Address the page listens on (default 127.0.0.1)') { |value| host = value }
          parser.on('--provider NAME', 'Model provider (default: the first with a key)') do |name|
            options[:provider] = name
          end
          parser.on('--model NAME', 'Model identifier') { |name| options[:model] = name }
          telegram_help(parser)
        end.parse!(argv)
        problem = env_file_problem(env_file)
        return talk_fail(problem) if problem

        base = env_with_file(env_file)
        runtime = telegram_runtime_path(options)
        return talk_fail(NO_CHANNEL) unless File.exist?(File.join(runtime, RuntimeDirectory::CONFIG_FILE))

        directory = RuntimeDirectory.resolve(path: runtime, env: base)
        return talk_fail(RUNTIME_IN_WORKSPACE) if directory.workspace_root && inside?(directory.path,
                                                                                      directory.workspace_root)

        entry = directory.channels[SURFACE]
        token_path = File.join(directory.path, 'talk', 'token')
        return talk_fail(NO_CHANNEL) unless entry && entry['kind'] == 'talk' && File.exist?(token_path)

        host ||= base['TAMOZ_TALK_HOST'] || '127.0.0.1'
        hosts = Array(entry.dig('talk', 'allow_hosts'))
        if !LOOPBACK.include?(host) && hosts.empty?
          return talk_fail("listening on #{host} needs `tamoz channel add talk --allow-host NAME` for the name the " \
                           'page is reached by')
        end

        problem = already_running(options, entry)
        return talk_fail(problem) if problem

        token = File.read(token_path).strip
        if token.length < TOKEN_MIN
          return talk_fail('the talk token is damaged; run `tamoz channel add talk --rotate-token`')
        end

        port = entry.dig('talk', 'port') || DEFAULT_PORT
        problem = port_problem(host, port)
        return talk_fail(problem) if problem

        provider, model = working_provider(options, base)
        return 1 unless provider

        problem = speech_problem(base, provider, runtime: directory)
        return talk_fail(problem) if problem

        unless LOOPBACK.include?(host)
          @err.puts "tamoz: #{host} is not loopback; the token crosses the network in clear text unless a TLS proxy " \
                    'fronts it'
        end
        print_talk_link(entry, host, token)
        run_talk(directory, base.merge('TAMOZ_PROVIDER' => provider, 'TAMOZ_MODEL' => model,
                                       TOKEN_ENV => token, 'TAMOZ_TALK_HOST' => host))
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # One real call per speech role, so a dead key is named now and not as a silent page.
      def speech_problem(base, chat_provider, runtime:)
        voice_key = ChildEnvironments.role_credential(base, 'VOICE') ||
                    (base['TAMOZ_VOICE_PROVIDER'] && Providers::ENV_KEYS[base['TAMOZ_VOICE_PROVIDER'].to_sym])
        chat_key = Providers::ENV_KEYS.fetch(chat_provider.to_sym)
        if voice_key && (voice_key == chat_key || (base[voice_key].to_s != '' && base[voice_key] == base[chat_key]))
          return "the voice key (#{voice_key}) must not be the chat model's key (#{chat_key}); give speech its own key"
        end

        transcription_problem(base, runtime) || voice_problem(base, runtime)
      rescue ArgumentError, Tamoz::ConfigurationError => e
        e.message
      end

      def transcription_problem(base, runtime)
        model = role_model(base, 'TRANSCRIPTION', runtime)
        unless model
          return 'set models.transcription in the runtime config (or TAMOZ_TRANSCRIPTION_PROVIDER and ' \
                 'TAMOZ_TRANSCRIPTION_MODEL) so Tamoz can hear you'
        end

        model.transcribe(audio: silent_wav, filename: 'probe.wav', media_type: 'audio/wav')
        nil
      rescue ModelCallError, EffectUnknownError => e
        "the speech-to-text model did not answer (#{e.class.name.split('::').last}); check its key and credit"
      end

      def voice_problem(base, runtime)
        model = role_model(base, 'VOICE', runtime)
        return nil unless model

        name = base['TAMOZ_VOICE_NAME'].to_s
        return 'set TAMOZ_VOICE_NAME to one of the voice model\'s voices' if name.empty?

        model.speak(text: 'ok', voice: name)
        nil
      rescue ModelCallError, EffectUnknownError => e
        "the voice model did not answer (#{e.class.name.split('::').last}); check TAMOZ_VOICE_* and its key"
      end

      def role_model(base, role, runtime)
        @talk_role_factory&.call(role) || with_env(base) { attachment_model(role, runtime:) }
      end

      def with_env(base)
        saved = @env
        @env = base
        yield
      ensure
        @env = saved
      end

      def voice_synthesizer
        model = attachment_model('VOICE')
        name = @env.to_h['TAMOZ_VOICE_NAME'].to_s
        return nil unless model && !name.empty?

        ->(text) { model.speak(text:, voice: name).audio }
      end

      def silent_wav
        samples = "\x00\x00".b * 16_000
        "RIFF#{[36 + samples.bytesize].pack('V')}WAVEfmt #{[16, 1, 1, 16_000, 32_000, 2, 16].pack('VvvVVvv')}" \
        "data#{[samples.bytesize].pack('V')}".b + samples
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

      def run_talk(directory, base)
        base = base.merge('RUBYLIB' => $LOAD_PATH.join(File::PATH_SEPARATOR), 'GEM_HOME' => Gem.dir,
                          'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR),
                          'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8')
        logs = File.join(directory.path, 'logs')
        Tamoz::Core::PrivateDirectory.secure(logs)
        runtime_dir = directory.path
        children = {}
        begin
          children[:"talk gateway"] = spawn_named(
            'talk-gateway', ChildEnvironments.gateway_env(base, runtime_dir:, surface: SURFACE, kind: 'talk'),
            ['--runtime-dir', runtime_dir, 'comms', 'serve', '--surface', SURFACE], logs
          )
          children[:worker] = spawn_named(
            'worker', ChildEnvironments.worker_env(base, runtime_dir:, models: directory.models),
            ['--runtime-dir', runtime_dir, '--provider', base.fetch('TAMOZ_PROVIDER'),
             '--model', base.fetch('TAMOZ_MODEL'), '--work-routing', 'worker', '--json'], logs
          )
        rescue StandardError
          children.each_value { |pid| stop_child(pid) }
          raise
        end
        @out.puts "Running. Open the link above; Ctrl-C stops it. Logs: #{logs}"
        @out.flush
        supervise(children.transform_keys { |name| name.to_s.tr(' ', '-') }, logs,
                  hint: 'check the model keys in your .env, or whether the talk port is free.')
      end

      def spawn_named(name, env, args, logs)
        log = File.join(logs, "#{name}.log")
        Process.spawn(env, RbConfig.ruby, CLITelegramCommands::EXE, *args,
                      out: [log, 'a', 0o600], err: [log, 'a', 0o600], unsetenv_others: true)
      end

      def inside?(path, folder)
        path = File.expand_path(path)
        folder = File.expand_path(folder)
        path == folder || path.start_with?("#{folder}/")
      end

      def talk_fail(message)
        @err.puts "tamoz: #{message}"
        1
      end
    end
    # rubocop:enable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength
  end
end
