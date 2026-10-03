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
      deadline cancellation clock notifier emitter store effects interrupts graph_runtime
      interrupt_mode episode_tools
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
      cancellation: nil,
      clock: Clock.monotonic,
      notifier: Tamoz.configuration.notifier,
      emitter: Emitter::Null::INSTANCE,
      store: nil,
      effects: nil,
      interrupts: nil,
      graph_runtime: nil,
      interrupt_mode: :interactive,
      episode_tools: nil
    )
      assign_identities(run_id:, parent_run_id:, execution_id:, request_id:, thread_id:, task_id:)
      validate_interrupt_mode!(interrupt_mode)
      @interrupt_mode = interrupt_mode
      assign_annotations(namespace:, tags:, metadata:, deadline:)
      collaborators = {
        cancellation:, clock:, notifier:, emitter:, store:, effects:, interrupts:, graph_runtime:, episode_tools:
      }
      validate_collaborators!(collaborators)
      assign_collaborators(collaborators)
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
      !!@cancellation&.cancelled?
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

    def assign_identities(ids)
      @run_id = identity!(ids.fetch(:run_id), :run_id)
      @parent_run_id = optional_identity!(ids.fetch(:parent_run_id), :parent_run_id)
      @execution_id = identity!(ids.fetch(:execution_id), :execution_id)
      @request_id = identity!(ids.fetch(:request_id), :request_id)
      @thread_id = optional_identity!(ids.fetch(:thread_id), :thread_id)
      @task_id = optional_identity!(ids.fetch(:task_id), :task_id)
    end

    def assign_annotations(namespace:, tags:, metadata:, deadline:)
      @namespace = normalize_list(namespace, :namespace, NAMESPACE_MAX_PARTS)
      @tags = normalize_list(tags, :tags, TAGS_MAX_ITEMS)
      @metadata = Immutable.copy(metadata)
      raise ConfigurationError, "metadata must be a Hash" unless @metadata.is_a?(Hash)

      @deadline = normalize_deadline(deadline)
    end

    def validate_collaborators!(collaborators)
      validate_cancellation!(collaborators.fetch(:cancellation))
      validate_capability!(collaborators.fetch(:clock), :now, "clock")
      validate_capability!(collaborators.fetch(:notifier), :instrument, "notifier")
      validate_capability!(collaborators.fetch(:emitter), :emit, "emitter")
      { interrupts: :call, graph_runtime: :call, episode_tools: :execute }.each do |name, method|
        collaborator = collaborators.fetch(name)
        validate_capability!(collaborator, method, name.to_s) if collaborator
      end
    end

    def assign_collaborators(collaborators)
      @cancellation, @clock, @notifier, @emitter, @store, @effects, @interrupts, @graph_runtime, @episode_tools =
        collaborators.values_at(:cancellation, :clock, :notifier, :emitter, :store, :effects, :interrupts,
                                :graph_runtime, :episode_tools)
    end

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

    def validate_interrupt_mode!(mode)
      return if %i[interactive non_interactive].include?(mode)

      raise ConfigurationError, "interrupt_mode must be :interactive or :non_interactive"
    end

    def validate_cancellation!(cancellation)
      return if cancellation.nil?
      return if cancellation.respond_to?(:cancelled?) && cancellation.respond_to?(:reason)

      raise ConfigurationError, "cancellation must implement cancelled? and reason"
    end

    def validate_capability!(collaborator, method, name)
      raise ConfigurationError, "#{name} must respond to #{method}" unless collaborator.respond_to?(method)
    end

    private_constant :ATTRIBUTES, :ID_MAX_BYTES, :NAMESPACE_MAX_PARTS, :TAGS_MAX_ITEMS, :UNCHANGED
  end
end
