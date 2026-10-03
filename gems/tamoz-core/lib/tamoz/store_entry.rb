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
    def initialize(**)
      super
      raise CheckpointCorruptionError, "stored entry metadata is invalid" unless valid_metadata?
      raise CheckpointCorruptionError, "deleted entry has a value" if deleted && !value.nil?

      freeze
    end

    private

    def valid_metadata?
      frozen_string?(namespace) && frozen_string?(key) && positive_integer?(version) &&
        boolean?(sensitive) && boolean?(deleted) && created_at_ms.is_a?(Integer) && !created_at_ms.negative?
    end

    def frozen_string?(value)
      value.is_a?(String) && value.frozen?
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def boolean?(value)
      [true, false].include?(value)
    end
  end
end
