# frozen_string_literal: true

require "securerandom"

module Tamoz
  class Context
    ID_MAX_BYTES = 256
    NAMESPACE_MAX_PARTS = 128
    TAGS_MAX_ITEMS = 64
    UNCHANGED = Object.new.freeze

    ATTRIBUTES = %i[
      run_id parent_run_id execution_id request_id thread_id namespace task_id tags metadata
      deadline cancellation clock notifier emitter store effects
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(
      run_id:,
      execution_id:,
      request_id:,
      parent_run_id: nil,
      thread_id: nil,
      namespace: [],
      task_id: nil,
      tags: [],
      metadata: {},
      deadline: nil,
      cancellation: CancellationToken.new,
      clock: Clock.monotonic,
      notifier: Tamoz.configuration.notifier,
      emitter: Emitter::Null::INSTANCE,
      store: nil,
      effects: nil
    )
      @run_id = identity!(run_id, :run_id)
      @parent_run_id = optional_identity!(parent_run_id, :parent_run_id)
      @execution_id = identity!(execution_id, :execution_id)
      @request_id = identity!(request_id, :request_id)
      @thread_id = optional_identity!(thread_id, :thread_id)
      @task_id = optional_identity!(task_id, :task_id)
      @namespace = normalize_list(namespace, :namespace, NAMESPACE_MAX_PARTS)
      @tags = normalize_list(tags, :tags, TAGS_MAX_ITEMS)
      @metadata = Immutable.copy(metadata)
      raise ConfigurationError, "metadata must be a Hash" unless @metadata.is_a?(Hash)

      @deadline = normalize_deadline(deadline)
      unless cancellation.respond_to?(:cancelled?) && cancellation.respond_to?(:reason)
        raise ConfigurationError, "cancellation must implement cancelled? and reason"
      end
      raise ConfigurationError, "clock must respond to now" unless clock.respond_to?(:now)
      unless notifier.respond_to?(:instrument)
        raise ConfigurationError, "notifier must respond to instrument"
      end
      raise ConfigurationError, "emitter must respond to emit" unless emitter.respond_to?(:emit)

      @cancellation = cancellation
      @clock = clock
      @notifier = notifier
      @emitter = emitter
      @store = store
      @effects = effects
      freeze
    end

    def with(**changes)
      unknown = changes.keys - ATTRIBUTES
      raise ArgumentError, "unknown Context fields: #{unknown.sort.inspect}" unless unknown.empty?

      self.class.new(**attributes.merge(changes))
    end

    def child(name, task_id: UNCHANGED, run_id: SecureRandom.uuid)
      component = identity!(name, :child_name)
      next_task_id = task_id.equal?(UNCHANGED) ? @task_id : task_id

      with(
        run_id:,
        parent_run_id: @run_id,
        namespace: [*@namespace, component],
        task_id: next_task_id
      )
    end

    def emit(type, data = {})
      @emitter.emit(
        type,
        @namespace,
        Immutable.copy(data),
        run_id: @run_id,
        task_id: @task_id
      )
    end

    def expired?
      return false unless @deadline

      now = @clock.now
      unless now.is_a?(Numeric) && now.finite?
        raise ConfigurationError, "clock.now must return a finite number"
      end

      now >= @deadline
    end

    def cancelled?
      !!@cancellation.cancelled?
    end

    def check!
      if cancelled?
        raise CancelledError, "operation cancelled"
      end
      raise TimeoutError, "monotonic deadline expired" if expired?

      true
    end

    def inspect
      "#<Tamoz::Context run_id=#{run_id.inspect} execution_id=#{execution_id.inspect} " \
        "request_id=#{request_id.inspect} thread_id=#{thread_id.inspect} " \
        "namespace=#{namespace.inspect} task_id=#{task_id.inspect} tags=#{tags.inspect} " \
        "metadata_keys=#{metadata.keys.map(&:to_s).sort.inspect} deadline=#{deadline.inspect}>"
    end

    private

    def attributes
      ATTRIBUTES.to_h { |name| [name, public_send(name)] }
    end

    def identity!(value, name)
      SafeText.normalize(
        value,
        name:,
        max_bytes: ID_MAX_BYTES,
        error_class: ConfigurationError
      )
    end

    def optional_identity!(value, name)
      value.nil? ? nil : identity!(value, name)
    end

    def normalize_list(value, name, maximum)
      raise ConfigurationError, "#{name} must be an Array" unless value.is_a?(Array)
      raise ConfigurationError, "#{name} exceeds #{maximum} items" if value.length > maximum

      value.map.with_index { |entry, index| identity!(entry, "#{name}[#{index}]") }.freeze
    end

    def normalize_deadline(value)
      return nil if value.nil?
      return value if value.is_a?(Numeric) && value.finite? && !value.negative?

      raise ConfigurationError, "deadline must be a finite non-negative monotonic value"
    end

    private_constant :ATTRIBUTES, :ID_MAX_BYTES, :NAMESPACE_MAX_PARTS, :TAGS_MAX_ITEMS, :UNCHANGED
  end
end
