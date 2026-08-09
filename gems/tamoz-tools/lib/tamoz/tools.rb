# frozen_string_literal: true

require "tamoz/core"
require_relative "tools/version"
require_relative "tools/skills"
require_relative "tools/path_resolver"
require_relative "tools/tool_argument_validator"
require_relative "tools/tool_policy_normalizer"
require_relative "tools/toolbox"
require_relative "tools/capability_host"
require_relative "tools/local_dispatcher"

module Tamoz
  module Tools
    # P16: the D-7 tool-error taxonomy is homed in tamoz-core, keeping the runtime
    # dependency graph tamoz-core <- tamoz-tools <- tamoz-agent. These constant
    # rebindings give the moved raise sites their in-tools names — `Tamoz::Tools::ToolError`
    # is the same class object as `Tamoz::Core::ToolError` — without a second
    # definition that could drift.
    ToolError = Tamoz::Core::ToolError
    ToolArgumentError = Tamoz::Core::ToolArgumentError
    ToolPolicyError = Tamoz::Core::ToolPolicyError
  end
end
