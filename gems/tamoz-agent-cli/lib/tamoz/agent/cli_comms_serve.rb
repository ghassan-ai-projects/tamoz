# frozen_string_literal: true

require 'optparse'

module Tamoz
  module Agent
    # `tamoz comms serve`: the gateway is a separate process that holds its channel's credential and NEVER
    # constructs a Session, loads a model credential, or opens a file under the workspace root (ADR-042).
    # :reek:FeatureEnvy, :reek:UtilityFunction
    module CLICommsServe
      include CLICommsLoops

      ServedSurface = Data.define(:descriptor, :connection, :drainer, :gateway)

      # `tamoz comms serve [--surface ID] [--once]`: one fenced gateway per enabled surface; its connection and
      # drainer start only once it holds the lease. A competing poller is named and the gateway exits.
      def comms_serve(options, argv)
        filter, once = serve_options(options, argv)
        with_comms_runtime(options) do |directory, _adapter, store, checkpoints|
          descriptors = served_descriptors(directory, filter)
          next refuse('tamoz: no enabled channel surfaces are configured') if descriptors.empty?

          descriptors.each { |descriptor| store.deploy_surface(descriptor.wire, now: Time.now.utc) }
          serve_descriptors(directory, store, checkpoints, descriptors, once ? options : nil)
        end
      rescue Comms::PollerConflictError => e
        @err.puts "tamoz: poller conflict: #{e.message}"
        1
      rescue Comms::ConnectionError, Comms::ValidationError => e
        @err.puts "tamoz: #{e.message}"
        1
      end

      private

      def served_descriptors(directory, filter)
        selected_surfaces(directory, filter).map do |surface_id|
          build_descriptor(surface_id, directory.channels.fetch(surface_id), directory)
        end
      end

      def serve_options(options, argv)
        filter = nil
        once = false
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms serve [--surface ID] [--once]'
          accept_json(value, options)
          value.on('--surface ID', 'Serve only this surface') { |id| filter = id }
          value.on('--once', 'One poll and drain pass, then exit') { once = true }
        end.parse!(argv)
        [filter, once]
      end

      # `once_options` is the command's options for a single pass, nil for the loops.
      def serve_descriptors(directory, store, checkpoints, descriptors, once_options)
        surfaces = []
        surfaces = descriptors.map { |descriptor| open_surface(descriptor, directory) }
        with_delivery_drainers(directory, surfaces) do |drainers|
          served = surfaces.zip(drainers).map do |surface, drainer|
            surface.with(drainer:, gateway: surface_gateway(directory, checkpoints, surface, drainer))
          end
          once_options ? serve_surfaces_once(store, served, once_options) : run_gateway_loops(store, served)
        end
      ensure
        surfaces.each { |surface| surface.connection.stop }
      end

      # No controls source: context controls are worker-owned, so the model-free gateway answers them with the
      # bounded unavailable reply.
      def surface_gateway(directory, checkpoints, surface, drainer)
        Tamoz::Comms::Gateway.new(
          checkpoints:, transport: surface.connection.transport, descriptor: surface.descriptor,
          poller_owner: "#{CLICommsShared::GATEWAY_POLLER_PREFIX}:#{Process.pid}", drainer:,
          attachments: directory.attachment_spool
        )
      end

      def open_surface(descriptor, directory)
        kind = channel_kind(descriptor.kind)
        env = channel_env(kind)
        name = credential_name(descriptor)
        raise ArgumentError, "credential #{name.inspect} is not set in the environment" if env[name].to_s.empty?

        voice = descriptor.speech? ? voice_synthesizer(directory) : nil
        ServedSurface.new(descriptor:, connection: kind.channel.connect(descriptor, env:, voice:), drainer: nil,
                          gateway: nil)
      end

      def serve_surfaces_once(store, surfaces, options)
        outcomes = surfaces.map do |surface|
          outcome = surface.gateway.start
          next outcome unless outcome == :started

          start_connection(store, surface)
          surface.gateway.serve_once
        ensure
          surface.gateway.stop
        end
        @out.puts JSON.generate(outcomes) if options[:json]
        outcomes.intersect?(%i[auth_failed poller_busy poller_lost]) ? 1 : 0
      end

      # Each drainer has its own connection, so it never shares a SQLite handle with its gateway's thread.
      def with_delivery_drainers(directory, surfaces)
        adapters = []
        drainers = surfaces.map do |surface|
          adapters << (adapter = comms_adapter(directory))
          surface_drainer(adapter, surface)
        end
        yield drainers
      ensure
        drainers&.each(&:stop)
        adapters.each { |adapter| adapter.close unless adapter.closed? }
      end

      def surface_drainer(adapter, surface)
        descriptor = surface.descriptor
        Tamoz::Comms::DeliveryDrainer.new(
          store: adapter.bind_comms_store, transport: surface.connection.transport, descriptor:,
          owner: "#{CLICommsShared::GATEWAY_POLLER_PREFIX}:drainer:#{Process.pid}:#{descriptor.surface_id}"
        )
      end
    end
  end
end
