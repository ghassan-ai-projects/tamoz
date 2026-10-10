# frozen_string_literal: true

require 'json'
require 'optparse'

module Tamoz
  module Agent
    # The operator's view of one request and of one ambiguous send, read from the durable stores alone.
    # :reek:FeatureEnvy, :reek:UtilityFunction, :reek:DuplicateMethodCall
    module CLICommsRequests
      TASK_WORDS = { 'not_started' => 'admitted', 'claimed' => 'running', 'redirecting' => 'waiting' }.freeze

      # `tamoz comms delivery resolve ID STATUS` — a genuinely ambiguous send (status :unknown) is resolved to
      # succeeded or failed by the OPERATOR, never retried blindly. The effect key is printed so the journal can
      # be reconciled with `tamoz resolve`.
      def comms_delivery(options, argv)
        unless argv.shift == 'resolve'
          raise OptionParser::InvalidArgument,
                'usage: tamoz comms delivery resolve ID STATUS'
        end

        delivery_id, status = delivery_operands(argv, options)
        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          row = unknown_delivery(store, delivery_id)
          next refuse("tamoz: no unknown delivery #{delivery_id.inspect}") unless row

          store.resolve_delivery(delivery_id:, status:, now: Time.now.utc)
          @out.puts "resolved #{delivery_id} as #{status} (effect #{row['effect_key']})"
          0
        end
      end

      # `tamoz comms request R<reference>`: task and delivery states, queue facts, lifecycle, terminal reason and
      # any cancellation timeline come from committed rows; JSON emits the store's document shape.
      def comms_request(options, argv)
        reference = request_reference(argv, options)
        with_comms_runtime(options) do |_directory, _adapter, store, _checkpoints|
          matches = store.requests_by_reference(reference).select do |surface_id, conversation_id, _|
            [nil, surface_id].include?(options[:surface]) && [nil, conversation_id].include?(options[:conversation])
          end
          next refuse("tamoz: no request with reference #{reference.inspect} is admitted") if matches.empty?

          print_request_views(request_views(store, matches, reference), options)
          0
        end
      end

      private

      def delivery_operands(argv, options)
        parser = OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms delivery resolve ID STATUS'
          accept_json(value, options)
        end
        parser.order!(argv)
        delivery_id = argv.shift
        status = argv.shift
        parser.parse!(argv)
        raise OptionParser::MissingArgument, 'ID' if delivery_id.to_s.empty?
        raise OptionParser::InvalidArgument, 'STATUS must be succeeded or failed' unless %w[succeeded
                                                                                            failed].include?(status)

        [delivery_id, status]
      end

      def unknown_delivery(store, delivery_id)
        rows = store.surfaces.flat_map do |surface|
          store.outbox_rows(surface_id: surface.fetch('surface_id'), statuses: %w[unknown], limit: 500)
        end
        rows.find { |candidate| candidate.fetch('delivery_id') == delivery_id }
      end

      def request_reference(argv, options)
        OptionParser.new do |value|
          value.banner = 'Usage: tamoz comms request R<reference> [--surface ID] [--conversation ID]'
          accept_json(value, options)
          value.on('--surface ID', 'Restrict to this surface') { |id| options[:surface] = id }
          value.on('--conversation ID', 'Restrict to this conversation') { |id| options[:conversation] = id }
        end.parse!(argv)
        reference = argv.shift
        raise OptionParser::MissingArgument, 'R<reference>' if reference.to_s.empty?

        reference
      end

      def request_views(store, matches, reference)
        matches.map do |surface_id, conversation_id, _|
          store.request_status(surface_id:, conversation_id:, ref: reference, now: Time.now.utc)
               .merge('surface_id' => surface_id, 'conversation_id' => conversation_id)
        end
      end

      def print_request_views(rows, options)
        return @out.puts(JSON.generate('schema' => 'tamoz.comms.request_view.v1', 'requests' => rows)) if options[:json]

        rows.each { |row| render_request_view(row) }
      end

      def render_request_view(row)
        @out.puts "request #{row.fetch('request_ref')} on #{row.fetch('surface_id')}/" \
                  "#{row.fetch('conversation_id')} (thread #{row.fetch('thread_id')})"
        @out.puts "  task=#{task_word(row)} delivery=#{delivery_word(row)} " \
                  "open_requests=#{row.fetch('open_requests')} state=#{row.fetch('state')}"
        queue = queue_facts(row)
        @out.puts "  #{queue.join(' ')}" unless queue.empty?
        render_cancellation(row['cancellation']) if row['cancellation']
      end

      def queue_facts(row)
        [row.key?('queue_position') && "queue_position=#{row['queue_position']}",
         row['queue_age_ms'] && "queue_age_ms=#{row['queue_age_ms']}"].select { |fact| fact }
      end

      def render_cancellation(cancellation)
        line = "  cancellation=#{cancellation.fetch('state')} requested_age_ms=#{cancellation['requested_age_ms']}"
        line += " observed_age_ms=#{cancellation['observed_age_ms']}" if cancellation['observed_at_ms']
        line += " terminal=#{cancellation['terminal']}" if cancellation['terminal']
        @out.puts line
        return unless cancellation['terminal'] == 'completed_before_effect'

        @out.puts '  terminal: completed before the cancellation took effect.'
      end

      def task_word(projection)
        internal = TASK_WORDS.fetch(projection.fetch('task_state')) { |stored| stored }
        Tamoz::Comms::Lifecycle.task_state_for(internal) || 'idle'
      rescue Tamoz::Comms::ValidationError
        internal
      end

      def delivery_word(projection)
        Tamoz::Comms::Lifecycle.delivery_state_for(projection.fetch('delivery_state'))
      rescue Tamoz::Comms::ValidationError
        projection.fetch('delivery_state')
      end
    end
  end
end
