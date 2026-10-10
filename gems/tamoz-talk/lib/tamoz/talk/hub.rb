# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Talk
    # One talk surface in one process: the inbox, event log, speaker and server that both transports share.
    class Hub
      MIN_TOKEN = 32
      FINAL_KINDS = %w[answer failed stopped blocked approval_request].freeze

      attr_reader :inbox, :log, :speaker, :normalizer, :stream_id

      # Where and how the page is served: the bound host and port (else the descriptor's), request
      # tracing, how long a submit waits for its answer, and the server's read deadlines.
      Serving = Data.define(:host, :port, :trace, :submit_timeout_s, :deadlines) do
        def initialize(host: '127.0.0.1', port: nil, trace: false, submit_timeout_s: 20.0, deadlines: {}) = super
      end

      def initialize(descriptor:, token:, floor: 0, synthesize: nil, **serving)
        raise ArgumentError, 'the talk token must be at least 32 characters' if token.to_s.length < MIN_TOKEN

        @descriptor = descriptor
        @token_digest = Digest::SHA256.digest(token)
        @serving = Serving.new(**serving)
        @trace = @serving.trace ? [] : nil
        @stream_id = descriptor.identity.fetch(:stream_id)
        @clock = Clock.new(floor:)
        @inbox = Inbox.new(clock: @clock)
        @log = EventLog.new(clock: @clock)
        @speaker = Speaker.new(synthesize:)
        @normalizer = Normalizer.new(surface_id: descriptor.surface_id, surface_revision: descriptor.revision)
        @mutex = Mutex.new
      end

      def submit_timeout_s = @serving.submit_timeout_s

      def transport = Transport.new(self)

      def start
        @server = Server.new(hub: self, host: @serving.host, port: @serving.port || @descriptor.settings.fetch(:port),
                             token_digest: @token_digest, allow_hosts: Array(@descriptor.settings[:allow_hosts]),
                             trace: !@trace.nil?, deadlines: @serving.deadlines).start
        self
      end

      def port = @server&.port

      # Above the durable cursor, and with the delivered history on the page, once the gateway holds the lease.
      def resume(floor:, history:)
        @clock.raise_floor(floor)
        seed(history)
      end

      def alive? = @server&.alive? || false

      def stop
        @inbox.stop
        @log.stop
        @server&.stop
      end

      # Delivered outbox rows keep their original receipts, so a live approval card still binds after a restart.
      def seed(rows)
        rows.each do |row|
          next unless row['receipt']

          message_id = JSON.parse(row.fetch('receipt')).fetch('message_id')
          delivery = Comms::Delivery.from_wire(row.merge('journaled' => row.fetch('journaled') == 1))
          register_speech(@log.seed(message_event(delivery, message_id)), delivery)
        end
      end

      def deliver(delivery)
        @log.settle(delivery.conversation_id) if FINAL_KINDS.include?(delivery.kind)
        editing = delivery.operation == 'edit_message'
        fields = message_event(delivery, editing ? delivery.reply_to : nil)
        event = @log.append_message(fields)
        mark('delivered', event['message_id'])
        prefetch(event) if register_speech(event, delivery)
        { 'message_id' => event['message_id'], 'platform_time' => Time.now.utc.iso8601(6) }
      end

      def trace = @mutex.synchronize { @trace&.dup || [] }

      private

      def message_event(delivery, message_id)
        markup = delivery.markup ? JSON.parse(delivery.markup) : {}
        { 'kind' => delivery.kind, 'text' => delivery.text, 'part_index' => delivery.part_index,
          'part_count' => delivery.part_count, 'spoken' => @speaker.enabled? && !spoken_text(delivery).nil?,
          'reference' => markup['reference'], 'actions' => markup['reference'] && markup.fetch('actions', %w[deny]),
          'replaces' => delivery.operation == 'edit_message' ? delivery.reply_to : nil,
          'message_id' => message_id }.compact
      end

      def spoken_text(delivery)
        return nil unless delivery.part_index.zero?

        Core::SpokenText.project(delivery.text, kind: delivery.kind, more: delivery.part_count > 1)
      end

      # The text registered to be spoken, or nil when the delivery is not spoken.
      def register_speech(event, delivery)
        spoken_text(delivery)&.tap { |text| @speaker.register(event['message_id'], text) }
      end

      # Speech is presentation: a prefetch problem never fails the delivery it follows.
      def prefetch(event)
        @speaker.prefetch(event['message_id']) if @log.listening?
      rescue StandardError => e
        warn "tamoz: speech prefetch failed (#{e.class})"
      end

      def mark(stage, id)
        return unless @trace

        @mutex.synchronize do
          @trace << { 'stage' => stage, 'id' => id, 'at' => Time.now.utc.iso8601(6) }
          @trace.shift while @trace.length > 1000
        end
      end
    end
  end
end
