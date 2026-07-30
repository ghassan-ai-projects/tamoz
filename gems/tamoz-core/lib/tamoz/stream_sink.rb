# frozen_string_literal: true

module Tamoz
  class StreamSink
    MAX_CAPACITY = Configuration::MAX_STREAM_BUFFER
    DEFAULT_MAX_NAMESPACES = 1_024
    MAX_NAMESPACES = 65_536

    attr_reader :capacity, :cancellation, :max_namespaces

    def initialize(
      capacity: Tamoz.configuration.stream_buffer,
      cancellation: CancellationToken.new,
      clock: Clock.monotonic,
      run_id: nil,
      task_id: nil,
      max_namespaces: DEFAULT_MAX_NAMESPACES
    )
      unless capacity.is_a?(Integer) && capacity.positive? && capacity <= MAX_CAPACITY
        raise ConfigurationError, "stream capacity must be between 1 and #{MAX_CAPACITY}"
      end
      unless cancellation.respond_to?(:cancelled?) &&
             cancellation.respond_to?(:cancel!) &&
             cancellation.respond_to?(:on_cancel)
        raise ConfigurationError, "stream cancellation token is invalid"
      end
      raise ConfigurationError, "stream clock must respond to now" unless clock.respond_to?(:now)
      unless max_namespaces.is_a?(Integer) &&
             max_namespaces.positive? &&
             max_namespaces <= MAX_NAMESPACES
        raise ConfigurationError, "max_namespaces must be between 1 and #{MAX_NAMESPACES}"
      end

      @capacity = capacity
      @max_namespaces = max_namespaces
      @cancellation = cancellation
      @clock = clock
      @default_run_id = run_id
      @default_task_id = task_id
      @queue = SizedQueue.new(capacity)
      @state_mutex = Mutex.new
      @emit_mutex = Mutex.new
      @sequences = {}
      @consumer_started = false
      @finished = false
      @closed_reason = nil
      @cancellation_subscription = cancellation.on_cancel do |reason|
        close_from_cancellation(reason)
      end
    end

    def emit(type, namespace, data = {}, run_id: nil, task_id: nil)
      @emit_mutex.synchronize do
        actual_run_id = run_id || @default_run_id
        actual_task_id = task_id.nil? ? @default_task_id : task_id
        normalized_namespace = normalize_namespace(namespace)
        candidate = StreamPart.new(
          type:,
          namespace: normalized_namespace,
          run_id: actual_run_id,
          task_id: actual_task_id,
          sequence: 0,
          data:,
          emitted_at: @clock.now
        )
        sequence = reserve_sequence!(normalized_namespace)
        part = candidate.with(sequence:)
        @queue.push(part)
        part
      end
    rescue ClosedQueueError
      raise StreamClosedError, "stream closed before emission was accepted"
    end

    def each
      return enum_for(:each) unless block_given?

      begin_consumer!
      naturally_completed = false
      begin
        loop do
          break if cancellation.cancelled?

          part = @queue.pop
          if part.nil?
            naturally_completed = true
            break
          end
          yield part
        end
      ensure
        close(reason: "consumer_closed") unless naturally_completed || cancellation.cancelled?
      end
      self
    end

    def finish
      subscription = nil
      changed = @state_mutex.synchronize do
        return false if @queue.closed?

        @finished = true
        @queue.close
        subscription = @cancellation_subscription
        @cancellation_subscription = nil
        true
      end
      subscription&.unsubscribe
      changed
    end

    def close(reason: "stream_closed")
      return false if finished?

      safe_reason = normalize_reason(reason)
      subscription = nil
      changed = @state_mutex.synchronize do
        return false if @finished

        unless @queue.closed?
          @closed_reason = safe_reason
          @queue.close
        end
        subscription = @cancellation_subscription
        @cancellation_subscription = nil
        true
      end
      subscription&.unsubscribe
      cancellation.cancel!(safe_reason)
      changed
    end

    def closed?
      @queue.closed?
    end

    def finished?
      @state_mutex.synchronize { @finished }
    end

    def closed_reason
      @state_mutex.synchronize { @closed_reason }
    end

    def size
      @queue.length
    end

    private

    def reserve_sequence!(namespace)
      @state_mutex.synchronize do
        if @queue.closed? || cancellation.cancelled?
          raise StreamClosedError, "stream is closed"
        end

        sequence = @sequences.fetch(namespace, 0)
        if sequence.zero? && !@sequences.key?(namespace) && @sequences.length >= max_namespaces
          raise StateLimitError, "stream exceeds #{max_namespaces} namespaces"
        end
        @sequences[namespace] = sequence + 1
        sequence
      end
    end

    def normalize_namespace(namespace)
      unless namespace.is_a?(Array) &&
             namespace.length <= StreamPartContract::MAX_NAMESPACE_PARTS
        raise ConfigurationError, "stream namespace is invalid"
      end

      namespace.map do |part|
        SafeText.normalize(
          part,
          name: "stream namespace part",
          max_bytes: StreamPartContract::MAX_ID_BYTES,
          error_class: ConfigurationError
        )
      end.freeze
    end

    def begin_consumer!
      @state_mutex.synchronize do
        raise ConfigurationError, "StreamSink supports exactly one consumer" if @consumer_started

        @consumer_started = true
      end
    end

    def close_from_cancellation(reason)
      safe_reason = normalize_reason(reason)
    rescue StandardError
      safe_reason = "cancelled".freeze
    ensure
      @state_mutex.synchronize do
        @closed_reason ||= safe_reason
        @queue.close unless @queue.closed?
        @cancellation_subscription = nil
      end
    end

    def normalize_reason(reason)
      SafeText.normalize(
        reason,
        name: "stream close reason",
        max_bytes: 256,
        error_class: ArgumentError
      )
    end

    private_constant :DEFAULT_MAX_NAMESPACES, :MAX_NAMESPACES
  end
end
