# frozen_string_literal: true

# The capability bridge: local tools, governed MCP sources, and the durable
# child-task capability bound into one sealed catalog. Required by tamoz-agent
# ahead of the session wiring; nothing here reaches up into session, worker,
# or CLI code.
require "tamoz/core"
require "tamoz/agent_kernel"

require_relative "agent/capabilities/version"
require_relative "agent/child_task"
require_relative "agent/child_task_dispatcher"
require_relative "agent/capability_binding"
require_relative "agent/mcp_capability_source"
require_relative "agent/governed_browser_source"
require_relative "agent/governed_database_source"
require_relative "agent/probe_catalog"
require_relative "agent/probe_source"
require_relative "agent/mcp_source_builder"

module Tamoz
  module Agent
    # The moved files raise these bare spellings under module nesting; bind the
    # same objects here so the gem is sound without tamoz-agent loaded.
    # agent.rb's later rebinding of the same objects is idempotent.
    ToolError = Tamoz::Tools::ToolError
    ToolArgumentError = Tamoz::Tools::ToolArgumentError
    ToolPolicyError = Tamoz::Tools::ToolPolicyError

    module Capabilities
    end
  end
end
