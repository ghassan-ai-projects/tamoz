# frozen_string_literal: true

# The command line: argument parsing, rendering, and every command group,
# over the tamoz-agent runtime. The only member of the family that ships an
# executable and the only one that depends on the runtime gem itself.
require "tamoz/agent"
require "tamoz/comms/gateway"

require_relative "agent/cli/version"
require_relative "agent/cli_worker_commands"
require_relative "agent/cli_self_observation_commands"
require_relative "agent/cli_improvement_commands"
require_relative "agent/cli_schedule_commands"
require_relative "agent/cli_profile_commands"
require_relative "agent/cli_session_commands"
require_relative "agent/cli_probe_commands"
require_relative "agent/skill_installation"
require_relative "agent/skills_options"
require_relative "agent/cli_skills_commands"
require_relative "agent/cli_memory_commands"
require_relative "agent/cli_authority"
require_relative "agent/cli_rendering"
require_relative "agent/cli_comms_shared"
require_relative "agent/cli_comms_commands"
require_relative "agent/cli_comms_doctor"
require_relative "agent/cli_comms_ops"
require_relative "agent/cli_telegram_commands"
require_relative "agent/cli_talk_commands"
require_relative "agent/cli_setup_commands"
require_relative "agent/cli_channel_commands"
require_relative "agent/cli_talk_gateway"
require_relative "agent/cli_telegram_pairing"
require_relative "agent/cli_child_processes"
require_relative "agent/cli_start_checks"
require_relative "agent/cli_start_commands"
require_relative "agent/launchd_plist"
require_relative "agent/cli_service_commands"
require_relative "agent/cli_launchd"
require_relative "agent/cli_prompt_adapter"
require_relative "agent/cli_argument_parser"
require_relative "agent/cli_option_policy"
require_relative "agent/cli_event_renderer"
require_relative "agent/cli_model_builder"
require_relative "agent/cli_session_builder"
require_relative "agent/cli_one_shot"
require_relative "agent/cli_operator"
require_relative "agent/cli_interrupt_answers"
require_relative "agent/cli_turn_stream"
require_relative "agent/cli_turn_driver"
require_relative "agent/cli"

module Tamoz
  # MCPServer loads on first use, so starting the CLI does not load the MCP SDK.
  module Agent
    autoload :MCPServer, File.expand_path("agent/mcp_server", __dir__)
  end
end
