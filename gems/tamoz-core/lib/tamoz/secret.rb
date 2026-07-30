# frozen_string_literal: true

module Tamoz
  class Secret
    def initialize(value)
      @value = value.is_a?(String) ? value.dup.freeze : value
      freeze
    end

    def reveal
      @value
    end

    def inspect
      "#<Tamoz::Secret [REDACTED]>"
    end

    def to_s
      "[REDACTED]"
    end
  end
end
