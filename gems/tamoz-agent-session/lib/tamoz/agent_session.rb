# frozen_string_literal: true

# The deliberation loop: one durable Session over its records, nodes, effects,
# evidence, routing, and adaptive machinery. Required by tamoz-agent ahead of
# the worker wiring; nothing here reaches up into worker, runtime, or CLI code.
require "tamoz/core"
require "tamoz/agent_kernel"
require "tamoz/agent_capabilities"
require "tamoz/agent_memory"
require "tamoz/agent_profile"

require_relative "agent/session_gem/version"
require_relative "agent/session_approval_wiring"
require_relative "agent/session_records"
require_relative "agent/session_bindings"
require_relative "agent/session_memory"
require_relative "agent/session_planning_context"
require_relative "agent/session_plan_outcomes"
require_relative "agent/session_plan_attempt"
require_relative "agent/session_effects"
require_relative "agent/session_evidence"
require_relative "agent/session_deliberation"
require_relative "agent/session_steps"
require_relative "agent/session_lifecycle"
require_relative "agent/session_routing"
require_relative "agent/session_adaptive"
require_relative "agent/session_nodes"
require_relative "agent/session"
require_relative "agent/session_status_projection"

module Tamoz
  module Agent
    module SessionGem
    end
  end
end
