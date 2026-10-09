# frozen_string_literal: true

require 'digest'

module Tamoz
  module Talk
    # What the browser sent, held until a later poll confirms the gateway made it durable; anything unconfirmed is
    # handed out again, as Telegram redelivers an update whose offset was never persisted.
    class Inbox
      MAX_UPDATES = 256
      MAX_AUDIO_BYTES = 8_000_000
      MAX_OFFSETS = 64

      Entry = Struct.new(:update_id, :digest, :sequence, :envelope, :audio, :returned, :outcome, keyword_init: true)

      def initialize(clock:, max_updates: MAX_UPDATES, max_audio_bytes: MAX_AUDIO_BYTES)
        @clock = clock
        @max_updates = max_updates
        @max_audio_bytes = max_audio_bytes
        @entries = []
        @mutex = Mutex.new
        @changed = ConditionVariable.new
        @stopping = false
        @offsets = []
      end

      # @return [Symbol] :admitted, :timeout, :full or :stopping
      def submit(envelope, audio: nil, timeout_s: 20.0)
        @mutex.synchronize do
          return :stopping if @stopping

          entry = find(envelope) || enqueue(envelope, audio)
          return :full unless entry

          wait_for(entry, deadline(timeout_s))
        end
      end

      def poll(next_offset:, limit:, timeout_s:)
        @mutex.synchronize do
          confirm_below(next_offset) if @offsets.include?(next_offset)
          batch = @entries.first(limit)
          if batch.empty? && !@stopping
            @changed.wait(@mutex, timeout_s)
            batch = @entries.first(limit)
          end
          batch.each { |entry| entry.returned = true }
          offset = batch.empty? ? nil : batch.last.sequence + 1
          remember_offset(offset) if offset
          { updates: batch.map(&:envelope), next_offset: offset }
        end
      end

      def audio(file_id)
        @mutex.synchronize { @entries.find { |entry| entry.envelope.dig('attachment', 'file_id') == file_id }&.audio }
      end

      def stop
        @mutex.synchronize do
          @stopping = true
          @changed.broadcast
        end
      end

      def size = @mutex.synchronize { @entries.length }

      private

      def find(envelope)
        digest = envelope.fetch('raw_payload_hash')
        @entries.find { |entry| entry.update_id == envelope.fetch('update_id') && entry.digest == digest }
      end

      def enqueue(envelope, audio)
        return nil if @entries.length >= @max_updates
        return nil if audio && held_audio_bytes + audio.bytesize > @max_audio_bytes

        entry = Entry.new(update_id: envelope.fetch('update_id'), digest: envelope.fetch('raw_payload_hash'),
                          sequence: @clock.next, envelope:, audio:, returned: false)
        @entries << entry
        @changed.broadcast
        entry
      end

      def wait_for(entry, deadline)
        until entry.outcome || @stopping
          left = deadline - monotonic
          return :timeout unless left.positive?

          @changed.wait(@mutex, left)
        end
        entry.outcome || :stopping
      end

      def confirm_below(next_offset)
        confirmed, @entries = @entries.partition { |entry| entry.returned && entry.sequence < next_offset }
        return if confirmed.empty?

        confirmed.each { |entry| entry.outcome = :admitted }
        @changed.broadcast
      end

      # Only an offset this process handed out can confirm anything; a stale one from another boot confirms nothing.
      def remember_offset(offset)
        @offsets << offset
        @offsets.shift while @offsets.length > MAX_OFFSETS
      end

      def held_audio_bytes = @entries.sum { |entry| entry.audio&.bytesize.to_i }

      def deadline(seconds) = monotonic + seconds

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
