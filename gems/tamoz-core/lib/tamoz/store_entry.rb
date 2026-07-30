# frozen_string_literal: true

module Tamoz
  StoreEntry = Data.define(
    :namespace,
    :key,
    :version,
    :value,
    :sensitive,
    :deleted,
    :created_at_ms
  ) do
    def initialize(
      namespace:,
      key:,
      version:,
      value:,
      sensitive:,
      deleted:,
      created_at_ms:
    )
      unless namespace.is_a?(String) && namespace.frozen? &&
             key.is_a?(String) && key.frozen? &&
             version.is_a?(Integer) && version.positive? &&
             (sensitive == true || sensitive == false) &&
             (deleted == true || deleted == false) &&
             created_at_ms.is_a?(Integer) && !created_at_ms.negative?
        raise CheckpointCorruptionError, "stored entry metadata is invalid"
      end
      raise CheckpointCorruptionError, "deleted entry has a value" if deleted && !value.nil?

      super
      freeze
    end
  end
end
