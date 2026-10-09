# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Talk
    # One talk surface in one process: the inbox, event log, speaker and server that both transports share.
    class Hub
      attr_reader :inbox, :log, :speaker, :normalizer, :identity_id, :submit_timeout_s

      # rubocop:disable Metrics/ParameterLists -- the surface's facts plus the two injected collaborators.
      def initialize(descriptor:, token:, floor:, synthesize: nil, host: '127.0.0.1', port: nil, trace: false,
                     submit_timeout_s: 20.0, deadlines: {})
        @descriptor = descriptor
        @token_digest = Digest::SHA256.digest(token)
        @host = host
        @port = port || descriptor.transport.fetch(:port)
        @trace = trace ? [] : nil
        @identity_id = descriptor.identity.fetch(:expected_bot_id)
        @clock = Clock.new(floor:)
        @inbox = Inbox.new(clock: @clock)
        @log = EventLog.new(clock: @clock)
        @speaker = Speaker.new(synthesize:)
        @normalizer = Normalizer.new(surface_id: descriptor.surface_id, surface_revision: descriptor.revision)
        @submit_timeout_s = submit_timeout_s
        @deadlines = deadlines
        @mutex = Mutex.new
      end
      # rubocop:enable Metrics/ParameterLists

      def transport = Transport.new(self)

      def start
        @server = Server.new(hub: self, host: @host, port: @port, token_digest: @token_digest,
                             allow_hosts: Array(@descriptor.transport[:allow_hosts]), trace: !@trace.nil?,
                             deadlines: @deadlines).start
        self
      end

      def port = @server&.port

      def alive? = @server&.alive? || false

      def stop
        @inbox.stop
        @log.stop
        @server&.stop
      end

      # Delivered outbox rows keep their original receipts, so a live approval card still binds after a restart.
      def seed(rows)
        rows.each do |row|
          message_id = JSON.parse(row.fetch('receipt')).fetch('message_id')
          delivery = Comms::Delivery.from_wire(row.merge('journaled' => row.fetch('journaled') == 1))
          register_speech(@log.seed(message_event(delivery, message_id)), delivery)
        end
      end

      def deliver(delivery)
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

      def register_speech(event, delivery)
        text = spoken_text(delivery)
        return false unless text

        @speaker.register(event['message_id'], text)
        true
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
