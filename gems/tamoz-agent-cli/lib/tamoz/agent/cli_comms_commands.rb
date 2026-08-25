# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # The channel operator surface (COMMS_DESIGN §14, ADR-042): `tamoz comms
    # serve|list`. The gateway is a separate process that holds the bot token
    # and NEVER constructs a Session, loads a model credential, or opens a
    # file under the workspace root.
    # rubocop:disable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Performance/CollectionLiteralInLoop
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
      # gateway over the shared runtime database; `--once` does a single
      # poll/drain pass for deterministic supervision.
      def comms_serve(options, argv)
        surface_filter = nil
        once = false
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms serve [--surface ID] [--once]'
          accept_json(value, options)
          value.on('--surface ID', 'Serve only this surface') { |id| surface_filter = id }
          value.on('--once', 'One poll and drain pass, then exit') { once = true }
        end.parse!(argv)

        with_comms_runtime(options) do |directory, adapter, store, checkpoints|
          descriptors = selected_surfaces(directory, surface_filter).map do |surface_id|
            build_descriptor(surface_id, directory.channels.fetch(surface_id))
          end
          if descriptors.empty?
            @err.puts 'tamoz: no enabled channel surfaces are configured'
            return 1
          end

          descriptors.each { |descriptor| store.deploy_surface(descriptor.wire, now: Time.now.utc) }
          controls_source = comms_controls_source(directory, adapter, options)
          with_delivery_drainers(directory, descriptors) do |drainers|
            gateways = descriptors.zip(drainers).map do |descriptor, drainer|
              transport = build_transport(descriptor, credential(descriptor))
              Tamoz::Comms::Gateway.new(
                adapter:, checkpoints:, transport:, descriptor:,
                poller_owner: "#{GATEWAY_POLLER_PREFIX}:#{Process.pid}", drainer:,
                controls: controls_source
              )
            end
            if once
              outcomes = gateways.map do |gateway|
                next :poller_busy unless gateway.start == :started

                gateway.serve_once
              ensure
                gateway.stop
              end
              @out.puts JSON.generate(outcomes) if options[:json]
              outcomes.any? { |outcome| %i[auth_failed poller_busy poller_lost].include?(outcome) } ? 1 : 0
            else
              run_gateway_loops(gateways, drainers)
            end
          end
        end
      # A competing poller is a correctness problem, not a retry: it is named
      # and the gateway exits, rather than dying as an unhandled backtrace or
      # looping against a stream it does not own.
      rescue Comms::PollerConflictError => e
        @err.puts "tamoz: poller conflict: #{e.message}"
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

      private

      # A fenced gateway loop per surface, supervised like `tamoz worker`:
      # INT/TERM ask every loop to stop, and the previous handlers are
      # restored so an in-process test never leaks traps. A drainer that
      # loses its credential stops every loop and exits non-zero; an
      # unexpected storage failure is captured, named on stderr with its
      # type, and turns into a non-zero exit — never a quiet spin beside a
      # dead sibling thread.
      def run_gateway_loops(gateways, drainers)
        # Trap.install hands each stop request to a thread for us: `stop`
        # releases the poller lease with a database write, whose mutex raises
        # ThreadError in a trap context. Doing it inline turns a supervisor's
        # SIGTERM into a backtrace instead of a released lease.
        stop = ->(_reason) { stop_loops(gateways, drainers) }
        Cancellation::Trap.install(int: stop, term: stop) do
          failures = []
          threads = gateways.map do |gateway|
            Thread.new do
              outcome = gateway.serve_loop(drain: false)
              stop_loops(gateways, drainers) if %i[auth_failed poller_conflict].include?(outcome)
              outcome
            rescue StandardError => e
              failures << e
              stop_loops(gateways, drainers)
              :storage_failed
            end
          end
          threads.concat(drainers.map do |drainer|
            Thread.new do
              outcome = drainer.serve_loop
              stop_loops(gateways, drainers) if outcome == :authentication_refused
              outcome
            rescue StandardError => e
              failures << e
              stop_loops(gateways, drainers)
              :storage_failed
            end
          end)
          outcomes = threads.map(&:value)
          failures.each do |failure|
            @err.puts "tamoz: comms delivery stopped on #{failure.class}: #{failure.message}"
          end
          if outcomes.include?(:auth_failed)
            @err.puts 'tamoz: comms gateway stopped on Comms::AuthenticationError: ' \
                      'the channel credential was refused'
          end
          if outcomes.include?(:authentication_refused)
            @err.puts 'tamoz: comms delivery stopped on Comms::AuthenticationError: ' \
                      'the channel credential was refused'
          end

          return 1 if failures.any? ||
                      outcomes.include?(:auth_failed) ||
                      outcomes.include?(:authentication_refused)

          if outcomes.include?(:poller_conflict)
            raise Comms::PollerConflictError,
                  'a gateway lost the Telegram poller lease'
          end

          0
        ensure
          stop_loops(gateways, drainers)
        end
      end

      def stop_loops(gateways, drainers)
        gateways.each(&:stop)
        drainers.each(&:stop)
      end

      def with_delivery_drainers(directory, descriptors)
        entries = []
        descriptors.each do |descriptor|
          adapter = nil
          begin
            codec = directory.enabled_sources.include?('memory') ? Memory::Surface.codec : nil
            adapter = Tamoz::SQLite::Adapter.new(
              path: directory.database_path,
              limits: Tamoz::SQLite::Limits.new(lease_ttl: lease_ttl),
              **(codec ? { state_codec: codec } : {})
            )
            store = adapter.bind_comms_store
            transport = build_transport(descriptor, credential(descriptor))
            drainer = Tamoz::Comms::DeliveryDrainer.new(
              store:, transport:, descriptor:,
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
    # rubocop:enable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength, Performance/CollectionLiteralInLoop
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
