# frozen_string_literal: true

module Tamoz
  class CancellationToken
    DEFAULT_MAX_CALLBACKS = 1_024
    MAX_CALLBACKS = 65_536

    class Subscription
      def initialize(token, callback_id)
        @token = token
        @callback_id = callback_id
        @mutex = Mutex.new
      end

      def unsubscribe
        token = nil
        callback_id = nil
        @mutex.synchronize do
          return false unless @token

          token = @token
          callback_id = @callback_id
          @token = nil
          @callback_id = nil
        end
        token.__send__(:remove_callback, callback_id)
      end
    end

    class ClosedSubscription
      def unsubscribe
        false
      end

      INSTANCE = new.freeze
    end

    attr_reader :max_callbacks

    def initialize(max_callbacks: DEFAULT_MAX_CALLBACKS)
      unless max_callbacks.is_a?(Integer) && max_callbacks.positive? && max_callbacks <= MAX_CALLBACKS
        raise ConfigurationError, "max_callbacks must be between 1 and #{MAX_CALLBACKS}"
      end

      @max_callbacks = max_callbacks
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @cancelled = false
      @reason = nil
      @callbacks = {}
    end

    def cancel!(reason = "cancelled")
      return false if cancelled?

      callbacks = nil
      safe_reason = normalize_reason(reason)
      @mutex.synchronize do
        return false if @cancelled

        @cancelled = true
        @reason = safe_reason
        callbacks = @callbacks.values
        @callbacks = {}
        @condition.broadcast
      end

      callbacks.each do |callback|
        callback.call(safe_reason)
      rescue StandardError
        nil
      end
      true
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    def reason
      @mutex.synchronize { @reason }
    end

    def wait(timeout: nil)
      validate_timeout!(timeout)
      deadline = timeout && Clock.monotonic.now + timeout

      @mutex.synchronize do
        until @cancelled
          remaining = deadline && deadline - Clock.monotonic.now
          break if remaining && remaining <= 0

          @condition.wait(@mutex, remaining)
        end
        @cancelled
      end
    end

    def on_cancel(&callback)
      raise ArgumentError, "a cancellation callback is required" unless callback

      callback_id = nil
      reason = nil
      @mutex.synchronize do
        if @cancelled
          reason = @reason
        else
          if @callbacks.length >= max_callbacks
            raise StateLimitError, "cancellation token exceeds #{max_callbacks} callbacks"
          end
          callback_id = Object.new.freeze
          @callbacks[callback_id] = callback
        end
      end

      if reason
        begin
          callback.call(reason)
        rescue StandardError
          nil
        end
        ClosedSubscription::INSTANCE
      else
        Subscription.new(self, callback_id)
      end
    end

    private

    def remove_callback(callback_id)
      @mutex.synchronize { !@callbacks.delete(callback_id).nil? }
    end

    def normalize_reason(reason)
      SafeText.normalize(
        reason,
        name: "cancellation reason",
        max_bytes: 256,
        error_class: ArgumentError
      )
    end

    def validate_timeout!(timeout)
      return if timeout.nil?
      return if timeout.is_a?(Numeric) && timeout.finite? && !timeout.negative?

      raise ArgumentError, "timeout must be a finite non-negative number"
    end

    private_constant :Subscription, :ClosedSubscription, :DEFAULT_MAX_CALLBACKS, :MAX_CALLBACKS
  end
end
