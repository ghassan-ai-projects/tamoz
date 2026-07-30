# frozen_string_literal: true

module Tamoz
  class Configuration
    CONCURRENCY_MODES = %i[inline threads].freeze
    MAX_POOL_SIZE = 256
    MAX_RECURSION_LIMIT = 1_000_000
    MAX_STREAM_BUFFER = 65_536

    attr_reader :concurrency, :pool_size, :recursion_limit, :stream_buffer, :notifier

    def initialize(
      concurrency: :threads,
      pool_size: 8,
      recursion_limit: 200,
      stream_buffer: 32,
      notifier: Notifier::Null::INSTANCE
    )
      unless CONCURRENCY_MODES.include?(concurrency)
        raise ConfigurationError, "concurrency must be one of #{CONCURRENCY_MODES.inspect}"
      end

      @concurrency = concurrency
      @pool_size = bounded_integer!(pool_size, :pool_size, MAX_POOL_SIZE)
      @recursion_limit = bounded_integer!(
        recursion_limit,
        :recursion_limit,
        MAX_RECURSION_LIMIT
      )
      @stream_buffer = bounded_integer!(
        stream_buffer,
        :stream_buffer,
        MAX_STREAM_BUFFER
      )
      unless notifier.respond_to?(:instrument)
        raise ConfigurationError, "notifier must respond to instrument"
      end

      @notifier = notifier
      freeze
    end

    def to_builder
      Builder.new(self)
    end

    class Builder
      attr_accessor :concurrency, :pool_size, :recursion_limit, :stream_buffer, :notifier

      def initialize(configuration)
        @concurrency = configuration.concurrency
        @pool_size = configuration.pool_size
        @recursion_limit = configuration.recursion_limit
        @stream_buffer = configuration.stream_buffer
        @notifier = configuration.notifier
      end

      def build
        Configuration.new(
          concurrency:,
          pool_size:,
          recursion_limit:,
          stream_buffer:,
          notifier:
        )
      end
    end

    private

    def bounded_integer!(value, name, maximum)
      unless value.is_a?(Integer) && value.positive? && value <= maximum
        raise ConfigurationError, "#{name} must be between 1 and #{maximum}"
      end

      value
    end

    private_constant :Builder
  end

  @configuration_mutex = Mutex.new
  @configuration = Configuration.new
  @configuration_generation = 0
  @configuration_finalized = false

  class << self
    def configuration
      @configuration_mutex.synchronize { @configuration }
    end

    def configure
      raise ArgumentError, "a configuration block is required" unless block_given?

      base, generation = @configuration_mutex.synchronize do
        raise ConfigurationError, "Tamoz configuration is finalized" if @configuration_finalized

        [@configuration, @configuration_generation]
      end
      builder = base.to_builder
      yield builder
      candidate = builder.build

      @configuration_mutex.synchronize do
        raise ConfigurationError, "Tamoz configuration is finalized" if @configuration_finalized
        unless generation == @configuration_generation
          raise ConfigurationError, "Tamoz configuration changed concurrently"
        end

        @configuration = candidate
        @configuration_generation += 1
      end
      candidate
    end

    def finalize_configuration!
      @configuration_mutex.synchronize do
        @configuration_finalized = true
        @configuration
      end
    end

    def configuration_finalized?
      @configuration_mutex.synchronize { @configuration_finalized }
    end
  end
end
