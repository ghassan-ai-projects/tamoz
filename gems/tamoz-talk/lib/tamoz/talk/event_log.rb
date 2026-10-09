# frozen_string_literal: true

require 'securerandom'

module Tamoz
  module Talk
    # The page's view of the conversation: bounded, in memory, and reset on every boot (the epoch).
    class EventLog
      MAX_EVENTS = 500
      PULSE_STALE_S = 10.0

      attr_reader :epoch

      def initialize(clock:, max_events: MAX_EVENTS, now: -> { Time.now.utc })
        @clock = clock
        @max_events = max_events
        @now = now
        @epoch = SecureRandom.hex(8)
        @events = []
        @trimmed = 0
        @working = {}
        @listened_at = nil
        @mutex = Mutex.new
        @changed = ConditionVariable.new
      end

      def append(type, **fields) = add { |seq| fields.merge('type' => type, 'seq' => seq) }

      def append_message(fields)
        add { |seq| fields.merge('type' => 'message', 'seq' => seq, 'message_id' => fields.fetch('message_id', seq)) }
      end

      # A seeded message keeps the id its prompt receipt was bound to.
      def seed(message)
        @clock.raise_floor(message.fetch('message_id'))
        add { |seq| message.merge('type' => 'message', 'seq' => seq) }
      end

      def stop
        @mutex.synchronize do
          @stopped = true
          @changed.broadcast
        end
      end

      def message(message_id)
        @mutex.synchronize do
          @events.reverse_each.find do |event|
            event['type'] == 'message' && event['message_id'] == message_id
          end
        end
      end

      def pulse(conversation_id)
        @mutex.synchronize do
          now = @now.call
          @working[conversation_id] = { 'since' => @working.dig(conversation_id, 'since') || now, 'last_pulse' => now }
          @changed.broadcast
        end
      end

      def settle(conversation_id) = @mutex.synchronize { @working.delete(conversation_id) }

      def listening?(within_s: 60.0) = @mutex.synchronize { @listened_at && @now.call - @listened_at <= within_s }

      def since(after:, epoch:, timeout_s:, speech: false)
        @mutex.synchronize do
          @listened_at = @now.call if speech
          reset = epoch != @epoch || after.to_i > head || after.to_i < @trimmed
          @changed.wait(@mutex, timeout_s) if !reset && !@stopped && newer(after).empty?
          events = reset ? @events.dup : newer(after)
          { 'epoch' => @epoch, 'events' => events, 'next' => head, 'working' => working, 'reset' => reset }
        end
      end

      private

      def add
        @mutex.synchronize do
          event = yield @clock.next
          @events << event
          @trimmed = @events.shift['seq'] while @events.length > @max_events
          @changed.broadcast
          event
        end
      end

      def newer(after) = @events.select { |event| event['seq'] > after.to_i }

      def head = @events.last ? @events.last['seq'] : 0

      def working
        now = @now.call
        @working.reject! { |_id, state| now - state['last_pulse'] > PULSE_STALE_S }
        state = @working.values.first
        state && { 'since' => state['since'].iso8601(3), 'last_pulse' => state['last_pulse'].iso8601(3) }
      end
    end
  end
end
