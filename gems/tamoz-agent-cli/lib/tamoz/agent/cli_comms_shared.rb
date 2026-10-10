# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # Shared comms-CLI machinery (COMMS_DESIGN §14, ADR-042): opening the runtime directory, its adapter and request
    # inbox WITHOUT constructing a Session or a model, and turning a config entry into a descriptor its channel kind
    # accepts. Each kind's adapter gem is loaded through the registry only when a command needs it.
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:UtilityFunction
    # :reek:TooManyStatements, :reek:NilCheck, :reek:LongYieldList
    # :reek:IrresponsibleModule -- the module is the shared seam: one runtime-open sequence and one
    #   config->descriptor projection; splitting them would scatter the ordering invariant (ADR-042).
    # rubocop:disable Metrics/ModuleLength -- one shared seam, per the :reek rationale above.
    module CLICommsShared
      class MissingAdapterError < Tamoz::Agent::Error; end

      GATEWAY_POLLER_PREFIX = 'gateway'

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- each helper
      #   is one sequence (runtime-open, config->descriptor defaults) and
      #   splitting it would scatter the ordering invariant.

      # Opens the runtime directory, the SQLite adapter (with the same
      # memory-codec selection the worker uses, so request payloads written
      # here decode there), and the request-inbox seam the admission enqueue
      # needs — without ever constructing a Session or a model.
      def with_comms_runtime(options)
        directory = RuntimeDirectory.resolve(path: options[:runtime_dir], env: @env)
        require 'tamoz/sqlite'
        codec = directory.enabled_sources.include?('memory') ? Memory::Surface.codec : nil
        adapter = Tamoz::SQLite::Adapter.new(
          path: directory.database_path,
          limits: Tamoz::SQLite::Limits.new(lease_ttl: @sessions.lease_ttl),
          **(codec ? { state_codec: codec } : {})
        )
        begin
          definition = Tamoz.graph(name: 'channel-gateway', version: '1') do
            state :ready, default: true
            node(:finish, implementation_name: 'comms.gateway.finish', version: '1') { |_s, _c| { ready: true } }
            edge Tamoz::START, :finish
            edge :finish, Tamoz::END
          end
          checkpoints = definition.compile(checkpointer: adapter).checkpointer
          store = adapter.bind_comms_store(checkpoints)
          yield directory, adapter, store, checkpoints
        ensure
          adapter.close unless adapter.closed?
        end
      end

      def selected_surfaces(directory, filter)
        enabled = directory.channels.select { |_id, entry| entry.fetch('enabled', true) }.keys.sort
        return enabled if filter.nil?
        unless enabled.include?(filter)
          raise ArgumentError, "surface #{filter.inspect} is not configured or not enabled"
        end

        [filter]
      end

      # Config entry -> a descriptor its channel kind accepts. Defaults fill what the operator may omit; the
      # credential must be one the kind declares, so a config cannot point a gateway at another key.
      def build_descriptor(surface_id, entry, directory)
        kind = channel_kind(entry.fetch('kind'))
        credential = entry.fetch('credential_ref')
        unless kind.setup.env_names.include?(credential['name'])
          raise Comms::ValidationError, "channels.#{surface_id}.credential_ref names #{credential['name']}, which a " \
                                        "#{entry['kind']} channel does not hold"
        end
        descriptor = surface_descriptor(surface_id, entry, directory)
        kind.channel.validate!(descriptor)
        descriptor
      end

      def surface_descriptor(surface_id, entry, directory)
        Tamoz::Comms::SurfaceDescriptor.build(
          surface_id:,
          kind: entry.fetch('kind'),
          revision: entry.fetch('revision'),
          transport: symbolize({
            credential_ref: entry.fetch('credential_ref'),
            poll_timeout_s: entry.dig('transport', 'poll_timeout_s') || 30,
            batch: entry.dig('transport', 'batch') || 50,
            max_response_bytes: entry.dig('transport', 'max_response_bytes')
          }),
          identity: { stream_id: entry.fetch('stream_id') },
          settings: symbolize(entry.fetch('settings', {})),
          admission: symbolize({ 'direct' => 'disabled' }.merge(entry.fetch('admission', {}))),
          threading: entry.fetch('threading', 'conversation'),
          profile_id: entry.fetch('profile'),
          profile_digest: pinned_profile_digest(directory, entry.fetch('profile')),
          approvals: symbolize({ 'mode' => 'none', 'prompt_ttl_s' => 900 }.merge(entry.fetch('approvals', {}))),
          rendering: symbolize({
            'format' => 'plain', 'max_parts' => 5, 'part_characters' => 3500, 'overflow' => 'truncate',
            'speech' => false
          }.merge(entry.fetch('rendering', {}))),
          limits: symbolize({
            'max_inbound_bytes' => 8192, 'max_open_requests' => 50,
            'max_denial_prompts_per_request' => 4, 'outbox_capacity' => 500,
            'control_capacity' => 50, 'per_chat_messages_per_s' => 1.0,
            'global_messages_per_s' => 25.0
          }.merge(entry.fetch('limits', {})))
        )
      end

      # The authority a deployed surface pins: the digest the worker compares a
      # bound thread against (F25-SEC-01). Resolved and adopted through the same
      # guarded path the worker uses, out of the runtime directory the worker
      # reads, so a deploy cannot pin a profile the worker would refuse.
      def pinned_profile_digest(directory, profile_id)
        env = { 'TAMOZ_CONFIG_HOME' => directory.path }
        path = Profile.resolve_path(profile: profile_id, env:)
        Profile.load(path, env:, confirm_adoption: ->(_document) { true }).canonical_digest
      end

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, entry| [key.to_sym, symbolize(entry)] }
        when Array then value.map { |entry| symbolize(entry) }
        else value
        end
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

      # A speaking surface's voice; one that cannot be built (its key is missing) leaves replies text only, and
      # `start` has said so.
      def voice_synthesizer(directory)
        voice = directory.models['voice']
        model = voice && attachment_model('VOICE', runtime: directory)
        model && ->(text) { model.speak(text:, voice: voice.voice).audio }
      rescue ModelCallError, ConfigurationError
        nil
      end

      def ms_to_iso(ms_value)
        ms_value && Time.at(ms_value / 1000.0).utc.iso8601(3)
      end

      # Context controls are worker-owned. The gateway stays a model-free
      # connector process and answers with the bounded unavailable reply until
      # a durable worker control request is available.
      def comms_controls_source(_directory, _adapter, _options)
        nil
      end

      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
