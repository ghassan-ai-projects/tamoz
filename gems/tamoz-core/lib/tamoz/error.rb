# frozen_string_literal: true

module Tamoz
  # Marker for failures that invalidate runtime coordination rather than one user task.
  # Pools preserve these as TaskResult::Fatal so executors cannot turn storage ownership
  # or corruption failures into ordinary node results.
  module FatalRuntimeFailure
  end

  class Error < StandardError
    module Metadata
      attr_reader :category, :safe_message

      def initialize(message = nil)
        @category = self.class::CATEGORY
        @retryable = self.class::RETRYABLE
        @user_visible = self.class::USER_VISIBLE
        @safe_message = self.class::SAFE_MESSAGE
        super(message || @safe_message)
      end

      def retryable?
        @retryable
      end

      def user_visible?
        @user_visible
      end

      def inspect
        "#<#{self.class} category=#{category.inspect} retryable=#{retryable?} " \
          "user_visible=#{user_visible?} safe_message=#{safe_message.inspect}>"
      end
    end

    CATEGORY = "operational"
    RETRYABLE = false
    USER_VISIBLE = false
    SAFE_MESSAGE = "The operation could not be completed."

    include Metadata
  end

  class TimeoutError < Error
    CATEGORY = "timeout"
    RETRYABLE = true
    USER_VISIBLE = true
    SAFE_MESSAGE = "The operation timed out."
  end

  class CancelledError < Error
    CATEGORY = "cancelled"
    RETRYABLE = false
    USER_VISIBLE = true
    SAFE_MESSAGE = "The operation was cancelled."
  end

  class NodeError < Error
    CATEGORY = "node"
    SAFE_MESSAGE = "A workflow step failed."

    attr_reader :graph_name, :node, :task_id, :attempt_id, :original

    def initialize(
      message = nil,
      graph_name: nil,
      node: nil,
      task_id: nil,
      attempt_id: nil,
      original: nil
    )
      @graph_name = graph_name&.to_s&.dup&.freeze
      @node = node&.to_s&.dup&.freeze
      @task_id = task_id&.to_s&.dup&.freeze
      @attempt_id = attempt_id&.to_s&.dup&.freeze
      @original = original
      super(message)
      set_backtrace(original.backtrace) if original&.backtrace
    end
  end

  class CheckpointError < Error
    include FatalRuntimeFailure

    CATEGORY = "checkpoint"
    SAFE_MESSAGE = "Workflow state could not be read or written."
  end

  class CheckpointConflictError < CheckpointError
    CATEGORY = "checkpoint_conflict"
    RETRYABLE = true
    SAFE_MESSAGE = "Workflow state changed concurrently."
  end

  class CheckpointVersionError < CheckpointError
    CATEGORY = "checkpoint_version"
    SAFE_MESSAGE = "The workflow state version is unsupported."
  end

  class CheckpointCorruptionError < CheckpointError
    CATEGORY = "checkpoint_corruption"
    SAFE_MESSAGE = "The workflow state is invalid or corrupted."
  end

  class LeaseLostError < Error
    include FatalRuntimeFailure

    CATEGORY = "lease_lost"
    RETRYABLE = true
    SAFE_MESSAGE = "Workflow ownership was lost."
  end

  class EffectUnknownError < Error
    CATEGORY = "effect_unknown"
    SAFE_MESSAGE = "An external operation has an unknown outcome."
  end

  class StoreError < Error
    include FatalRuntimeFailure

    CATEGORY = "store"
    RETRYABLE = true
    SAFE_MESSAGE = "The runtime store is unavailable."
  end

  class StoreConflictError < StoreError
    CATEGORY = "store_conflict"
    RETRYABLE = true
    SAFE_MESSAGE = "The stored value changed concurrently."
  end

  class StoreCapabilityError < StoreError
    CATEGORY = "store_capability"
    RETRYABLE = false
    SAFE_MESSAGE = "The requested store capability is unavailable."
  end

  class StreamClosedError < Error
    CATEGORY = "stream_closed"
    SAFE_MESSAGE = "The execution stream is closed."
  end

  class PoolCircuitOpenError < Error
    CATEGORY = "pool_circuit_open"
    SAFE_MESSAGE = "The execution pool is unavailable after stuck work."
  end

  class PoolWorkerError < Error
    CATEGORY = "pool_worker"
    SAFE_MESSAGE = "An execution worker failed."
  end

  class ConfigurationError < StandardError
    CATEGORY = "configuration"
    RETRYABLE = false
    USER_VISIBLE = false
    SAFE_MESSAGE = "Tamoz is configured incorrectly."

    include Error::Metadata
  end

  class GraphDefinitionError < StandardError
    CATEGORY = "graph_definition"
    RETRYABLE = false
    USER_VISIBLE = false
    SAFE_MESSAGE = "The graph definition is invalid."

    include Error::Metadata
  end

  class InvalidUpdateError < StandardError
    CATEGORY = "invalid_update"
    RETRYABLE = false
    USER_VISIBLE = false
    SAFE_MESSAGE = "The state update is invalid."

    include Error::Metadata
  end

  class UnsupportedValueError < InvalidUpdateError
    CATEGORY = "unsupported_value"
    SAFE_MESSAGE = "The value cannot cross the durable state boundary."
  end

  class SensitiveValueError < InvalidUpdateError
    CATEGORY = "sensitive_value"
    SAFE_MESSAGE = "Sensitive data requires an explicit protection policy."
  end

  class StateLimitError < InvalidUpdateError
    CATEGORY = "state_limit"
    SAFE_MESSAGE = "The value exceeds a configured state limit."
  end

  class RecursionLimitError < StandardError
    CATEGORY = "recursion_limit"
    RETRYABLE = false
    USER_VISIBLE = false
    SAFE_MESSAGE = "The workflow recursion limit was reached."

    include Error::Metadata
  end

  Error.private_constant :Metadata
end
