# frozen_string_literal: true

# Trusted profiles: operator-side document/authority/egress validation and
# the adoption/transition registries. Required by tamoz-agent ahead of the
# session wiring; nothing here reaches up into session, worker, or CLI code.
require "tamoz/agent_kernel"
require "tamoz/core"
require_relative "agent/profile/version"
require_relative "agent/profile"
