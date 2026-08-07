# frozen_string_literal: true

require_relative "memory_checkpointer/writer"

module Tamoz
  module Graph
    class MemoryCheckpointer
      CHECKPOINT_PROTOCOL_VERSION = 1
      DEFAULT_MAX_THREADS = 10_000
      MAX_THREADS = 100_000
      DEFAULT_MAX_CHECKPOINTS_PER_NAMESPACE = 100_000
      MAX_CHECKPOINTS_PER_NAMESPACE = 1_000_000
      MAX_RUNTIME_ID_BYTES = 256
      MAX_NAMESPACE_PARTS = 128

      def initialize(
        max_threads: DEFAULT_MAX_THREADS,
        max_checkpoints_per_namespace: DEFAULT_MAX_CHECKPOINTS_PER_NAMESPACE
      )
        unless max_threads.is_a?(Integer) && max_threads.positive? && max_threads <= MAX_THREADS
          raise ConfigurationError, "max_threads must be between 1 and #{MAX_THREADS}"
        end
        unless max_checkpoints_per_namespace.is_a?(Integer) &&
               max_checkpoints_per_namespace.positive? &&
               max_checkpoints_per_namespace <= MAX_CHECKPOINTS_PER_NAMESPACE
          raise ConfigurationError,
                "max_checkpoints_per_namespace must be between 1 and " \
                "#{MAX_CHECKPOINTS_PER_NAMESPACE}"
        end

        @max_threads = max_threads
        @max_checkpoints_per_namespace = max_checkpoints_per_namespace
        @mutex = Mutex.new
        @history = {}
        @locks = {}
      end

      def checkpoint_protocol_version = CHECKPOINT_PROTOCOL_VERSION
      def durable? = false

      def open_writer(thread_id:, namespace:, owner_id:, ttl:)
        address = normalize_address(thread_id, namespace)
        SafeText.normalize(
          owner_id,
          name: "writer owner id",
          max_bytes: MAX_RUNTIME_ID_BYTES,
          error_class: ConfigurationError
        )
        unless ttl.is_a?(Numeric) && ttl.finite? && ttl.positive?
          raise ConfigurationError, "writer ttl must be a positive finite number"
        end

        lock = @mutex.synchronize do
          ensure_address_capacity!(address)
          @locks[address] ||= Mutex.new
        end
        lock.synchronize { yield Writer.new(self, address) }
      end

      def synchronize(thread_id:, namespace:)
        open_writer(
          thread_id:,
          namespace:,
          owner_id: "memory.compatibility",
          ttl: 1
        ) do
          yield
        end
      end

      def latest(thread_id:, namespace: [])
        address = normalize_address(thread_id, namespace)
        @mutex.synchronize { @history.fetch(address, []).last }
      end

      def find(thread_id:, namespace: [], checkpoint_id:)
        address = normalize_address(thread_id, namespace)
        @mutex.synchronize do
          @history.fetch(address, []).find { |checkpoint| checkpoint.id == checkpoint_id }
        end
      end

      def history(thread_id:, namespace: [], limit:)
        unless limit.is_a?(Integer) && limit.positive?
          raise ConfigurationError, "history limit must be positive"
        end

        address = normalize_address(thread_id, namespace)
        @mutex.synchronize { @history.fetch(address, []).last(limit).reverse.freeze }
      end

      def append(
        thread_id:,
        namespace:,
        expected_base_id:,
        mode:,
        attributes:
      )
        address = normalize_address(thread_id, namespace)
        @mutex.synchronize do
          ensure_address_capacity!(address)
          entries = (@history[address] ||= [])
          if entries.length >= @max_checkpoints_per_namespace
            raise StateLimitError,
                  "memory checkpointer exceeds #{@max_checkpoints_per_namespace} " \
                  "checkpoints for one thread namespace"
          end
          base = expected_base_id && entries.find { |checkpoint| checkpoint.id == expected_base_id }
          validate_append!(entries, base, expected_base_id, mode)
          sequence = entries.length
          immutable_attributes = freeze_value(attributes)
          checkpoint_id = checkpoint_id_for(
            immutable_attributes.merge(
              thread_id: address.first,
              namespace: address.last,
              sequence: sequence,
              parent_id: base&.id
            )
          ).freeze
          frontier = immutable_attributes.fetch(:frontier).map do |entry|
            entry.activation_checkpoint_id ? entry : entry.with_activation_checkpoint(checkpoint_id)
          end.freeze
          checkpoint = Checkpoint.new(
            format_version: 1,
            id: checkpoint_id,
            sequence:,
            thread_id: address.first,
            namespace: address.last,
            parent_id: base&.id,
            frontier:,
            **immutable_attributes.except(:frontier)
          )
          entries << checkpoint
          checkpoint
        end
      end

      private

      def normalize_address(thread_id, namespace)
        thread_value = SafeText.normalize(
          thread_id,
          name: "thread id",
          max_bytes: MAX_RUNTIME_ID_BYTES,
          error_class: ConfigurationError
        )
        unless namespace.is_a?(Array) && namespace.length <= MAX_NAMESPACE_PARTS
          raise ConfigurationError,
                "namespace must contain at most #{MAX_NAMESPACE_PARTS} parts"
        end
        namespace_value = namespace.map do |part|
          SafeText.normalize(
            part,
            name: "namespace part",
            max_bytes: MAX_RUNTIME_ID_BYTES,
            error_class: ConfigurationError
          )
        end.freeze
        [thread_value, namespace_value].freeze
      end

      def ensure_address_capacity!(address)
        return if @locks.key?(address) || @history.key?(address)

        addresses = (@locks.keys | @history.keys).length
        return if addresses < @max_threads

        raise StateLimitError, "memory checkpointer exceeds #{@max_threads} thread namespaces"
      end

      def freeze_value(value)
        case value
        when String
          value.dup.freeze
        when Array
          value.map { |entry| freeze_value(entry) }.freeze
        when Hash
          value.to_h do |key, entry|
            frozen_key = key.is_a?(String) ? key.dup.freeze : key
            [frozen_key, freeze_value(entry)]
          end.freeze
        else
          unless value.frozen?
            raise ConfigurationError,
                  "checkpoint attributes must contain only immutable values; got #{value.class}"
          end
          value
        end
      end

      def validate_append!(entries, base, expected_base_id, mode)
        case mode
        when :start
          raise CheckpointConflictError, "thread namespace already exists" unless entries.empty?
        when :advance, :turn
          unless base && entries.last&.id == expected_base_id
            raise CheckpointConflictError, "checkpoint base is not the active tip"
          end
        when :fork
          raise CheckpointConflictError, "fork source checkpoint does not exist" unless base
        else
          raise ConfigurationError, "unknown checkpoint append mode #{mode.inspect}"
        end
      end

      def checkpoint_id_for(attributes)
        serializable = attributes.to_h do |key, value|
          normalized = case value
                       when Array
                         value.map { |entry| descriptor_for(entry) }
                       when Hash
                         value.transform_values { |entry| descriptor_for(entry) }
                       else
                         descriptor_for(value)
                       end
          [key.to_s, normalized]
        end
        Canonical.digest(serializable, domain: "tamoz.graph.checkpoint")
      end

      def descriptor_for(value)
        if value.is_a?(Interrupt)
          return {
            "task_id" => value.task_id,
            "call_index" => value.call_index,
            "descriptor" => value.descriptor
          }
        end
        if value.is_a?(Frontier) || value.is_a?(Outcome) || value.is_a?(Task)
          return value.descriptor
        end
        if value.is_a?(Hash)
          return value.to_h do |key, entry|
            [key.to_s, descriptor_for(entry)]
          end
        end
        return value.map { |entry| descriptor_for(entry) } if value.is_a?(Array)
        return value.to_s if value.is_a?(Symbol)
        return value.id if value.is_a?(Checkpoint)

        value
      end

      private_constant :DEFAULT_MAX_THREADS, :MAX_THREADS,
                       :DEFAULT_MAX_CHECKPOINTS_PER_NAMESPACE,
                       :MAX_CHECKPOINTS_PER_NAMESPACE,
                       :MAX_RUNTIME_ID_BYTES, :MAX_NAMESPACE_PARTS, :Writer
    end
  end
end
