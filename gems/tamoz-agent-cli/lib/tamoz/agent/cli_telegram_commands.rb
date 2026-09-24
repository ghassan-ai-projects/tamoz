# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'optparse'
require 'psych'
require 'rbconfig'

module Tamoz
  module Agent
    # `tamoz telegram setup|start`: a working Telegram chat from a bot token and a model key.
    # rubocop:disable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength -- two guided operator flows.
    module CLITelegramCommands
      SURFACE = 'telegram'
      PROFILE = 'telegram'
      TOKEN_ENV = 'TAMOZ_TELEGRAM_BOT_TOKEN'
      TOOLS = %w[read_file list_directory search_text glob apply_patch create_file].freeze
      EXE = File.expand_path('../../../exe/tamoz', __dir__)
      PAIRING_WAIT_S = 120
      # Tried in this order when no --provider is given; the first that answers is used.
      PROVIDERS = { 'deepseek' => 'deepseek-chat', 'openrouter' => 'deepseek/deepseek-v4.1-flash',
                    'openai' => 'gpt-4.1-mini' }.freeze
      REFUSALS = { 401 => 'the API key was rejected', 403 => 'the API key was rejected',
                   402 => 'the account is out of credit', 429 => 'the key is rate-limited right now' }.freeze
      NO_CHANNEL = 'no Telegram channel is configured; run `tamoz telegram setup` first'

      def cmd_telegram(options, argv)
        case argv.first
        when 'setup' then telegram_setup(options, argv.drop(1))
        when 'start' then telegram_start(options, argv.drop(1))
        when '-h', '--help' then telegram_usage
        when nil then telegram_usage(1)
        else raise OptionParser::InvalidArgument, 'usage: tamoz telegram setup|start'
        end
      end

      private

      def telegram_usage(status = 0)
        @out.puts 'Usage: tamoz telegram setup|start'
        @out.puts '  setup  Pair the bot once and write its channel and workspace profile'
        @out.puts '  start  Verify the token and provider, then run the gateway and worker'
        status
      end

      def telegram_setup(options, argv)
        workspace = options[:root]
        explicit_workspace = false
        owner = nil
        env_file = nil
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz telegram setup [--workspace PATH] [--owner TELEGRAM_USER_ID] [--env-file PATH]'
          parser.on('--workspace PATH', 'Folder the agent works in (default: current folder)') do |path|
            workspace = path
            explicit_workspace = true
          end
          parser.on('--owner ID', Integer, 'Your Telegram user id, instead of pairing by message') { |id| owner = id }
          parser.on('--env-file PATH', 'Read KEY=value secrets from this file') { |path| env_file = path }
          telegram_help(parser)
        end.parse!(argv)
        problem = env_file_problem(env_file)
        return telegram_fail(problem) if problem

        token = env_with_file(env_file)[TOKEN_ENV].to_s
        return telegram_fail("set #{TOKEN_ENV} to the token @BotFather gave you") if token.empty?

        workspace = File.expand_path(workspace || Dir.pwd)
        return telegram_fail("workspace folder does not exist: #{workspace}") unless Dir.exist?(workspace)

        directory = telegram_runtime(telegram_runtime_path(options), workspace, explicit: explicit_workspace)
        client = comms_client_factory.call(token)
        bot = client.call('getMe', {}, idempotent: true)
        @out.puts "Bot: @#{bot.fetch('username')}"
        owner ||= pair_owner(client, bot)
        return 1 unless owner

        # The profile first: a failure here leaves no channel that points at a missing profile.
        write_telegram_profile(directory)
        surface = write_telegram_channel(directory, bot:, owner:)
        @out.puts "Paired with Telegram user #{owner}. Start it with:"
        @out.puts "  tamoz --runtime-dir #{directory.path} telegram start"
        @out.puts "  (if `tamoz` is not on your PATH: bundle exec tamoz --runtime-dir #{directory.path} telegram start)"
        @out.puts "Channel #{surface}, workspace #{directory.workspace_root}."
        0
      rescue Comms::AuthenticationError
        telegram_fail("Telegram refused the bot token in #{TOKEN_ENV}; copy it again from @BotFather")
      rescue Comms::CommsError => e
        telegram_fail("Telegram could not be reached (#{e.class.name.split('::').last}); check the token and network")
      end

      def telegram_help(parser)
        parser.on('-h', '--help', "Show this subcommand's options") do
          @out.puts parser
          throw :tamoz_subcommand_help, 0
        end
      end

      def telegram_runtime(path, workspace, explicit: false)
        directory = if File.exist?(File.join(path, RuntimeDirectory::CONFIG_FILE))
                      RuntimeDirectory.resolve(path:, env: @env)
                    else
                      RuntimeDirectory.create!(path, workspace:)
                    end
        # A runtime directory can predate its profiles directory; setup writes into it.
        FileUtils.mkdir_p(directory.profiles_path, mode: 0o700)
        explicit ? rewrite_workspace_root(directory, workspace) : directory
      end

      # `--workspace` is an explicit instruction; a re-run must not silently keep the old root.
      def rewrite_workspace_root(directory, workspace)
        return directory if directory.workspace_root == workspace

        path = File.join(directory.path, RuntimeDirectory::CONFIG_FILE)
        document = Psych.safe_load_file(path, aliases: false) || {}
        document['workspace'] = { 'root' => workspace }
        write_private(path, Psych.dump(document))
        RuntimeDirectory.resolve(path: directory.path, env: @env)
      end

      # `--runtime-dir`, then TAMOZ_RUNTIME_DIR, then the guide's ~/.tamoz.
      def telegram_runtime_path(options)
        options[:runtime_dir] || @env['TAMOZ_RUNTIME_DIR'] || File.join(Dir.home, '.tamoz')
      end

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
        telegram_fail('no message arrived; run setup again, or pass --owner with your Telegram user id')
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

      def write_telegram_channel(directory, bot:, owner:)
        path = File.join(directory.path, RuntimeDirectory::CONFIG_FILE)
        document = Psych.safe_load_file(path, aliases: false) || {}
        channels = document['channels'] ||= {}
        surface, existing = telegram_channel(channels, bot)
        allowed = Array(existing&.dig('admission', 'correspondents')) | ["telegram:user:#{owner}"]
        # A revision bump is what makes the gateway deploy the changed surface.
        channels[surface] = {
          'kind' => 'telegram', 'revision' => existing ? existing.fetch('revision') + 1 : 1, 'enabled' => true,
          'profile' => PROFILE,
          'credential_ref' => { 'kind' => 'env', 'name' => TOKEN_ENV },
          'expected_bot_id' => bot.fetch('id'), 'bot_username' => bot.fetch('username'),
          # A short poll lets Ctrl-C stop the gateway quickly.
          'transport' => { 'poll_timeout_s' => 10 },
          'admission' => { 'direct' => 'allowlist', 'correspondents' => allowed },
          'approvals' => { 'mode' => 'deny_only', 'prompt_ttl_s' => 900 }
        }
        write_private(path, Psych.dump(document))
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

      def write_telegram_profile(directory)
        path = File.join(directory.profiles_path, "#{PROFILE}.yaml")
        root = directory.workspace_root
        digest = Toolbox.new(root:, allow_changes: true, checks: {}, allowed_tools: TOOLS).catalog_digest
        write_private(path, Psych.dump(
                              'profile' => { 'schema_version' => 1, 'profile_id' => PROFILE,
                                             'profile_version' => '1.0', 'canonical_root' => root },
                              'roots' => { 'workspace' => root },
                              'tools' => { 'allowed' => TOOLS },
                              'policy' => { 'allow_changes' => true, 'default_check_safety' => 'read_only',
                                            'graph_version' => '1', 'behavior_version' => '1.0',
                                            'tool_catalog_digest' => digest, 'unattended_catalog_digest' => digest }
                            ))
      end

      def write_private(path, text)
        File.write(path, text)
        File.chmod(0o600, path)
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      #   -- one guard per operator mistake, each named before anything is spawned.
      def telegram_start(options, argv)
        env_file = nil
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz telegram start [--env-file PATH] [--provider NAME --model NAME]'
          parser.on('--env-file PATH', 'Read KEY=value secrets from this file') { |path| env_file = path }
          # The global parser stops at `telegram`, so these must also be accepted here.
          parser.on('--provider NAME', 'Model provider (default: the first with a key)') do |name|
            options[:provider] = name
          end
          parser.on('--model NAME', 'Model identifier') { |name| options[:model] = name }
          telegram_help(parser)
        end.parse!(argv)
        problem = env_file_problem(env_file)
        return telegram_fail(problem) if problem

        base = env_with_file(env_file)
        return telegram_fail("set #{TOKEN_ENV} (or pass --env-file)") if base[TOKEN_ENV].to_s.empty?
        return telegram_fail(NO_CHANNEL) unless File.exist?(
          File.join(telegram_runtime_path(options), RuntimeDirectory::CONFIG_FILE)
        )

        directory = RuntimeDirectory.resolve(path: telegram_runtime_path(options), env: base)
        surface, entry = configured_telegram_channel(directory)
        return telegram_fail(NO_CHANNEL) unless surface

        problem = token_problem(base) || already_running(options, entry)
        return telegram_fail(problem) if problem

        provider, model = working_provider(options, base)
        return 1 unless provider

        @out.puts "Tamoz is starting as @#{entry['bot_username'] || surface} with #{provider}/#{model}."
        run_telegram(directory, surface, base.merge('TAMOZ_PROVIDER' => provider, 'TAMOZ_MODEL' => model))
      end
      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # A second bot on the same token loses the poller race and exits; name the one that owns it instead.
      # A lease left by a run that crashed expires within a minute, so that case waits it out.
      def already_running(options, entry)
        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          state = store.poll_state(bot_id: entry.fetch('expected_bot_id')) || {}
          remaining = (state['poller_expires_at_ms'].to_i / 1000.0) - Time.now.to_f
          pid = state['poller_owner_id'].to_s[/\A#{CLICommsShared::GATEWAY_POLLER_PREFIX}:(\d+)\z/o, 1]&.to_i
          next unless remaining.positive? && pid

          next "Tamoz is already running for this bot (pid #{pid}); stop it first (Ctrl-C where it runs)" if alive?(pid)

          @out.puts "Waiting #{remaining.ceil}s for the previous run's hold on Telegram to expire..."
          sleep(remaining)
          nil
        end
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def env_with_file(env_file) = @env.to_h.merge(env_file ? read_env_file(env_file) : {})

      def env_file_problem(env_file)
        "cannot read --env-file #{env_file}" if env_file && !File.readable?(env_file)
      end

      def configured_telegram_channel(directory)
        directory.channels.find { |_id, channel| channel['kind'] == 'telegram' } || [nil, nil]
      end

      # One real getMe, so a revoked token is a named error now, not a dead child.
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

      def read_env_file(path)
        File.readlines(path, chomp: true).filter_map do |line|
          line = line.delete_suffix("\r").sub(/\Aexport\s+/, '')
          next if line.strip.empty? || line.lstrip.start_with?('#') || !line.include?('=')

          name, value = line.split('=', 2).map(&:strip)
          [name, unquote(value)]
        end.to_h
      end

      def unquote(value)
        return value[1..-2] if value.length >= 2 && value.start_with?(value[-1]) && ['"', "'"].include?(value[0])

        value
      end

      # One real call per candidate, so a dead key or an empty account is named before the bot starts.
      def working_provider(options, base)
        candidates = provider_candidates(options, base)
        return telegram_fail("no model API key found; set one of #{provider_env_names}") && nil if candidates.empty?

        candidates.each do |provider, model|
          problem = provider_problem(provider, model, base)
          return [provider, model] unless problem

          @err.puts "tamoz: #{provider}/#{model} (#{Providers::ENV_KEYS.fetch(provider.to_sym)}): #{problem}"
        end
        telegram_fail('no model provider answered; fix the key or account above')
        nil
      end

      def provider_candidates(options, base)
        name = options[:provider] || base['TAMOZ_PROVIDER']
        return [[name, options[:model] || base['TAMOZ_MODEL'] || PROVIDERS[name]]] if name

        PROVIDERS.reject { |provider, _| base[Providers::ENV_KEYS.fetch(provider.to_sym)].to_s.empty? }.to_a
      end

      def provider_env_names = PROVIDERS.keys.map { |name| Providers::ENV_KEYS.fetch(name.to_sym) }.join(', ')

      def provider_problem(provider, model, base)
        client = @model_factory&.call(provider:, model:) ||
                 ModelClientFactory.build(provider:, model:, profile_role: nil, environment: base, safety: :idempotent)
        client.generate(stage: :ping, system: 'Reply with the single word ok.', prompt: 'ping')
        nil
      rescue ModelCallError => e
        return "no #{Providers::ENV_KEYS.fetch(provider.to_sym)} found; set it" if e.code == 'credential_unavailable'

        REFUSALS.fetch(e.status.to_i) { "the provider call failed (#{e.code})" }
      rescue StandardError => e
        "the provider could not be reached (#{e.class})"
      end

      def run_telegram(directory, surface, base)
        base = base.merge('RUBYLIB' => $LOAD_PATH.join(File::PATH_SEPARATOR), 'GEM_HOME' => Gem.dir,
                          'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR),
                          'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8')
        logs = File.join(directory.path, 'logs')
        FileUtils.mkdir_p(logs, mode: 0o700)
        runtime_dir = directory.path
        children = {}
        begin
          children[:gateway] = spawn_child(
            ChildEnvironments.gateway_env(base, runtime_dir:, surface:),
            ['--runtime-dir', runtime_dir, 'comms', 'serve', '--surface', surface], logs
          )
          children[:worker] = spawn_child(
            ChildEnvironments.worker_env(base, runtime_dir:),
            ['--runtime-dir', runtime_dir, '--provider', base.fetch('TAMOZ_PROVIDER'),
             '--model', base.fetch('TAMOZ_MODEL'), '--work-routing', 'worker', '--json'], logs
          )
        rescue StandardError
          children.each_value { |pid| stop_child(pid) }
          raise
        end
        @out.puts "Running. Message the bot on Telegram; Ctrl-C stops it. Logs: #{logs}"
        @out.flush
        supervise(children, logs)
      end

      def spawn_child(env, args, logs)
        name = args.include?('worker') ? 'worker' : 'gateway'
        log = File.join(logs, "#{name}.log")
        Process.spawn(env, RbConfig.ruby, EXE, *args,
                      out: [log, 'a', 0o600], err: [log, 'a', 0o600], unsetenv_others: true)
      end

      # Both processes run until Ctrl-C; if one dies the other is stopped and its log tail is shown.
      def supervise(children, logs)
        stopping = false
        stop = ->(_reason) { stopping = true }
        Cancellation::Trap.install(int: stop, term: stop) do
          until stopping
            name, = children.find { |_name, pid| Process.wait(pid, Process::WNOHANG) }
            if name
              children.delete(name)
              @err.puts "tamoz: the #{name} stopped; last lines of #{File.join(logs, "#{name}.log")}:\n" \
                        "#{File.readlines(File.join(logs, "#{name}.log")).last(8).join}\n" \
                        'Full logs are in the runtime logs directory; re-check the token with `tamoz telegram setup`.'
              break
            end
            sleep 0.5
          end
        end
        @out.puts 'Stopping...'
        children.each_value { |pid| stop_child(pid) }
        @out.puts 'Stopped.'
        stopping ? 0 : 1
      end

      # TERM, then KILL after a bounded wait: a wedged child must not make Ctrl-C unkillable.
      def stop_child(pid, grace: 8)
        Process.kill('TERM', pid)
        return if exited_within?(pid, grace)

        Process.kill('KILL', pid)
        reap(pid)
      rescue Errno::ESRCH
        nil
      end

      def reap(pid)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end

      def exited_within?(pid, seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          return true if Process.wait(pid, Process::WNOHANG)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.2
        end
      rescue Errno::ECHILD
        true
      end

      def telegram_fail(message)
        @err.puts "tamoz: #{message}"
        1
      end
    end
    # rubocop:enable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength
  end
end
