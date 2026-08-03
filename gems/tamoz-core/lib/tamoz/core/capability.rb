# frozen_string_literal: true

# P18 — the unified capability contract (docs/P18_CAPABILITY_HOST_PLAN.md).
# Zeitwerk maps `capability.rb` -> `Tamoz::Core::Capability`; the descriptor,
# source, registry, and error live under `capability/`.
module Tamoz
  module Core
    module Capability
    end
  end
end

require_relative "capability/descriptor"
require_relative "capability/source"
require_relative "capability/registry"
require_relative "capability/descriptor_conflict_error"
