# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # The channel operator surface (COMMS_DESIGN §14, ADR-042): `tamoz comms serve|list|pair|delivery|request|doctor`.
    # :reek:FeatureEnvy, :reek:DuplicateMethodCall, :reek:UtilityFunction
    module CLICommsCommands
      include CLICommsShared
      include CLICommsServe

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
          rows = store.surfaces.select { |row| surface_filter.nil? || row.fetch('surface_id') == surface_filter }
          print_surface_summaries(rows.map { |row| surface_summary(store, row) }, options)
        end
        0
      end

      private

      def print_surface_summaries(document, options)
        if options[:json]
          @out.puts JSON.generate(document)
        elsif document.empty?
          @out.puts "No surfaces deployed. Configure channels and run 'tamoz comms serve --once'."
        else
          document.each { |row| render_surface_summary(row) }
        end
      end

      def surface_summary(store, row)
        surface_id = row.fetch('surface_id')
        stream_id = Tamoz::Comms::SurfaceDescriptor.from_wire(JSON.parse(row.fetch('descriptor_json')))
                                                   .identity.fetch(:stream_id)
        poll = store.poll_state(stream_id:)
        { 'surface_id' => surface_id, 'revision' => row.fetch('revision'), 'stream_id' => stream_id,
          'bindings' => store.bindings(surface_id:).map { |binding| binding_summary(binding) },
          'conversations' => store.conversations(surface_id:).map do |route|
            route.slice('conversation_id', 'thread_id')
          end,
          'next_offset' => poll && poll['next_offset'],
          'last_poll_at' => poll && ms_to_iso(poll.fetch('updated_at_ms')),
          'outbox' => store.outbox_counts(surface_id:) }
      end

      def binding_line(binding)
        "  binding v#{binding.fetch('version')} #{binding.fetch('correspondent_id')} " \
          "#{binding.fetch('conversation_id')} (#{binding.fetch('status')})"
      end

      def route_line(route) = "  route #{route.values_at('conversation_id', 'thread_id').join(' -> ')}"

      def binding_summary(binding) = binding.slice('correspondent_id', 'conversation_id', 'status', 'version')

      def render_surface_summary(row)
        @out.puts "surface #{row.fetch('surface_id')} rev #{row.fetch('revision')} stream #{row.fetch('stream_id')}",
                  "  offset #{row['next_offset'].inspect} last poll #{row['last_poll_at']}",
                  *row.fetch('bindings').map { |binding| binding_line(binding) },
                  *row.fetch('conversations').map { |route| route_line(route) },
                  "  outbox #{row.fetch('outbox').map { |pair| pair.join('=') }.join(' ')}"
      end
    end
  end
end
