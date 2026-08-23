# frozen_string_literal: true

# P12 bounded self-healing: the typed failure contract, classification and
# abstention, the immutable rule contract, and the reviewed remediation
# protocol. Required by tamoz-agent alongside its other verticals; nothing
# here reaches back up into session, worker, or CLI code.
require "tamoz/core"
require "tamoz/tools"
require "tamoz/agent_kernel"

require_relative "agent/healing/version"
require_relative "agent/healing/errors"
require_relative "agent/healing/scope"
require_relative "agent/healing/failure_record"
require_relative "agent/healing/classification"
require_relative "agent/healing/preflight"
require_relative "agent/healing/rule"
require_relative "agent/healing/seams"
require_relative "agent/healing/rule_registry"
require_relative "agent/healing/effect_identity"
require_relative "agent/healing/oracle"
require_relative "agent/healing/promotion_gate"
require_relative "agent/healing/remediation"
require_relative "agent/healing"
