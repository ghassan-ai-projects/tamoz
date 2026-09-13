# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'thread'

module Tamoz
  module Observability
    module Recorder
      class Null
        INSTANCE = new.freeze

        def record(_signal) = :dropped

        def health
          {
            'enabled' => false,
            'reserved_depth' => 0,
            'bulk_depth' => 0,
            'drops' => {},
            'journal_disabled' => false
          }
        end

        def flush(deadline_ms:) = 0
        def close = nil
      end

      class Memory
        include DropLedger

        attr_reader :signals

        def initialize(max_size: 1_024, catalog: Catalog, strict: false, policy_digest: nil)
          @max_size = Integer(max_size)
          raise ValidationError, 'max_size must be positive' unless @max_size.positive?
          @catalog = catalog
          @strict = strict
          @policy_digest = policy_digest
          @signals = []
          @drops = Hash.new(0)
          @mutex = Mutex.new
        end

        def record(signal) = guard_record(signal) { store(signal) }

        def health
          synchronize do
            {
              'enabled' => true,
              'reserved_depth' => 0,
              'bulk_depth' => @signals.length,
              'drops' => drops_hash,
              'journal_disabled' => false,
              'policy_digest' => @policy_digest
            }
          end
        end

        def flush(deadline_ms:) = 0
        def close = nil

        private

        def synchronize(&block) = @mutex.synchronize(&block)

        def store(signal)
          synchronize do
            return drop_queue_full(signal) if queue_full?

            @signals << signal
            :recorded
          end
        end

        def queue_full?
          @signals.length >= @max_size
        end

        def drop_queue_full(signal)
          @drops[drop_key(signal.name, 'queue_full', 'bulk')] += 1
          :dropped
        end
      end

      class Fanout
        # A child recorder that raises is unavailable, not a signal drop: the
        # fallback each guarded call carries keeps that failure inside the
        # method's own contract (a count of 0 unflushed, an unavailable health
        # entry) instead of leaking a :dropped sentinel into arithmetic or JSON.
        UNAVAILABLE_HEALTH = { 'enabled' => false, 'error' => 'unavailable' }.freeze

        def initialize(recorders)
          @recorders = Array(recorders).compact.freeze
        end

        def record(signal)
          results = @recorders.map { |recorder| guarded(:dropped) { recorder.record(signal) } }
          results.include?(:recorded) ? :recorded : :dropped
        end

        def health
          @recorders.each_with_index.to_h do |recorder, index|
            [index.to_s, guarded(UNAVAILABLE_HEALTH) { recorder.health }]
          end
        end

        def flush(deadline_ms:)
          @recorders.sum { |recorder| guarded(0) { Integer(recorder.flush(deadline_ms:)) } }
        end

        def close
          @recorders.each { |recorder| guarded(nil) { recorder.close if recorder.respond_to?(:close) } }
          nil
        end

        private

        def guarded(fallback)
          yield
        rescue StandardError
          fallback
        end
      end
    end
  end
end
