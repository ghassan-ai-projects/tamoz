# frozen_string_literal: true

module Tamoz
  module Core
    module Capability
      # P18 §6 — a forged/extra source registration, or a cross-source
      # descriptor id collision. The registry is sealed; refused (typed).
      class DescriptorConflictError < Tamoz::Error
        CATEGORY = "descriptor_conflict"
        RETRYABLE = false
      end
    end
  end
end
