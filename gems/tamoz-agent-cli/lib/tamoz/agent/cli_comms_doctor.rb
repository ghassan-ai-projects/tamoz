# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # `tamoz comms doctor` (COMMS_DESIGN §14): getMe, exact bot id,
    # TLS/permissions, webhook/poller conflict, token, and adapter presence —
    # each failure is NAMED in the output and exits 1. `--bootstrap` runs
    # before a surface exists: it authenticates with one env-var name, prints
    # the numeric bot id for the operator to copy into config, and never
    # persists or trusts it.
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:FeatureEnvy
    # :reek:UncommunicativeVariableName, :reek:UtilityFunction, :reek:NilCheck
    # :reek:NestedIterators, :reek:ManualDispatch, :reek:IrresponsibleModule
    #   -- the module is one named check per call; the branching IS the
    #   doctor's report (design §14), and the [value, error] helpers keep
    #   every failure named without exceptions crossing the report boundary.
    module CLICommsDoctor
      include CLICommsShared

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one named
      #   check per call; the branching IS the doctor's report.
      def comms_doctor(options, argv)
        bootstrap = false
        credential_ref = nil
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz comms doctor [--bootstrap] [--credential-ref NAME]'
          accept_json(parser, options)
          parser.on('--bootstrap', 'Authenticate before a surface exists') { bootstrap = true }
          parser.on('--credential-ref NAME', 'Env var name holding the token (bootstrap)') do |name|
            credential_ref = name
          end
        end.parse!(argv)

        return comms_doctor_bootstrap(credential_ref, options) if bootstrap

        checks = []
        begin
          with_comms_runtime(options) do |directory, _adapter, store, _checkpoints|
            checks << ['runtime permissions', true]
            selected_surfaces(directory, nil).each do |surface_id|
              descriptor = build_descriptor(surface_id, directory.channels.fetch(surface_id), directory)
              checks.concat(doctor_surface(store, descriptor))
            end
          end
        rescue RuntimeDirectory::Error => e
          checks << ['runtime permissions', e.message]
        end
        render_doctor(checks, options)
        checks.any? { |_name, detail| detail != true } ? 1 : 0
      end

      private

      # One surface's doctor checks. The token check runs BEFORE getMe so a
      # missing credential is named without a network call; the adapter check
      # runs before the client is built.
      def doctor_surface(store, descriptor)
        token_check = ["token #{credential_name(descriptor)}", credential_present?(descriptor)]
        checks = [token_check]
        return checks unless token_check.last == true

        client, client_error = comms_client(descriptor)
        return checks + [['adapter', client_error.message]] if client_error

        checks << ['adapter', true]
        checks << ['tls', tls_ok?(client)]
        identity, auth_error = authenticated_identity(client)
        return checks + [['token validity', auth_error.message]] if auth_error

        expected = descriptor.identity.fetch(:expected_bot_id)
        checks << if identity.fetch('id') == expected
                    ['bot id', true]
                  else
                    ['bot id', "token authenticates bot #{identity.fetch('id')}, " \
                               "config expects #{expected} (a token swap is a different surface)"]
                  end
        checks << ['webhook', webhook_ok?(client)]
        checks << ['poller', poller_ok?(store, descriptor)]
        checks
      end

      # The [value, error] pair keeps the failure NAMED without a
      # return-inside-begin in the caller.
      def comms_client(descriptor)
        [comms_client_factory.call(@env.fetch(credential_name(descriptor))), nil]
      rescue MissingAdapterError, LoadError => e
        [nil, e]
      end

      def authenticated_identity(client)
        [client.call('getMe', {}, idempotent: true), nil]
      rescue Tamoz::Comms::AuthenticationError => e
        [nil, e]
      end

      def credential_present?(descriptor)
        value = @env[credential_name(descriptor)]
        value.nil? || value.empty? ? "credential #{credential_name(descriptor).inspect} is not set" : true
      end

      # The production adapter constructs only https; a fixture client on
      # localhost is the only way this check can name a deviation.
      def tls_ok?(client)
        return true if client.respond_to?(:origin) && client.origin.start_with?('https://')

        'the API origin must be https'
      end

      def webhook_ok?(client)
        url = client.call('getWebhookInfo', {}, idempotent: true).fetch('url').to_s
        url.empty? || "a webhook is set at #{url}; long polling will conflict"
      end

      def poller_ok?(store, descriptor)
        state = store.poll_state(bot_id: descriptor.identity.fetch(:expected_bot_id))
        return true unless state && state['poller_owner_id'] && !state['poller_expires_at_ms'].nil?
        return true if state.fetch('poller_expires_at_ms') <= (Time.now.utc.to_r * 1000).to_i

        "another gateway (#{state.fetch('poller_owner_id')}) holds the poller lease"
      end

      # `--bootstrap` prints the authenticated numeric bot id for the operator
      # to copy into config and never persists or trusts it (design §14).
      def comms_doctor_bootstrap(credential_ref, _options)
        raise OptionParser::MissingArgument, '--credential-ref' if credential_ref.to_s.empty?

        token = @env[credential_ref]
        if token.to_s.empty?
          @err.puts "tamoz: credential #{credential_ref.inspect} is not set in the environment"
          return 1
        end

        client = comms_client_factory.call(token)
        identity = client.call('getMe', {}, idempotent: true)
        @out.puts "authenticated bot id: #{identity.fetch('id')}"
        @out.puts 'copy it into channels.<surface>.expected_bot_id; tamoz never persists or trusts it automatically'
        0
      rescue MissingAdapterError => e
        @err.puts "tamoz: #{e.message}"
        1
      end

      def render_doctor(checks, options)
        return if options[:json]

        checks.each do |name, detail|
          @out.puts detail == true ? "ok    #{name}" : "FAIL  #{name}: #{detail}"
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
    end
  end
end
