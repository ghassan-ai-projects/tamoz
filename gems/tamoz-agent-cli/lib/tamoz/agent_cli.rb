# frozen_string_literal: true

# The command line: argument parsing, rendering, and every command group,
# over the tamoz-agent runtime. The only member of the family that ships an
# executable and the only one that depends on the runtime gem itself.
require "tamoz/agent"

require_relative "agent/cli/version"
require_relative "agent/cli_worker_commands"
require_relative "agent/cli_schedule_commands"
require_relative "agent/cli_profile_commands"
require_relative "agent/cli_session_commands"
require_relative "agent/cli_authority"
require_relative "agent/cli_rendering"
require_relative "agent/cli_comms_shared"
require_relative "agent/cli_comms_commands"
require_relative "agent/cli_comms_doctor"
require_relative "agent/cli_comms_ops"
require_relative "agent/cli_prompt_adapter"
require_relative "agent/cli_argument_parser"
require_relative "agent/cli_option_policy"
require_relative "agent/cli"
