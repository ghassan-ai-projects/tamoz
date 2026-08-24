# frozen_string_literal: true

require "tamoz/cancellation"
require "tamoz/concurrency"
require "tamoz/graph"
require "tamoz/tools"
require "tamoz/observability"
require "tamoz/comms"
require "tamoz/approval"
require_relative "agent/request_projection"
require_relative "agent/version"
require "tamoz/agent_kernel"
require "tamoz/agent_capabilities"
require_relative "agent/episode_graph"
require_relative "agent/request_route"
require_relative "agent/ruby_llm_model"
require_relative "agent/lane_config"
require_relative "agent/runtime"
require "tamoz/agent_session"
require "tamoz/agent_memory"
require "tamoz/agent_healing"
require "tamoz/agent_improvement"
require_relative "agent/terminal_progress"
require "tamoz/agent_profile"
require_relative "agent/runtime_directory"
require_relative "agent/worker_runtime"
require_relative "agent/child_environments"
require_relative "agent/durable_recorder"
require_relative "agent/worker"

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
    # ToolError/ToolArgumentError/ToolPolicyError are bound once, by the
    # capabilities umbrella (required above); rebinding them here would warn.

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
