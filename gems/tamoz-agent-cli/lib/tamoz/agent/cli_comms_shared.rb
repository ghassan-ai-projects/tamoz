# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # Shared comms-CLI machinery (COMMS_DESIGN §14, ADR-042): opening the runtime directory, its adapter and request
    # inbox WITHOUT constructing a Session or a model, and turning a config entry into a descriptor its channel kind
    # accepts. Each kind's adapter gem is loaded through the registry only when a command needs it.
    # :reek:UtilityFunction, :reek:LongYieldList
    module CLICommsShared
      class MissingAdapterError < Tamoz::Agent::Error; end

      GATEWAY_POLLER_PREFIX = 'gateway'

      # The adapter uses the memory codec the worker uses, so request payloads written here decode there.
      def with_comms_runtime(options)
        directory = RuntimeDirectory.resolve(path: options[:runtime_dir], env: @env)
        adapter = comms_adapter(directory)
        begin
          checkpoints = gateway_definition.compile(checkpointer: adapter).checkpointer
          yield directory, adapter, adapter.bind_comms_store(checkpoints), checkpoints
        ensure
          adapter.close unless adapter.closed?
        end
      end

      def comms_adapter(directory)
        require 'tamoz/sqlite'
        codec = directory.enabled_sources.include?('memory') ? Memory::Surface.codec : nil
        Tamoz::SQLite::Adapter.new(path: directory.database_path,
                                   limits: Tamoz::SQLite::Limits.new(lease_ttl: @sessions.lease_ttl),
                                   **(codec ? { state_codec: codec } : {}))
      end

      def gateway_definition
        Tamoz.graph(name: 'channel-gateway', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'comms.gateway.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
      end

      def selected_surfaces(directory, filter)
        enabled = directory.channels.select { |_id, entry| entry.fetch('enabled', true) }.keys.sort
        return enabled if filter.nil?
        unless enabled.include?(filter)
          raise ArgumentError,
                "surface #{filter.inspect} is not configured or not enabled"
        end

        [filter]
      end

      # The credential must be one the kind declares, so a config cannot point a gateway at another key.
      def build_descriptor(surface_id, entry, directory)
        kind = channel_kind(entry.fetch('kind'))
        credential = entry.fetch('credential_ref')
        unless kind.setup.env_names.include?(credential['name'])
          raise Comms::ValidationError, "channels.#{surface_id}.credential_ref names #{credential['name']}, which a " \
                                        "#{entry['kind']} channel does not hold"
        end
        profile_digest = pinned_profile_digest(directory, entry.fetch('profile'))
        SurfaceConfig.descriptor(surface_id, entry, profile_digest:).tap do |descriptor|
          kind.channel.validate!(descriptor)
        end
      end

      # The digest the worker compares a bound thread against, resolved and adopted through the worker's own
      # guarded path, so a deploy cannot pin a profile the worker would refuse.
      def pinned_profile_digest(directory, profile_id)
        env = { 'TAMOZ_CONFIG_HOME' => directory.path }
        path = Profile.resolve_path(profile: profile_id, env:)
        Profile.load(path, env:, confirm_adoption: ->(_document) { true }).canonical_digest
      end

      def channel_kinds = @channel_kinds || CHANNEL_KINDS

      def channel_kind(name)
        channel_kinds.fetch(name) do
          raise Comms::ValidationError, "#{name.inspect} is not a channel kind (#{channel_kinds.keys.join(', ')})"
        end
      end

      # Only the variables the kind declares; a channel never sees the rest of the environment.
      def channel_env(kind, env = @env.to_h) = env.to_h.slice(*kind.setup.env_names)

      def channel_state_path(directory, surface_id) = File.join(directory.path, 'channels', surface_id)

      def channel_state_dir(directory, surface_id)
        channel_state_path(directory, surface_id).tap do |path|
          Tamoz::Core::PrivateDirectory.secure(File.dirname(path))
          Tamoz::Core::PrivateDirectory.secure(path)
        end
      end

      def credential_name(descriptor) = descriptor.transport.fetch(:credential_ref).fetch(:name)

      # A voice that cannot be built (its key is missing) leaves replies text only, and `start` has said so.
      def voice_synthesizer(directory)
        voice = directory.models['voice']
        model = voice && attachment_model('VOICE', runtime: directory)
        model && ->(text) { model.speak(text:, voice: voice.voice).audio }
      rescue ModelCallError, ConfigurationError
        nil
      end

      # One refused operator command: its message on stderr and exit 1.
      def refuse(message)
        @err.puts message
        1
      end

      def ms_to_iso(ms_value) = ms_value && Time.at(ms_value / 1000.0).utc.iso8601(3)
    end
  end
end
