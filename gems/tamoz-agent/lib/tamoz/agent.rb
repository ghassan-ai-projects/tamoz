# frozen_string_literal: true

require "tamoz/graph"
require_relative "agent/version"
require_relative "agent/errors"
require_relative "agent/plan"
require_relative "agent/deliberation"
require_relative "agent/skills"
require_relative "agent/toolbox"
require_relative "agent/ruby_llm_model"
require_relative "agent/runtime"
require_relative "agent/session_records"
require_relative "agent/effect_dispatcher"
require_relative "agent/session_nodes"
require_relative "agent/session"
require_relative "agent/profile"
require_relative "agent/cli"

module Tamoz
  module Agent
    ROOT = File.expand_path("../../..", __dir__).freeze

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
