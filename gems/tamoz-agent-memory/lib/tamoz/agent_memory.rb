# frozen_string_literal: true

# The durable memory vertical: admitted records, situation-scoped retrieval,
# consolidation, lifecycle, and behavior transitions, assembled into
# Memory::Engine over the SQLite-backed memory store. Nothing here reaches up
# into session, worker, or CLI code.
require "tamoz/core"
require "tamoz/tools"
require "tamoz/sqlite"
require "tamoz/agent_kernel"

require_relative "agent/memory/version"
require_relative "agent/memory/errors"
require_relative "agent/memory/limits"
require_relative "agent/memory/record"
require_relative "agent/memory/surface"
require_relative "agent/memory/admission"
require_relative "agent/memory/verified_outcome_reference"
require_relative "agent/memory/retrieval"
require_relative "agent/memory/situation_recaller"
require_relative "agent/memory/lifecycle"
require_relative "agent/memory/consolidation"
require_relative "agent/memory/behavior_transition"
require_relative "agent/memory/transition_registry"
require_relative "agent/memory/wisdom"

module Tamoz
  module Agent
    module Memory
    end
  end
end
