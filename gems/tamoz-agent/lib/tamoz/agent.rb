# frozen_string_literal: true

require "tamoz/graph"
require "tamoz/tools"
require_relative "agent/version"
require_relative "agent/errors"
require_relative "agent/behavior_version"
require_relative "agent/plan"
require_relative "agent/deliberation"
require_relative "agent/mcp_capability_source"
require_relative "agent/capability_binding"
require_relative "agent/ruby_llm_model"
require_relative "agent/runtime"
require_relative "agent/session_records"
require_relative "agent/effect_dispatcher"
require_relative "agent/memory"
require_relative "agent/healing"
require_relative "agent/improvement"
require_relative "agent/session_nodes"
require_relative "agent/session"
require_relative "agent/profile"
require_relative "agent/runtime_directory"
require_relative "agent/mcp_source_builder"
require_relative "agent/worker_runtime"
require_relative "agent/outbox_delivery_sink"
require_relative "agent/comms_gateway"
require_relative "agent/worker"
require_relative "agent/cli_worker_commands"
require_relative "agent/cli_schedule_commands"
require_relative "agent/cli_profile_commands"
require_relative "agent/cli_session_commands"
require_relative "agent/cli_authority"
require_relative "agent/cli_rendering"
require_relative "agent/cli_prompt_adapter"
require_relative "agent/cli_argument_parser"
require_relative "agent/cli_option_policy"
require_relative "agent/cli"

module Tamoz
  module Agent
    ROOT = File.expand_path("../../..", __dir__).freeze

    # P16: the tool primitives and the skills descriptor surface live in
    # tamoz-tools. These are constant rebindings — object-identical to the
    # tools-side constants — never subclass or delegation wrappers, so class
    # identity, `MAX_*` constants, and attr_readers all survive. The
    # `Tamoz::Agent::ToolError` family is the same class objects as the
    # tamoz-core D-7 taxonomy; serializers map the core `.name` back to these
    # spellings via `Tamoz::Core::TOOL_ERROR_CLASS_NAMES`.
    Toolbox = Tamoz::Tools::Toolbox
    CheckReceipt = Tamoz::Tools::CheckReceipt
    Skills = Tamoz::Tools::Skills
    ToolError = Tamoz::Tools::ToolError
    ToolArgumentError = Tamoz::Tools::ToolArgumentError
    ToolPolicyError = Tamoz::Tools::ToolPolicyError

    def self.build(
      model:,
      root: Dir.pwd,
      max_plan_attempts: 3,
      allow_changes: false,
      checks: {},
      check_timeout: Toolbox::DEFAULT_CHECK_TIMEOUT,
      approval: nil,
      skills: Skills::Snapshot.empty
    )
      # `skills` is a compiled snapshot supplied by the caller — operator authority.
      # It is never discovered by scanning the workspace, so repository content can
      # never put a skill on the catalog (plan §2).
      toolbox = Toolbox.new(root:, allow_changes:, checks:, check_timeout:, skills:)
      Runtime.new(model:, toolbox:, max_plan_attempts:, approval:)
    end
  end
end
