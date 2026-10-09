# frozen_string_literal: true

require 'digest'

module Tamoz
  module Talk
    # Speech for delivered messages: synthesized once per message and text, kept in memory only.
    class Speaker
      MAX_CACHED = 32
      MAX_TEXTS = 500
      WAIT_S = 15.0
      RETRY_AFTER_S = 30.0
      PREFETCH_QUEUE = 4

      def initialize(synthesize:)
        @synthesize = synthesize
        @texts = {}
        @cache = {}
        @inflight = {}
        @failed = {}
        @queue = SizedQueue.new(PREFETCH_QUEUE)
        @mutex = Mutex.new
        @done = ConditionVariable.new
      end

      def enabled? = !@synthesize.nil?

      def register(message_id, text)
        @mutex.synchronize do
          @texts[message_id] = text
          @texts.shift while @texts.length > MAX_TEXTS
        end
      end

      # @return [String, Symbol] the mp3 bytes, :not_spoken or :failed
      def speech(message_id)
        key = @mutex.synchronize do
          text = @texts[message_id]
          return :not_spoken unless text && enabled?

          [message_id, Digest::SHA256.hexdigest(text), text]
        end
        fetch(key)
      end

      # One worker, a short queue: prefetch never stacks up paid calls; a full queue simply skips the prefetch.
      def prefetch(message_id)
        return unless enabled?

        @mutex.synchronize { @prefetcher ||= Thread.new { loop { speech(@queue.pop) } } }
        @queue.push(message_id, true)
      rescue ThreadError
        nil
      end

      private

      def fetch((id, digest, text))
        cache_key = [id, digest]
        @mutex.synchronize do
          deadline = monotonic + WAIT_S
          while @inflight[cache_key]
            left = deadline - monotonic
            return :failed unless left.positive?

            @done.wait(@mutex, left)
          end
          return @cache[cache_key] if @cache.key?(cache_key)
          return :failed if @failed[cache_key] && monotonic - @failed[cache_key] < RETRY_AFTER_S

          @inflight[cache_key] = true
        end
        audio = :failed
        begin
          audio = synthesize(text)
        ensure
          settle(cache_key, audio)
        end
        audio
      end

      def settle(cache_key, audio)
        @mutex.synchronize do
          audio == :failed ? @failed[cache_key] = monotonic : remember(cache_key, audio)
          @failed.shift while @failed.length > MAX_CACHED
          @inflight.delete(cache_key)
          @done.broadcast
        end
      end

      def synthesize(text)
        @synthesize.call(text)
      rescue StandardError => e
        warn "tamoz: speech synthesis failed (#{e.class})"
        :failed
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def remember(key, audio)
        @cache[key] = audio
        @cache.shift while @cache.length > MAX_CACHED
      end
    end
  end
end
