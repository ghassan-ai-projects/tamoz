# frozen_string_literal: true

module Tamoz
  module StreamPartContract
    CORE_TYPES = %i[
      run_start run_end task_start task_end node_update message_chunk tool_start
      tool_progress tool_end interrupt checkpoint effect_unknown error custom
    ].freeze
    # P1/§8.2: the episode model/decision vocabulary on the trusted wire
    # channel. Graph nodes never emit these (the projection adapter rejects
    # them from the Context emitter); the trusted effect adapter produces them
    # from journal receipts.
    EPISODE_TYPES = %i[
      model_started model_delta model_completed decision terminal
    ].freeze
    ALL_TYPES = (CORE_TYPES + EPISODE_TYPES).freeze
    TYPE_LOOKUP = ALL_TYPES.to_h { |type| [type.to_s, type] }.freeze
    MAX_NAMESPACE_PARTS = 128
    MAX_ID_BYTES = 256
  end

  StreamPart = Data.define(
    :type,
    :namespace,
    :run_id,
    :task_id,
    :sequence,
    :data,
    :emitted_at
  ) do
    def initialize(type:, namespace:, run_id:, task_id: nil, sequence:, data: {}, emitted_at:)
      normalized_type = StreamPartContract::TYPE_LOOKUP[String(type)]
      unless normalized_type
        raise ConfigurationError,
              "stream type must be one of #{StreamPartContract::CORE_TYPES.inspect}"
      end
      unless namespace.is_a?(Array) &&
             namespace.length <= StreamPartContract::MAX_NAMESPACE_PARTS
        raise ConfigurationError,
              "stream namespace must contain at most " \
              "#{StreamPartContract::MAX_NAMESPACE_PARTS} parts"
      end
      normalized_namespace = namespace.map.with_index do |part, index|
        normalize_identity(part, "namespace[#{index}]")
      end.freeze
      normalized_run_id = normalize_identity(run_id, "run_id")
      normalized_task_id = task_id.nil? ? nil : normalize_identity(task_id, "task_id")
      unless sequence.is_a?(Integer) && !sequence.negative?
        raise ConfigurationError, "stream sequence must be a non-negative integer"
      end
      unless emitted_at.is_a?(Numeric) && emitted_at.finite? && !emitted_at.negative?
        raise ConfigurationError, "stream emitted_at must be a finite non-negative number"
      end

      super(
        type: normalized_type,
        namespace: normalized_namespace,
        run_id: normalized_run_id,
        task_id: normalized_task_id,
        sequence:,
        data: Immutable.copy(data),
        emitted_at:
      )
    end

    def inspect
      shape = data.is_a?(Hash) ? "keys=#{data.keys.map(&:to_s).sort.inspect}" : "class=#{data.class}"
      "#<Tamoz::StreamPart type=#{type.inspect} namespace=#{namespace.inspect} " \
        "run_id=#{run_id.inspect} task_id=#{task_id.inspect} sequence=#{sequence} " \
        "data=[REDACTED #{shape}] emitted_at=#{emitted_at.inspect}>"
    end

    private

    def normalize_identity(value, name)
      SafeText.normalize(
        value,
        name:,
        max_bytes: StreamPartContract::MAX_ID_BYTES,
        error_class: ConfigurationError
      )
    end
  end

  private_constant :StreamPartContract
end
