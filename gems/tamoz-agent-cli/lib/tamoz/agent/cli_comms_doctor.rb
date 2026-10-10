# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # `tamoz comms doctor` (COMMS_DESIGN §14): runtime permissions, then each surface's own checks (its channel
    # kind's), the adapter's presence and the poller lease — each failure NAMED in the output, exit 1.
    # :reek:TooManyStatements, :reek:FeatureEnvy, :reek:UtilityFunction, :reek:IrresponsibleModule
    module CLICommsDoctor
      include CLICommsShared

      def comms_doctor(options, argv)
        OptionParser.new do |parser|
          parser.banner = 'Usage: tamoz comms doctor'
          accept_json(parser, options)
        end.parse!(argv)

        checks = []
        begin
          with_comms_runtime(options) do |directory, _adapter, store, _checkpoints|
            checks << ['runtime permissions', true]
            selected_surfaces(directory, nil).each do |surface_id|
              checks.concat(doctor_surface(store, surface_id, directory))
            end
          end
        rescue RuntimeDirectory::Error => e
          checks << ['runtime permissions', e.message]
        end
        render_doctor(checks, options)
        checks.any? { |_name, detail| detail != true } ? 1 : 0
      end

      private

      def doctor_surface(store, surface_id, directory)
        descriptor = build_descriptor(surface_id, directory.channels.fetch(surface_id), directory)
        kind = channel_kind(descriptor.kind)
        poller = poller_ok?(store, descriptor)
        [['adapter', true]] +
          kind.setup.check(descriptor:, env: channel_env(kind), state_dir: channel_state_dir(directory, surface_id),
                           poller_free: poller == true) + [['poller', poller]]
      rescue MissingAdapterError => e
        [['adapter', e.message]]
      rescue Comms::ValidationError => e
        [["surface #{surface_id}", e.message]]
      end

      def poller_ok?(store, descriptor)
        state = store.poll_state(bot_id: descriptor.identity.fetch(:expected_bot_id))
        return true unless state && state['poller_owner_id'] && !state['poller_expires_at_ms'].nil?
        return true if state.fetch('poller_expires_at_ms') <= (Time.now.utc.to_r * 1000).to_i

        "another gateway (#{state.fetch('poller_owner_id')}) holds the poller lease"
      end

      def render_doctor(checks, options)
        return if options[:json]

        checks.each do |name, detail|
          @out.puts detail == true ? "ok    #{name}" : "FAIL  #{name}: #{detail}"
        end
      end
    end
  end
end
