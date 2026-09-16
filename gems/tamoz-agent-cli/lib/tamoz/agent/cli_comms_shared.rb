# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # Shared comms-CLI machinery (COMMS_DESIGN §14, ADR-042): opening the
    # runtime directory + adapter + request-inbox seam WITHOUT constructing a
    # Session or a model, and building the transport through the lazy adapter
    # seam. `tamoz-comms` is a hard dependency; `tamoz-telegram` is loaded
    # only when a command actually needs the wire, so an installation without
    # the adapter reports a typed missing-adapter error instead of failing to
    # boot.
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:UtilityFunction
    # :reek:TooManyStatements, :reek:NilCheck, :reek:LongYieldList
    # :reek:IrresponsibleModule -- the module is the shared seam: one
    #   runtime-open sequence, one config->descriptor projection, one lazy
    #   adapter load. Splitting the helpers would scatter the ordering
    #   invariant (ADR-042: no Session, no model, no workspace file).
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
          limits: Tamoz::SQLite::Limits.new(lease_ttl: lease_ttl),
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

      # Config entry -> validated SurfaceDescriptor. Fields the operator may
      # omit get the design defaults; every mandatory field of the descriptor
      # contract is filled here. YAML keys are strings; the descriptor
      # contract is symbol-keyed, so the nested sections are converted.
      def build_descriptor(surface_id, entry)
        Tamoz::Comms::SurfaceDescriptor.build(
          surface_id:,
          revision: entry.fetch('revision'),
          transport: symbolize({
            mode: 'long_poll',
            credential_ref: entry.fetch('credential_ref'),
            poll_timeout_s: entry.dig('transport', 'poll_timeout_s') || 30,
            batch: entry.dig('transport', 'batch') || 50,
            max_response_bytes: entry.dig('transport', 'max_response_bytes')
          }),
          identity: symbolize({ expected_bot_id: entry.fetch('expected_bot_id'),
                                bot_username: entry['bot_username'] }.compact),
          admission: symbolize({ 'direct' => 'disabled' }.merge(entry.fetch('admission', {}))),
          threading: entry.fetch('threading', 'conversation'),
          profile_id: entry.fetch('profile'),
          profile_digest: pinned_profile_digest(entry.fetch('profile')),
          approvals: symbolize({ 'mode' => 'none', 'prompt_ttl_s' => 900 }.merge(entry.fetch('approvals', {}))),
          rendering: symbolize({
            'format' => 'plain', 'max_parts' => 5, 'part_characters' => 3500, 'overflow' => 'truncate'
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
      # guarded path the worker uses, so a deploy cannot pin a profile the
      # worker would refuse.
      def pinned_profile_digest(profile_id)
        path = Profile.resolve_path(profile: profile_id, env: @env)
        Profile.load(path, env: @env, confirm_adoption: ->(_document) { true }).canonical_digest
      end

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, entry| [key.to_sym, symbolize(entry)] }
        when Array then value.map { |entry| symbolize(entry) }
        else value
        end
      end

      def credential(descriptor)
        name = credential_name(descriptor)
        @env.fetch(name) do
          raise ArgumentError, "credential #{name.inspect} is not set in the environment"
        end
      end

      def credential_name(descriptor) = descriptor.transport.fetch(:credential_ref).fetch(:name)

      # The lazy adapter load (ADR-041: tamoz-agent has no HTTP client; the
      # transport is optional). A missing adapter is a typed error, never a
      # boot failure.
      def build_transport(descriptor, token)
        client = comms_client_factory(descriptor).call(token)
        require 'tamoz/telegram'
        normalizer = Tamoz::Telegram::Normalizer.new(
          surface_id: descriptor.surface_id,
          surface_revision: descriptor.revision,
          bot_username: descriptor.identity[:bot_username]
        )
        Tamoz::Telegram::Transport.new(client:, normalizer:)
      end

      # The client seam: production builds the real Telegram client carrying
      # the surface's DECLARED response cap (nil means the client's own
      # default — one source of truth); tests inject a fixture client (the
      # design's "inject a fixture client rather than weakening this
      # production origin rule"). A missing adapter surfaces as
      # MissingAdapterError, never a boot failure.
      def comms_client_factory(descriptor = nil)
        @comms_client_factory || lambda do |token|
          require 'tamoz/telegram'
          cap = descriptor && descriptor.transport[:max_response_bytes]
          Tamoz::Telegram::Client.new(token, max_response_bytes: cap)
        rescue LoadError
          raise MissingAdapterError,
                'the Telegram adapter (tamoz-telegram) is not installed; install it to run comms commands'
        end
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
  end
end
