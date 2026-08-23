# frozen_string_literal: true

require "tamoz/graph"
require "tamoz/tools"
require "tamoz/observability"
require "tamoz/comms"
require "tamoz/approval"
require_relative "agent/request_projection"
require_relative "agent/version"
require "tamoz/agent_kernel"
require_relative "agent/episode_graph"
require_relative "agent/request_route"
require_relative "agent/mcp_capability_source"
require_relative "agent/capability_binding"
require_relative "agent/ruby_llm_model"
require_relative "agent/lane_config"
require_relative "agent/runtime"
require_relative "agent/session_records"
require "tamoz/agent_memory"
require "tamoz/agent_healing"
require_relative "agent/improvement"
require_relative "agent/session_nodes"
require_relative "agent/session"
require_relative "agent/session_status_projection"
require_relative "agent/terminal_progress"
require "tamoz/agent_profile"
require_relative "agent/runtime_directory"
require_relative "agent/mcp_source_builder"
require_relative "agent/governed_database_source"
require_relative "agent/governed_browser_source"
require_relative "agent/worker_runtime"
require_relative "agent/child_environments"
require_relative "agent/child_task"
require_relative "agent/outbox_delivery_sink"
require_relative "agent/comms_gateway"
require_relative "agent/durable_recorder"
require_relative "agent/worker"
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
      ask: nil,
      skills: Skills::Snapshot.empty,
      routing: :legacy,
      recorder: Tamoz::Observability::Recorder::Null::INSTANCE
    )
      # `skills` is a compiled snapshot supplied by the caller — operator authority.
      # It is never discovered by scanning the workspace, so repository content can
      # never put a skill on the catalog (plan §2).
      toolbox = Toolbox.new(root:, allow_changes:, checks:, check_timeout:, skills:)
      # The one-shot runtime is ephemeral: its grants live and die with this
      # process, so it gets the in-memory stores — never the worker's SQLite
      # engine (ADR §2.3).
      approval_engine = build_approval_engine(profile_name: "implement")
      Runtime.new(model:, toolbox:, max_plan_attempts:, ask:, routing:, recorder:, approval_engine:)
    end

    # An ephemeral engine over memory stores for processes that own their own
    # approvals (the one-shot runtime, the interactive CLI). Durable workers
    # build theirs over SQLite at boot (ADR §2.3) — never share instances.
    def self.build_approval_engine(profile_name:, policy_path: Tamoz::Approval.bundled_policy_path)
      evidence_symbols = Tamoz::Comms::AuthorityEvidence.members
      Tamoz::Approval::Engine.new(
        policy: Tamoz::Approval::PolicyDocument.load_profile(
          policy_path, profile_name, evidence_symbols: evidence_symbols
        ),
        grant_store: Tamoz::Approval::MemoryGrantStore.new,
        decision_log: Tamoz::Approval::MemoryDecisionLog.new,
        clock: -> { Time.now },
        evidence_symbols: evidence_symbols
      )
    end
  end
end
