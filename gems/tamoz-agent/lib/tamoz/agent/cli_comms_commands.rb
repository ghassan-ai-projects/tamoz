# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # The channel operator surface (COMMS_DESIGN §14, ADR-042): `tamoz comms
    # serve|list`. The gateway is a separate process that holds the bot token
    # and NEVER constructs a Session, loads a model credential, or opens a
    # file under the workspace root.
    # rubocop:disable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength
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
        else
          raise OptionParser::InvalidArgument, 'usage: tamoz comms serve|list|pair|delivery|doctor'
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
          gateways = descriptors.map do |descriptor|
            transport = build_transport(descriptor, credential(descriptor))
            Tamoz::Agent::CommsGateway.new(
              adapter:, checkpoints:, transport:, descriptor:,
              poller_owner: "#{GATEWAY_POLLER_PREFIX}:#{Process.pid}"
            )
          end
          if once
            outcomes = gateways.map(&:serve_once)
            @out.puts JSON.generate(outcomes) if options[:json]
            outcomes.include?(:auth_failed) ? 1 : 0
          else
            run_gateway_loops(gateways)
            0
          end
        end
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
      # restored so an in-process test never leaks traps.
      def run_gateway_loops(gateways)
        old_int = Signal.trap('INT') { gateways.each(&:stop) }
        old_term = Signal.trap('TERM') { gateways.each(&:stop) }
        begin
          gateways.map { |gateway| Thread.new { gateway.serve_loop } }.each(&:join)
        ensure
          Signal.trap('INT', old_int) if old_int
          Signal.trap('TERM', old_term) if old_term
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
    # rubocop:enable Metrics/ModuleLength, Metrics/AbcSize, Metrics/MethodLength
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  end
end
