# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # The channel operator surface (COMMS_DESIGN §14, ADR-042): `tamoz comms
    # serve|list`. The gateway is a separate process that holds its channel's
    # credential and NEVER constructs a Session, loads a model credential, or
    # opens a file under the workspace root.
    # rubocop:disable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength, Performance/CollectionLiteralInLoop
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    #   -- one operator command per method; the json-vs-text branching is the
    #   CLI's global convention and the summaries are one projection each.
    # :reek:TooManyStatements, :reek:FeatureEnvy, :reek:DuplicateMethodCall
    # :reek:NestedIterators, :reek:DataClump, :reek:UtilityFunction
    # :reek:IrresponsibleModule -- the module is one operator command per
    #   method; the json-vs-text branching is the CLI's global convention.
    module CLICommsCommands
      include CLICommsShared

      def cmd_comms(options, argv)
        verb = argv.shift
        case verb
        when 'serve' then comms_serve(options, argv)
        when 'list' then comms_list(options, argv)
        when 'doctor' then comms_doctor(options, argv)
        when 'pair' then comms_pair(options, argv)
        when 'delivery' then comms_delivery(options, argv)
        when 'request' then comms_request(options, argv)
        else
          raise OptionParser::InvalidArgument, 'usage: tamoz comms serve|list|pair|delivery|request|doctor'
        end
      end

      # `tamoz comms serve [--surface ID] [--once]` — the long-running gateway
      # (design §5, ADR-042). Each enabled surface gets its own fenced poller
      # gateway over the shared runtime database; a surface's connection and
      # drainer start only once its gateway holds the lease. `--once` does a
      # single poll/drain pass for deterministic supervision.
      def comms_serve(options, argv)
        surface_filter = nil
        once = false
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms serve [--surface ID] [--once]'
          accept_json(value, options)
          value.on('--surface ID', 'Serve only this surface') { |id| surface_filter = id }
          value.on('--once', 'One poll and drain pass, then exit') { once = true }
        end.parse!(argv)

        connections = []
        with_comms_runtime(options) do |directory, adapter, store, checkpoints|
          descriptors = selected_surfaces(directory, surface_filter).map do |surface_id|
            build_descriptor(surface_id, directory.channels.fetch(surface_id), directory)
          end
          if descriptors.empty?
            @err.puts 'tamoz: no enabled channel surfaces are configured'
            return 1
          end

          descriptors.each { |descriptor| store.deploy_surface(descriptor.wire, now: Time.now.utc) }
          surfaces = descriptors.map { |descriptor| open_surface(descriptor, directory) }
          connections = surfaces.map(&:connection)
          controls_source = comms_controls_source(directory, adapter, options)
          with_delivery_drainers(directory, surfaces) do |drainers|
            surfaces = surfaces.zip(drainers).map do |surface, drainer|
              surface.with(drainer:, gateway: Tamoz::Comms::Gateway.new(
                adapter:, checkpoints:, transport: surface.connection.transport, descriptor: surface.descriptor,
                poller_owner: "#{GATEWAY_POLLER_PREFIX}:#{Process.pid}", drainer:,
                controls: controls_source, credential: surface.credential, attachments: directory.attachment_spool
              ))
            end
            once ? serve_surfaces_once(store, surfaces, options) : run_gateway_loops(store, surfaces)
          end
        ensure
          connections.each(&:stop)
        end
      # A competing poller is a correctness problem, not a retry: it is named
      # and the gateway exits, rather than dying as an unhandled backtrace or
      # looping against a stream it does not own.
      rescue Comms::PollerConflictError => e
        @err.puts "tamoz: poller conflict: #{e.message}"
        1
      rescue Comms::ConnectionError, Comms::ValidationError => e
        @err.puts "tamoz: #{e.message}"
        1
      end

      # `tamoz comms list [--surface ID]` — surfaces, bindings, the
      # conversation -> thread map, the durable next offset, and outbox depth.
      def comms_list(options, argv)
        surface_filter = nil
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms list [--surface ID]'
          accept_json(value, options)
          value.on('--surface ID', 'List only this surface') { |id| surface_filter = id }
        end.parse!(argv)

        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          surfaces = store.surfaces
          surfaces = surfaces.select { |row| row.fetch('surface_id') == surface_filter } if surface_filter
          document = surfaces.map { |row| surface_summary(store, row) }
          if options[:json]
            @out.puts JSON.generate(document)
          elsif document.empty?
            @out.puts "No surfaces deployed. Configure channels and run 'tamoz comms serve --once'."
          else
            document.each { |row| render_surface_summary(row) }
          end
        end
        0
      end

      ServedSurface = Data.define(:descriptor, :connection, :credential, :drainer, :gateway)

      private

      def open_surface(descriptor, directory)
        kind = channel_kind(descriptor.kind)
        env = channel_env(kind)
        name = credential_name(descriptor)
        raise ArgumentError, "credential #{name.inspect} is not set in the environment" if env[name].to_s.empty?

        connection = kind.channel.connect(descriptor, env:,
                                                      voice: descriptor.speech? ? voice_synthesizer(directory) : nil)
        ServedSurface.new(descriptor:, connection:, credential: env.fetch(name), drainer: nil, gateway: nil)
      end

      def start_connection(store, surface)
        descriptor = surface.descriptor
        surface.connection.start(
          floor: store.poll_offset(bot_id: descriptor.identity.fetch(:expected_bot_id)),
          history: store.delivered_messages(surface_id: descriptor.surface_id, limit: 50)
        )
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
        outcomes.any? { |outcome| %i[auth_failed poller_busy poller_lost].include?(outcome) } ? 1 : 0
      end

      # A fenced gateway loop per surface, supervised like `tamoz worker`:
      # INT/TERM ask every loop to stop, and the previous handlers are
      # restored so an in-process test never leaks traps. A surface's
      # connection and drainer start from the gateway's `on_started`, so a run
      # that cannot take the lease never listens or delivers. A drainer that
      # loses its credential stops every loop and exits non-zero; an
      # unexpected failure is named on stderr with its type and turns into a
      # non-zero exit — never a quiet spin beside a dead sibling thread.
      def run_gateway_loops(store, surfaces)
        # Trap.install hands each stop request to a thread for us: `stop`
        # releases the poller lease with a database write, whose mutex raises
        # ThreadError in a trap context.
        stop = ->(_reason) { stop_loops(surfaces) }
        Cancellation::Trap.install(int: stop, term: stop) do
          failures = Queue.new
          drainers = Queue.new
          threads = surfaces.map { |surface| gateway_thread(store, surface, surfaces, failures, drainers) }
          outcomes = threads.map(&:value)
          busy = surfaces.zip(outcomes).filter_map do |surface, outcome|
            surface.descriptor.surface_id if outcome == :poller_busy
          end
          outcomes += Array.new(drainers.size) { drainers.pop }.map(&:value)
          report_loop_failures(Array.new(failures.size) { failures.pop }, outcomes, busy)
        ensure
          stop_loops(surfaces)
        end
      end

      def gateway_thread(store, surface, surfaces, failures, drainers)
        Thread.new do
          started = lambda do
            start_connection(store, surface)
            drainers << drainer_thread(surface, surfaces, failures)
          end
          outcome = surface.gateway.serve_loop(drain: false, interval_s: surface.connection.interval_s,
                                               on_started: started)
          stop_loops(surfaces) if %i[auth_failed poller_conflict poller_busy].include?(outcome)
          outcome
        rescue StandardError => e
          failures << e
          stop_loops(surfaces)
          :storage_failed
        end
      end

      def drainer_thread(surface, surfaces, failures)
        Thread.new do
          outcome = surface.drainer.serve_loop
          stop_loops(surfaces) if outcome == :authentication_refused
          outcome
        rescue StandardError => e
          failures << e
          stop_loops(surfaces)
          :storage_failed
        end
      end

      def report_loop_failures(failures, outcomes, busy)
        failures.each do |failure|
          named = failure.is_a?(Comms::ConnectionError) ? '' : "comms delivery stopped on #{failure.class}: "
          @err.puts "tamoz: #{named}#{failure.message}"
        end
        if outcomes.include?(:auth_failed)
          @err.puts 'tamoz: comms gateway stopped on Comms::AuthenticationError: the channel credential was refused'
        end
        if outcomes.include?(:authentication_refused)
          @err.puts 'tamoz: comms delivery stopped on Comms::AuthenticationError: the channel credential was refused'
        end
        @err.puts "tamoz: another run holds #{busy.join(', ')}; stop it first" if busy.any?
        return 1 if failures.any? || outcomes.intersect?(%i[auth_failed authentication_refused poller_busy])
        raise Comms::PollerConflictError, 'a gateway lost the poller lease' if outcomes.include?(:poller_conflict)

        0
      end

      def stop_loops(surfaces)
        surfaces.each do |surface|
          surface.gateway&.stop
          surface.drainer&.stop
          surface.connection.stop
        end
      end

      def with_delivery_drainers(directory, surfaces)
        entries = []
        surfaces.each do |surface|
          adapter = nil
          begin
            codec = directory.enabled_sources.include?('memory') ? Memory::Surface.codec : nil
            adapter = Tamoz::SQLite::Adapter.new(
              path: directory.database_path,
              limits: Tamoz::SQLite::Limits.new(lease_ttl: @sessions.lease_ttl),
              **(codec ? { state_codec: codec } : {})
            )
            descriptor = surface.descriptor
            drainer = Tamoz::Comms::DeliveryDrainer.new(
              store: adapter.bind_comms_store, transport: surface.connection.transport, descriptor:,
              owner: "#{GATEWAY_POLLER_PREFIX}:drainer:#{Process.pid}:#{descriptor.surface_id}",
              batch_size: descriptor.transport.fetch(:batch)
            )
            entries << [adapter, drainer]
          rescue StandardError
            adapter&.close unless adapter&.closed?
            raise
          end
        end
        yield entries.map(&:last)
      ensure
        entries.each do |adapter, drainer|
          drainer.stop
          adapter.close unless adapter.closed?
        end
      end

      def surface_summary(store, row)
        descriptor = Tamoz::Comms::SurfaceDescriptor.from_wire(JSON.parse(row.fetch('descriptor_json')))
        bot_id = descriptor.identity.fetch(:expected_bot_id)
        poll = store.poll_state(bot_id:)
        {
          'surface_id' => row.fetch('surface_id'),
          'revision' => row.fetch('revision'),
          'bot_id' => bot_id,
          'bindings' => store.bindings(surface_id: row.fetch('surface_id')).map do |binding|
            { 'correspondent_id' => binding.fetch('correspondent_id'),
              'conversation_id' => binding.fetch('conversation_id'),
              'status' => binding.fetch('status'), 'version' => binding.fetch('version') }
          end,
          'conversations' => store.conversations(surface_id: row.fetch('surface_id')).map do |route|
            { 'conversation_id' => route.fetch('conversation_id'), 'thread_id' => route.fetch('thread_id') }
          end,
          'next_offset' => poll && poll['next_offset'],
          'last_poll_at' => poll && ms_to_iso(poll.fetch('updated_at_ms')),
          'outbox' => store.outbox_counts(surface_id: row.fetch('surface_id'))
        }
      end

      def render_surface_summary(row)
        @out.puts "surface #{row.fetch('surface_id')} rev #{row.fetch('revision')} bot #{row.fetch('bot_id')}"
        @out.puts "  offset #{row['next_offset'].inspect} last poll #{row['last_poll_at']}"
        row.fetch('bindings').each do |binding|
          @out.puts "  binding v#{binding.fetch('version')} #{binding.fetch('correspondent_id')} " \
                    "#{binding.fetch('conversation_id')} (#{binding.fetch('status')})"
        end
        row.fetch('conversations').each do |route|
          @out.puts "  route #{route.fetch('conversation_id')} -> #{route.fetch('thread_id')}"
        end
        @out.puts "  outbox #{row.fetch('outbox').map { |status, count| "#{status}=#{count}" }.join(' ')}"
      end
    end
    # rubocop:enable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength, Performance/CollectionLiteralInLoop
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
